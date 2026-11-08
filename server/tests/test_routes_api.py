"""Routes API client (ADR-8) against mocked HTTP, and the private polyline/projection helpers."""

from __future__ import annotations

import json

import httpx
import pytest

from app.integrations.routes_api import FIELD_MASK, GoogleRoutesClient, RoutesApiError
from app.modules.routes.geo import (
    cumulative_distances,
    decode_polyline,
    encode_polyline,
    haversine_m,
    project_stops,
)

URL = "https://routes.googleapis.com/directions/v2:computeRoutes"
STOPS = [(34.126, 74.835), (34.1278, 74.8368), (34.1295, 74.8382), (34.1315, 74.8399)]


def client_with(handler, key: str | None = "test-key") -> tuple[GoogleRoutesClient, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    return GoogleRoutesClient(key, url=URL, timeout_s=5, transport=httpx.MockTransport(record)), seen


async def test_request_shape_and_response_parsing():
    reply = {"routes": [{"distanceMeters": 772, "polyline": {"encodedPolyline": "ipkcFfichVnP@j@BLoFVwM{E?"}}]}
    client, seen = client_with(lambda r: httpx.Response(200, json=reply))
    route = await client.compute_route(STOPS)
    assert route.encoded_polyline == "ipkcFfichVnP@j@BLoFVwM{E?" and route.distance_m == 772
    (req,) = seen
    assert req.method == "POST" and str(req.url) == URL
    assert req.headers["X-Goog-Api-Key"] == "test-key"
    assert req.headers["X-Goog-FieldMask"] == FIELD_MASK == "routes.polyline.encodedPolyline,routes.distanceMeters"
    assert req.headers["content-type"] == "application/json"
    body = json.loads(req.content)
    assert body["origin"] == {"location": {"latLng": {"latitude": 34.126, "longitude": 74.835}}}
    assert body["destination"] == {"location": {"latLng": {"latitude": 34.1315, "longitude": 74.8399}}}
    assert [w["location"]["latLng"] for w in body["intermediates"]] == [
        {"latitude": 34.1278, "longitude": 74.8368},
        {"latitude": 34.1295, "longitude": 74.8382},
    ]
    assert body["travelMode"] == "DRIVE" and body["routingPreference"] == "TRAFFIC_UNAWARE"
    assert body["polylineEncoding"] == "ENCODED_POLYLINE" and body["computeAlternativeRoutes"] is False
    assert "test-key" not in req.url.query.decode()  # key in a header, never in the URL


async def test_two_stops_send_no_intermediates():
    reply = {"routes": [{"polyline": {"encodedPolyline": "_p~iF~ps|U_ulLnnqC"}}]}
    client, seen = client_with(lambda r: httpx.Response(200, json=reply))
    route = await client.compute_route(STOPS[:2])
    assert route.distance_m is None
    assert "intermediates" not in json.loads(seen[0].content)


@pytest.mark.parametrize(
    ("response", "reason"),
    [
        (
            httpx.Response(
                403, json={"error": {"code": 403, "message": "API key not valid", "status": "PERMISSION_DENIED"}}
            ),
            "http_403",
        ),
        (httpx.Response(200, json={}), "no_route"),
        (httpx.Response(200, json={"routes": []}), "no_route"),
        (httpx.Response(200, json={"routes": [{"distanceMeters": 5}]}), "bad_response"),
        (httpx.Response(200, text="not json"), "bad_response"),
    ],
)
async def test_failures_raise_routes_api_error(response, reason):
    client, _ = client_with(lambda r: response)
    with pytest.raises(RoutesApiError) as info:
        await client.compute_route(STOPS)
    assert info.value.reason == reason
    if reason == "http_403":
        assert "API key not valid" in info.value.message


async def test_timeout_and_network_errors():
    def timeout(request):
        raise httpx.ReadTimeout("slow", request=request)

    def refused(request):
        raise httpx.ConnectError("refused", request=request)

    for handler, reason in ((timeout, "timeout"), (refused, "network")):
        client, _ = client_with(handler)
        with pytest.raises(RoutesApiError) as info:
            await client.compute_route(STOPS)
        assert info.value.reason == reason


async def test_no_key_or_bad_stop_count_makes_no_http_call():
    client, seen = client_with(lambda r: httpx.Response(200, json={}), key=None)
    with pytest.raises(RoutesApiError) as info:
        await client.compute_route(STOPS)
    assert info.value.reason == "not_configured"
    client, seen = client_with(lambda r: httpx.Response(200, json={}))
    for stops, reason in ((STOPS[:1], "too_few_stops"), ([(34.0, 74.0)] * 28, "too_many_stops")):
        with pytest.raises(RoutesApiError) as info:
            await client.compute_route(stops)
        assert info.value.reason == reason
    assert seen == []


def test_polyline_google_example_round_trip():
    encoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
    points = [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]
    assert decode_polyline(encoded) == points
    assert encode_polyline(points) == encoded
    with pytest.raises(ValueError):
        decode_polyline("_p~iF~ps|U_")


def test_cumulative_distance_and_stop_projection():
    points = [(34.0, 74.0), (34.0, 74.01), (34.01, 74.01)]
    cum = cumulative_distances(points)
    assert cum[0] == 0 and cum[1] == pytest.approx(haversine_m(points[0], points[1]))
    assert cum[1] == pytest.approx(922, rel=0.01)  # 0.01 deg of longitude at 34 N
    stops = [(34.0001, 74.0), (34.0001, 74.005), (34.005, 74.0101), (34.01, 74.01)]
    along = project_stops(points, cum, stops)
    assert along == sorted(along)
    assert along[0] == pytest.approx(0, abs=1)
    assert along[1] == pytest.approx(cum[1] / 2, rel=0.01)
    assert along[3] == pytest.approx(cum[2], abs=1)
