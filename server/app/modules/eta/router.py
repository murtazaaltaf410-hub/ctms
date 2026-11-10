"""GET /stops/{id}/eta (API spec p.4). Never errors for a known stop: no active bus
gives an empty list plus `next_scheduled`."""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Request
from pydantic import Field

from app import clock
from app.db import Conn
from app.deps import AuthUser
from app.errors import NotFound
from app.geo.snap import snap_forward
from app.live.state import classify, get_live
from app.modules.eta.service import compute_eta
from app.modules.students.service import ApprovedStudent, approved_route_id, student_scope
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


class EtaTarget(ApiModel):
    type: Literal["pickup", "first_stop"]
    lat: float
    lng: float
    label: str | None
    stop_id: UUID | None
    direction: Literal["to_campus", "from_campus"] | None = Field(description="The pin's leg (pickup only)")


class MyEta(ApiModel):
    target: EtaTarget | None = Field(description="null when the route has neither a pin nor a stop")
    etas: list[BusEta]
    next_scheduled: UtcDateTime | None


def bus_eta(app, bus, d_target: float | None, now: datetime) -> BusEta | None:
    """The ETA of one live bus to a point `d_target` metres along its frozen polyline (None: no position yet)."""
    if not bus.has_position or bus.along_m is None or d_target is None:
        return None
    store = app.state.settings_store
    get = lambda key: float(store.get_cached(key))  # noqa: E731
    thresholds = {k: get(k) for k in ("stale_after_s", "offline_after_s", "stopped_speed_mps")}
    eta = compute_eta(d_target, bus.along_m, bus.ema_speed_mps, v_min_mps=get("eta_v_min_kmh") / 3.6,
                      cap_s=get("eta_display_cap_s"), passed_tolerance_m=get("eta_passed_tolerance_m"))
    return BusEta(
        bus_id=bus.bus_id, trip_id=bus.trip_id, label=bus.bus_label, state=classify(bus, now, **thresholds),
        status=bus.status, note=bus.note, passed=eta.passed, eta_seconds=eta.eta_seconds, capped=eta.capped,
        distance_m=eta.distance_m, trip_type=bus.trip_type, scheduled_departure=bus.scheduled_departure,
    )


@router.get("/stops/{stop_id}/eta", response_model=StopEta)
async def stop_eta(stop_id: UUID, request: Request, user: AuthUser, con: Conn) -> StopEta:
    app = request.app
    only_route = await student_scope(con, user)  # 403 REGISTRATION_REQUIRED until approved (ADR-10)
    stop = await con.fetchrow(
        "select id, route_id, lat, lng from public.stops where id = $1 and active", stop_id
    )
    if stop is None or (only_route is not None and stop["route_id"] != only_route):
        raise NotFound("Stop not found")
    now: datetime = clock.now()
    etas: list[BusEta] = []
    for bus in get_live(app).on_route(stop["route_id"]):
        d_stop = bus.stop_distance(stop["id"], stop["lat"], stop["lng"],
                                   float(app.state.settings_store.get_cached("snap_tie_tolerance_m")))
        eta = bus_eta(app, bus, d_stop, now)
        if eta is not None:
            etas.append(eta)
    etas.sort(key=lambda e: (e.passed, e.eta_seconds if e.eta_seconds is not None else 0))
    rows = await con.fetch(
        "select id, departure_time, days_of_week from public.schedules where route_id = $1 and active",
        stop["route_id"],
    )
    slots = [Slot(r["id"], r["departure_time"], tuple(r["days_of_week"])) for r in rows]
    return StopEta(stop_id=stop_id, route_id=stop["route_id"], etas=etas,
                   next_scheduled=next_departure(slots, now, campus_tz(app)))


@router.get("/me/eta", response_model=MyEta)
async def my_eta(request: Request, user: ApprovedStudent, con: Conn) -> MyEta:
    """Student: ETAs of the buses on my route to my waiting pickup pin (buses on the pin's leg only), or, with
    no pin, to the route's first stop. Works with only the first and last stops visible to students."""
    app = request.app
    route_id = await approved_route_id(con, user.id)
    now: datetime = clock.now()
    tie = float(app.state.settings_store.get_cached("snap_tie_tolerance_m"))
    pin = await con.fetchrow(
        """select lat, lng, label, direction from public.pickup_requests
            where student_id = $1 and status = 'waiting' and expires_at > $2 and route_id = $3""",
        user.id, now, route_id)
    etas: list[BusEta] = []
    target: EtaTarget | None = None
    if pin is not None:
        target = EtaTarget(type="pickup", lat=pin["lat"], lng=pin["lng"], label=pin["label"], stop_id=None,
                           direction=pin["direction"])
        for bus in get_live(app).on_route(route_id):
            if bus.direction != pin["direction"] or not bus.route.usable:
                continue
            d_pin = snap_forward(bus.route.points, bus.route.cum, pin["lat"], pin["lng"], 0, tie).along_m
            eta = bus_eta(app, bus, d_pin, now)
            if eta is not None:
                etas.append(eta)
    else:
        stop = await con.fetchrow(
            """select id, name, lat, lng from public.stops where route_id = $1 and active
                order by sequence, created_at limit 1""", route_id)
        if stop is not None:
            target = EtaTarget(type="first_stop", lat=stop["lat"], lng=stop["lng"], label=stop["name"],
                               stop_id=stop["id"], direction=None)
            for bus in get_live(app).on_route(route_id):
                eta = bus_eta(app, bus, bus.stop_distance(stop["id"], stop["lat"], stop["lng"], tie), now)
                if eta is not None:
                    etas.append(eta)
    etas.sort(key=lambda e: (e.passed, e.eta_seconds if e.eta_seconds is not None else 0))
    rows = await con.fetch(
        "select id, departure_time, days_of_week from public.schedules where route_id = $1 and active", route_id)
    slots = [Slot(r["id"], r["departure_time"], tuple(r["days_of_week"])) for r in rows]
    return MyEta(target=target, etas=etas, next_scheduled=next_departure(slots, now, campus_tz(app)))
