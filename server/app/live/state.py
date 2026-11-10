"""In-memory live state, one entry per bus on an active trip (TRD: single instance).

`app.state.live` (created lazily by `get_live`) holds a `BusLive` per active trip.
It is the source for `GET /buses/live`, the ETA endpoint and WS fan-out. The DB
is written asynchronously by `app.live.writer`; on startup the state is rebuilt
from active trips and their latest stored fix (TC19 / N4).

Freshness uses the SERVER receive time of the live fix, never the phone clock
(T13). States:
  live     a fix arrived less than `stale_after_s` ago and the bus is moving
  stopped  as live, but smoothed speed below `stopped_speed_mps` (T14)
  stale    no fix for `stale_after_s`  (30 s)
  offline  no fix for `offline_after_s` (2 min), or no fix yet
"""

from __future__ import annotations

import asyncio
import math
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any
from uuid import UUID

from app.geo import cumulative_distances
from app.geo.polyline import PolylineError, decode
from app.geo.snap import snap_forward


@dataclass(frozen=True)
class RouteGeom:
    """A route's decoded polyline, frozen for the whole trip (edits apply next trip, U6)."""

    route_id: UUID
    name: str
    points: list[tuple[float, float]]
    cum: list[float]

    @classmethod
    def from_row(cls, route_id: UUID, name: str, polyline: str | None, cum_dist_m: Any) -> RouteGeom:
        points: list[tuple[float, float]] = []
        if polyline:
            try:
                points = decode(polyline)
            except PolylineError:
                points = []
        cum = [float(x) for x in cum_dist_m] if isinstance(cum_dist_m, list) else []
        if len(cum) != len(points):
            cum = cumulative_distances(points)
        return cls(route_id, name, points, cum)

    @property
    def usable(self) -> bool:
        return len(self.points) >= 1

    def reversed(self) -> RouteGeom:
        """The same road read backwards (a `from_campus` trip): points flipped and
        the cumulative distances recomputed from the new start."""
        points = list(reversed(self.points))
        return RouteGeom(self.route_id, self.name, points, cumulative_distances(points))


@dataclass
class BusLive:
    bus_id: UUID
    trip_id: UUID
    route_id: UUID
    driver_id: UUID
    bus_label: str
    route: RouteGeom
    started_at: datetime
    trip_type: str = "ad_hoc"
    direction: str = "to_campus"
    scheduled_departure: datetime | None = None
    status: str = "on_time"
    note: str | None = None
    # Live fix (the newest accepted fix by recorded_at).
    lat: float | None = None
    lng: float | None = None
    heading: float | None = None
    recorded_at: datetime | None = None
    received_at: datetime | None = None
    ema_speed_mps: float | None = None
    snap_index: int = 0
    along_m: float | None = None
    distance_m: float = 0.0
    # U6: stop_id -> distance along THIS trip's frozen polyline, taken when the trip
    # was loaded. Stop edits mid-trip never change it (they apply from the next trip).
    stop_along: dict[UUID, float] = field(default_factory=dict)
    moved_at: datetime | None = None           # first fix above moved_speed_mps (journey really began)
    arriving: bool = False                     # an arrival close is in flight; fires once
    # V1.3 stop alert: server time of the last accepted fix whose speed was above moved_speed_mps
    # (None = never moved this trip), and whether a stop_events episode is open (kept by the stop job).
    last_moving_at: datetime | None = None
    stop_open: bool = False
    # from_campus only: the travel-order last stop (lowest sequence), cached at load time.
    last_stop: tuple[float, float] | None = None
    last_stored_at: datetime | None = None     # history downsampling
    clock_skew_s: float | None = None          # T13: received - recorded, when large
    seen_fix_ids: OrderedDict[UUID, None] = field(default_factory=OrderedDict)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    @property
    def has_position(self) -> bool:
        return self.lat is not None and self.lng is not None

    def remember_fix(self, fix_id: UUID, limit: int) -> None:
        self.seen_fix_ids[fix_id] = None
        while len(self.seen_fix_ids) > limit:
            self.seen_fix_ids.popitem(last=False)

    def update_ema(self, sample_mps: float, dt_s: float, window_s: float) -> None:
        """Time-based EMA; tau = window/3 puts ~95% of the weight on the last window."""
        if self.ema_speed_mps is None or dt_s <= 0:
            self.ema_speed_mps = sample_mps if self.ema_speed_mps is None else self.ema_speed_mps
            return
        alpha = 1 - math.exp(-dt_s / max(window_s / 3, 1e-6))
        self.ema_speed_mps += alpha * (sample_mps - self.ema_speed_mps)

    def stop_distance(self, stop_id: UUID, lat: float, lng: float, tie_tolerance_m: float) -> float | None:
        """The stop's distance on the frozen polyline: from the snapshot, else (a stop
        added after the trip started) the stop snapped onto the same polyline."""
        if stop_id in self.stop_along:
            return self.stop_along[stop_id]
        if not self.route.usable:
            return None
        return snap_forward(self.route.points, self.route.cum, lat, lng, 0, tie_tolerance_m).along_m

    def resnap(self, tie_tolerance_m: float) -> None:
        if not self.has_position or not self.route.usable:
            return
        snap = snap_forward(self.route.points, self.route.cum, self.lat, self.lng,  # type: ignore[arg-type]
                            start_index=self.snap_index, tie_tolerance_m=tie_tolerance_m)
        self.snap_index, self.along_m = snap.index, snap.along_m


def classify(bus: BusLive, now: datetime, *, stale_after_s: float, offline_after_s: float,
             stopped_speed_mps: float) -> str:
    if bus.received_at is None:
        return "offline"
    age = (now - bus.received_at).total_seconds()
    if age >= offline_after_s:
        return "offline"
    if age >= stale_after_s:
        return "stale"
    if bus.ema_speed_mps is not None and bus.ema_speed_mps < stopped_speed_mps:
        return "stopped"
    return "live"


class LiveState:
    def __init__(self) -> None:
        self.buses: dict[UUID, BusLive] = {}
        self.revoked_sessions: set[UUID] = set()   # for the DB-down ingestion path (N5)

    def add(self, bus: BusLive) -> None:
        self.buses[bus.bus_id] = bus

    def by_trip(self, trip_id: UUID) -> BusLive | None:
        return next((b for b in self.buses.values() if b.trip_id == trip_id), None)

    def remove_trip(self, trip_id: UUID) -> BusLive | None:
        bus = self.by_trip(trip_id)
        if bus is not None:
            self.buses.pop(bus.bus_id, None)
        return bus

    def on_route(self, route_id: UUID) -> list[BusLive]:
        return [b for b in self.buses.values() if b.route_id == route_id]


def get_live(app: Any) -> LiveState:
    live = getattr(app.state, "live", None)
    if live is None:
        live = app.state.live = LiveState()
    return live
