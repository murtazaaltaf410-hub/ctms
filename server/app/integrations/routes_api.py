"""Route polylines from the Google Routes API `computeRoutes` (ADR-8, not legacy Directions).

    provider = get_route_provider(request)                  # app.state.route_provider, built lazily
    route = await provider.compute_route([(lat, lng), ...])  # stops in order; raises RoutesApiError

Request shape (developers.google.com/maps/documentation/routes/compute_route_directions and
.../reference/rest/v2/TopLevel/computeRoutes, checked 2026-11-08):

    POST https://routes.googleapis.com/directions/v2:computeRoutes
    X-Goog-Api-Key: <key>
    X-Goog-FieldMask: routes.polyline.encodedPolyline,routes.distanceMeters
    {"origin": Waypoint, "destination": Waypoint, "intermediates": [Waypoint, ...],   # <= 25
     "travelMode": "DRIVE", "routingPreference": "TRAFFIC_UNAWARE", ...}
    Waypoint = {"location": {"latLng": {"latitude": .., "longitude": ..}}}

Response: {"routes": [{"distanceMeters": 772, "polyline": {"encodedPolyline": "..."}}]}; an
empty or missing `routes` array means no route could be found.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol

import httpx
from fastapi import Request

from app.config import Settings
from app.modules.routes.geo import encode_polyline

FIELD_MASK = "routes.polyline.encodedPolyline,routes.distanceMeters"

LatLng = tuple[float, float]


class RoutesApiError(Exception):
    """The route could not be generated. `reason` is a short code safe for the audit log."""

    def __init__(self, reason: str, message: str) -> None:
        self.reason = reason
        self.message = message
        super().__init__(message)


@dataclass(frozen=True, slots=True)
class ComputedRoute:
    encoded_polyline: str
    distance_m: float | None


class RouteProvider(Protocol):
    async def compute_route(self, stops: Sequence[LatLng]) -> ComputedRoute: ...


def _waypoint(point: LatLng) -> dict:
    return {"location": {"latLng": {"latitude": point[0], "longitude": point[1]}}}


def build_request_body(stops: Sequence[LatLng]) -> dict:
    body: dict = {
        "origin": _waypoint(stops[0]),
        "destination": _waypoint(stops[-1]),
        "travelMode": "DRIVE",
        "routingPreference": "TRAFFIC_UNAWARE",
        "polylineQuality": "HIGH_QUALITY",
        "polylineEncoding": "ENCODED_POLYLINE",
        "computeAlternativeRoutes": False,
        "units": "METRIC",
    }
    if len(stops) > 2:
        body["intermediates"] = [_waypoint(p) for p in stops[1:-1]]
    return body


def _google_error_message(resp: httpx.Response) -> str:
    try:
        message = resp.json().get("error", {}).get("message")
    except ValueError:
        message = None
    return str(message or resp.reason_phrase or "error")[:300]


class GoogleRoutesClient:
    def __init__(self, api_key: str | None, *, url: str, timeout_s: float, max_intermediates: int = 25,
                 transport: httpx.AsyncBaseTransport | None = None) -> None:
        self._api_key = api_key
        self._url = url
        self._timeout_s = timeout_s
        self._max_intermediates = max_intermediates
        self._transport = transport

    async def compute_route(self, stops: Sequence[LatLng]) -> ComputedRoute:
        if len(stops) < 2:
            raise RoutesApiError("too_few_stops", "A route needs at least 2 stops")
        if len(stops) - 2 > self._max_intermediates:
            raise RoutesApiError("too_many_stops", f"A route can have at most {self._max_intermediates + 2} stops")
        if not self._api_key:
            raise RoutesApiError("not_configured", "GOOGLE_DIRECTIONS_KEY is not configured on the server")
        headers = {"X-Goog-Api-Key": self._api_key, "X-Goog-FieldMask": FIELD_MASK}
        try:
            async with httpx.AsyncClient(timeout=self._timeout_s, transport=self._transport) as client:
                resp = await client.post(self._url, json=build_request_body(stops), headers=headers)
        except httpx.TimeoutException as exc:
            raise RoutesApiError("timeout", "Routes API timed out") from exc
        except httpx.HTTPError as exc:
            raise RoutesApiError("network", f"Routes API unreachable ({type(exc).__name__})") from exc
        if resp.status_code != 200:
            raise RoutesApiError(f"http_{resp.status_code}",
                                 f"Routes API error (HTTP {resp.status_code}): {_google_error_message(resp)}")
        try:
            routes = resp.json().get("routes") or []
        except ValueError as exc:
            raise RoutesApiError("bad_response", "Routes API returned invalid JSON") from exc
        if not routes:
            raise RoutesApiError("no_route", "No drivable route found between the stops")
        encoded = (routes[0].get("polyline") or {}).get("encodedPolyline")
        if not encoded:
            raise RoutesApiError("bad_response", "Routes API response has no polyline")
        distance = routes[0].get("distanceMeters")
        return ComputedRoute(encoded_polyline=encoded, distance_m=float(distance) if distance is not None else None)


class FakeRouteProvider:
    """Test double: a straight line through the stops, or `RoutesApiError` while `fail` is set."""

    def __init__(self, fail: RoutesApiError | None = None) -> None:
        self.fail = fail
        self.calls: list[list[LatLng]] = []

    async def compute_route(self, stops: Sequence[LatLng]) -> ComputedRoute:
        self.calls.append(list(stops))
        if self.fail is not None:
            raise self.fail
        return ComputedRoute(encoded_polyline=encode_polyline(stops), distance_m=None)


def build_route_provider(config: Settings) -> GoogleRoutesClient:
    return GoogleRoutesClient(config.google_directions_key, url=config.routes_api_url,
                              timeout_s=config.routes_api_timeout_s,
                              max_intermediates=config.routes_api_max_intermediates)


def get_route_provider(request: Request) -> RouteProvider:
    provider = getattr(request.app.state, "route_provider", None)
    if provider is None:
        provider = build_route_provider(request.app.state.config)
        request.app.state.route_provider = provider
    return provider
