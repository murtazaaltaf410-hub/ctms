"""Trip lifecycle: start, status, end (driver or auto-close) and live-state rebuild."""

from __future__ import annotations

import itertools
import logging
from datetime import datetime
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo

import asyncpg
from fastapi import FastAPI

from app import clock
from app.audit import write_audit
from app.errors import NotFound, NotYourTrip, TripAlreadyActive, ValidationFailed
from app.geo import haversine_m
from app.geo.snap import snap_forward
from app.live import on_startup
from app.live.conn import live_conn
from app.live.hooks import TripEvent, emit_trip
from app.live.hub import broadcast
from app.live.messages import bus_status, trip_ended, trip_started
from app.live.state import BusLive, RouteGeom, get_live
from app.live.writer import get_writer
from app.modules.trips.schedule import Slot, nearest_slot, slot_occurrence
from app.modules.trips.schemas import TripOut, TripSummary

log = logging.getLogger("ctms.trips")

TRIP_SELECT = """
select t.id, t.bus_id, t.driver_id, t.route_id, t.schedule_id, t.type, t.direction, t.status, t.note,
       t.started_at, t.ended_at, t.closed_by, t.distance_m, t.last_fix_at,
       b.label as bus_label, r.name as route_name, r.polyline, r.cum_dist_m,
       s.departure_time
  from public.trips t
  join public.buses b on b.id = t.bus_id
  join public.routes r on r.id = t.route_id
  left join public.schedules s on s.id = t.schedule_id
"""

ACTIVE_TRIP_INDEXES = ("trips_one_active_per_bus", "trips_one_active_per_driver")


def campus_tz(app: Any) -> ZoneInfo:
    return ZoneInfo(str(app.state.settings_store.get_cached("timezone")))


def _scheduled_departure(app: Any, row: asyncpg.Record) -> datetime | None:
    if row["departure_time"] is None:
        return None
    return slot_occurrence(row["departure_time"], row["started_at"], campus_tz(app))


def trip_out(app: Any, row: asyncpg.Record) -> TripOut:
    return TripOut(
        id=row["id"], bus_id=row["bus_id"], bus_label=row["bus_label"], route_id=row["route_id"],
        route_name=row["route_name"], driver_id=row["driver_id"], schedule_id=row["schedule_id"],
        type=row["type"], direction=row["direction"], scheduled_departure=_scheduled_departure(app, row),
        status=row["status"],
        note=row["note"], started_at=row["started_at"], ended_at=row["ended_at"], closed_by=row["closed_by"],
        distance_m=round(row["distance_m"], 1), last_fix_at=row["last_fix_at"],
    )


async def load_trip(con: asyncpg.Connection, trip_id: UUID) -> asyncpg.Record | None:
    return await con.fetchrow(TRIP_SELECT + " where t.id = $1", trip_id)


def bus_from_row(app: Any, row: asyncpg.Record) -> BusLive:
    route = RouteGeom.from_row(row["route_id"], row["route_name"], row["polyline"], row["cum_dist_m"])
    if row["direction"] == "from_campus":
        route = route.reversed()  # the same road read backwards: stops and ETAs follow it
    return BusLive(
        bus_id=row["bus_id"], trip_id=row["id"], route_id=row["route_id"], driver_id=row["driver_id"],
        bus_label=row["bus_label"], route=route,
        started_at=row["started_at"], trip_type=row["type"], direction=row["direction"],
        scheduled_departure=_scheduled_departure(app, row), status=row["status"], note=row["note"],
        distance_m=float(row["distance_m"] or 0.0),
    )


async def load_bus(app: Any, con: asyncpg.Connection, row: asyncpg.Record) -> BusLive:
    """A trip's live entry with its stop-distance snapshot (U6).

    Each active stop is snapped onto the trip's own polyline in sequence order
    (forward from the previous stop, so loops resolve correctly) instead of
    trusting `stops.dist_along_m`, which a mid-trip route edit rewrites at once.
    Accepted limitation: after a restart (`rebuild_live`) or an N4 resume, only
    the CURRENT route polyline and stops exist in the DB, so a trip whose route
    was edited mid-trip continues on the edited geometry.
    """
    bus = bus_from_row(app, row)
    if not bus.route.usable:
        return bus
    tie = float(app.state.settings_store.get_cached("snap_tie_tolerance_m"))
    order = "desc" if row["direction"] == "from_campus" else "asc"
    stops = await con.fetch(
        f"select id, lat, lng from public.stops where route_id = $1 and active order by sequence {order}",  # noqa: S608
        row["route_id"],
    )
    index = 0
    for stop in stops:
        snap = snap_forward(bus.route.points, bus.route.cum, stop["lat"], stop["lng"], index, tie)
        bus.stop_along[stop["id"]] = snap.along_m
        index = snap.index
    return bus


async def active_trip_for_driver(con: asyncpg.Connection, driver_id: UUID) -> asyncpg.Record | None:
    return await con.fetchrow(TRIP_SELECT + " where t.driver_id = $1 and t.ended_at is null", driver_id)


async def owned_active_trip(con: asyncpg.Connection, driver_id: UUID, trip_id: UUID) -> asyncpg.Record:
    """The driver's own, not-ended trip: 404 unknown or ended, 403 NOT_YOUR_TRIP."""
    row = await load_trip(con, trip_id)
    if row is None:
        raise NotFound("Trip not found")
    if row["driver_id"] != driver_id:
        raise NotYourTrip()
    if row["ended_at"] is not None:
        raise NotFound("Trip has ended")
    return row


async def _classify(app: Any, con: asyncpg.Connection, route_id: UUID, started_at: datetime,
                    direction: str) -> tuple[UUID | None, str]:
    rows = await con.fetch(
        """select id, departure_time, days_of_week from public.schedules
           where route_id = $1 and direction = $2 and active""",
        route_id, direction,
    )
    slots = [Slot(r["id"], r["departure_time"], tuple(r["days_of_week"])) for r in rows]
    window = float(app.state.settings_store.get_cached("schedule_match_window_s"))
    match = nearest_slot(slots, started_at, campus_tz(app), window)
    return (match[0].schedule_id, "scheduled") if match else (None, "ad_hoc")


async def start_trip(app: FastAPI, con: asyncpg.Connection, driver_id: UUID, route_id: UUID | None,
                     direction: str = "to_campus") -> TripOut:
    bus = await con.fetchrow(
        "select id, default_route_id from public.buses where driver_id = $1 and active", driver_id
    )
    if bus is None:
        raise NotFound("No active bus is linked to this driver")
    explicit = route_id is not None
    route_id = route_id or bus["default_route_id"]
    usable = route_id is not None and await con.fetchval(
        "select true from public.routes where id = $1 and active and status = 'active'", route_id
    )
    if not usable:
        # A draft/inactive default route is ignored, i.e. treated as no default (U6/U7).
        raise ValidationFailed("route_id: route is unknown, draft or inactive" if explicit
                               else "route_id: required because the bus has no active default route")
    if await con.fetchval(
        "select true from public.trips where (bus_id = $1 or driver_id = $2) and ended_at is null",
        bus["id"], driver_id,
    ):
        raise TripAlreadyActive()
    now = clock.now()
    schedule_id, trip_type = await _classify(app, con, route_id, now, direction)
    try:
        async with con.transaction():
            trip_id = await con.fetchval(
                """insert into public.trips (bus_id, driver_id, route_id, schedule_id, type, direction, started_at)
                   values ($1, $2, $3, $4, $5, $6, $7) returning id""",
                bus["id"], driver_id, route_id, schedule_id, trip_type, direction, now,
            )
            await write_audit(con, actor_id=driver_id, action="trip.start", target_type="trip",
                              target_id=trip_id, meta={"type": trip_type, "direction": direction})
    except asyncpg.UniqueViolationError as exc:
        if exc.constraint_name in ACTIVE_TRIP_INDEXES:
            raise TripAlreadyActive() from exc
        raise
    row = await load_trip(con, trip_id)
    assert row is not None
    bus_live = await load_bus(app, con, row)
    get_live(app).add(bus_live)
    await broadcast(app, trip_started(bus_live.bus_id, trip_id), route_id)
    await emit_trip(app, TripEvent(trip_id, bus_live.bus_id, route_id, "started"))
    return trip_out(app, row)


async def set_status(app: FastAPI, con: asyncpg.Connection, row: asyncpg.Record, status: str,
                     note: str | None) -> None:
    note = note or None
    await con.execute("update public.trips set status = $2, note = $3 where id = $1", row["id"], status, note)
    live = get_live(app)
    bus = live.by_trip(row["id"])
    if bus is None:
        bus = await load_bus(app, con, row)
        live.add(bus)
    bus.status, bus.note = status, note
    await broadcast(app, bus_status(bus), bus.route_id)
    await emit_trip(app, TripEvent(row["id"], row["bus_id"], row["route_id"], "status"))


async def path_distance_m(con: asyncpg.Connection, trip_id: UUID) -> float | None:
    """Distance along the stored (accepted) fixes in recorded order; None if < 2 fixes."""
    rows = await con.fetch(
        "select lat, lng from public.locations where trip_id = $1 order by recorded_at, id", trip_id
    )
    if len(rows) < 2:
        return None
    return sum(haversine_m(a["lat"], a["lng"], b["lat"], b["lng"]) for a, b in itertools.pairwise(rows))


def summarize(app: Any, row: asyncpg.Record) -> TripSummary:
    out = trip_out(app, row)
    duration = max(0.0, ((out.ended_at or clock.now()) - out.started_at).total_seconds())
    avg = out.distance_m / duration if duration > 0 else 0.0
    return TripSummary(**out.model_dump(), duration_s=round(duration, 1), avg_speed_mps=round(avg, 2))


async def end_trip(app: FastAPI, con: asyncpg.Connection, trip_id: UUID, *, closed_by: str,
                   ended_at: datetime, actor_id: UUID | None) -> TripSummary:
    """Close a trip (driver or auto-close): flush queued fixes, compute distance, notify."""
    live = get_live(app)
    bus = live.by_trip(trip_id)
    await get_writer(app).flush(app)
    distance = await path_distance_m(con, trip_id)
    if distance is None:
        distance = bus.distance_m if bus else 0.0
    last_fix = bus.received_at if bus else None
    async with con.transaction():
        closed = await con.fetchval(
            """update public.trips
                  set ended_at = greatest($2, started_at), closed_by = $3,
                      distance_m = greatest(distance_m, $4),
                      last_fix_at = case when $5::timestamptz is null then last_fix_at
                                         else greatest(coalesce(last_fix_at, $5), $5) end
                where id = $1 and ended_at is null
            returning id""",
            trip_id, ended_at, closed_by, distance, last_fix,
        )
        if closed:
            await write_audit(con, actor_id=actor_id, action="trip.end", target_type="trip", target_id=trip_id,
                              meta={"closed_by": closed_by, "distance_m": round(distance, 1)})
    row = await load_trip(con, trip_id)
    assert row is not None
    live.remove_trip(trip_id)
    if closed:
        await broadcast(app, trip_ended(row["bus_id"], trip_id), row["route_id"])
        await emit_trip(app, TripEvent(trip_id, row["bus_id"], row["route_id"], "ended"))
    return summarize(app, row)


async def rebuild_live(app: FastAPI) -> int:
    """Load every active trip and its latest stored fix into memory (TC19 / N4)."""
    live = get_live(app)
    tie = float(app.state.settings_store.get_cached("snap_tie_tolerance_m"))
    async with live_conn(app) as con:
        rows = await con.fetch(TRIP_SELECT + " where t.ended_at is null")
        for row in rows:
            bus = await load_bus(app, con, row)
            fix = await con.fetchrow(
                """select lat, lng, heading, speed_mps, recorded_at, received_at from public.locations
                    where trip_id = $1 order by recorded_at desc, id desc limit 1""",
                row["id"],
            )
            if fix is not None:
                bus.lat, bus.lng, bus.heading = fix["lat"], fix["lng"], fix["heading"]
                bus.recorded_at, bus.received_at = fix["recorded_at"], fix["received_at"]
                bus.last_stored_at = fix["recorded_at"]
                bus.ema_speed_mps = None if fix["speed_mps"] is None else float(fix["speed_mps"])
                bus.resnap(tie)
            live.add(bus)
    return len(rows)


@on_startup
async def rebuild_live_on_startup(app: FastAPI) -> None:
    count = await rebuild_live(app)
    if count:
        log.info("rebuilt live state for %d active trip(s)", count)
