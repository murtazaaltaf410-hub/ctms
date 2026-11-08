"""GET /stops/{id}/eta (API spec p.4). Never errors for a known stop: no active bus
gives an empty list plus `next_scheduled`."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Request
from pydantic import Field

from app import clock
from app.db import Conn
from app.deps import AuthUser
from app.errors import NotFound
from app.live.state import classify, get_live
from app.modules.eta.service import compute_eta, stop_along_m
from app.modules.trips.schedule import Slot, next_departure
from app.modules.trips.service import campus_tz
from app.schemas import ApiModel, UtcDateTime

router = APIRouter(tags=["eta"])


class BusEta(ApiModel):
    bus_id: UUID
    trip_id: UUID
    label: str
    state: str = Field(description="live | stopped | stale | offline")
    status: str
    note: str | None
    passed: bool = Field(description="The bus is already beyond this stop on this trip")
    eta_seconds: int | None = Field(description="null when passed; at most eta_display_cap_s")
    capped: bool = Field(description="True when the real ETA exceeds the cap (show '30+ min')")
    distance_m: float | None = Field(description="Remaining distance along the route")
    trip_type: str
    scheduled_departure: UtcDateTime | None


class StopEta(ApiModel):
    stop_id: UUID
    route_id: UUID
    etas: list[BusEta]
    next_scheduled: UtcDateTime | None = Field(description="Next timetable departure on this route, if any")


@router.get("/stops/{stop_id}/eta", response_model=StopEta)
async def stop_eta(stop_id: UUID, request: Request, user: AuthUser, con: Conn) -> StopEta:
    app = request.app
    stop = await con.fetchrow(
        "select id, route_id, lat, lng, dist_along_m from public.stops where id = $1 and active", stop_id
    )
    if stop is None:
        raise NotFound("Stop not found")
    store = app.state.settings_store
    now: datetime = clock.now()
    get = lambda key: float(store.get_cached(key))  # noqa: E731
    thresholds = {k: get(k) for k in ("stale_after_s", "offline_after_s", "stopped_speed_mps")}
    etas: list[BusEta] = []
    for bus in get_live(app).on_route(stop["route_id"]):
        if not bus.has_position or bus.along_m is None:
            continue
        d_stop = stop_along_m(bus, stop["lat"], stop["lng"], stop["dist_along_m"], get("snap_tie_tolerance_m"))
        if d_stop is None:
            continue
        eta = compute_eta(d_stop, bus.along_m, bus.ema_speed_mps, v_min_mps=get("eta_v_min_kmh") / 3.6,
                          cap_s=get("eta_display_cap_s"), passed_tolerance_m=get("eta_passed_tolerance_m"))
        etas.append(BusEta(
            bus_id=bus.bus_id, trip_id=bus.trip_id, label=bus.bus_label, state=classify(bus, now, **thresholds),
            status=bus.status, note=bus.note, passed=eta.passed, eta_seconds=eta.eta_seconds, capped=eta.capped,
            distance_m=eta.distance_m, trip_type=bus.trip_type, scheduled_departure=bus.scheduled_departure,
        ))
    etas.sort(key=lambda e: (e.passed, e.eta_seconds if e.eta_seconds is not None else 0))
    rows = await con.fetch(
        "select id, departure_time, days_of_week from public.schedules where route_id = $1 and active",
        stop["route_id"],
    )
    slots = [Slot(r["id"], r["departure_time"], tuple(r["days_of_week"])) for r in rows]
    return StopEta(stop_id=stop_id, route_id=stop["route_id"], etas=etas,
                   next_scheduled=next_departure(slots, now, campus_tz(app)))
