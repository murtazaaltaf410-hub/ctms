"""Fix ingestion: validate each fix, update live state, queue DB writes, fan out.

Per fix, in recorded_at order (TRD p.2–3, edge cases T3/T4/T12/T13, N6):
  DUPLICATE          fix_id already seen (this batch, memory, write queue or DB)
  OUT_OF_ORDER       recorded before the trip started (beyond a grace period,
                     widened by the batch's apparent clock lag) - not this trip's
  ACCURACY_TOO_LOW   accuracy worse than `gps_accuracy_max_m`
  SPEED_IMPLAUSIBLE  implied speed from the current live fix above `max_speed_kmh`
Anything else is accepted and stored. Only a fix NEWER than the live fix moves
the bus (T12: older fixes fill history only). Freshness uses the server receive
time; a large phone/server clock difference is flagged on the bus (T13).

One `bus_position` WS message and one `emit_fix` per batch, for the final live
fix, so a buffered catch-up upload jumps the map to the latest position (T6).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

import asyncpg

from app import clock
from app.geo import haversine_m
from app.live.hooks import FixEvent, emit_fix
from app.live.hub import broadcast
from app.live.messages import bus_position
from app.live.state import BusLive
from app.live.writer import LocationRow, RejectedRow, get_writer
from app.modules.trips import service as trips

log = logging.getLogger("ctms.tracking")


@dataclass(frozen=True)
class Fix:
    fix_id: UUID
    lat: float
    lng: float
    accuracy: float
    speed: float | None
    heading: float | None
    recorded_at: datetime


@dataclass
class IngestResult:
    accepted: list[UUID]
    rejected: list[tuple[UUID, str]]


def _utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


async def _known_fix_ids(app: Any, bus: BusLive, ids: list[UUID], con: asyncpg.Connection | None) -> set[UUID]:
    known = set(bus.seen_fix_ids).intersection(ids) | get_writer(app).pending_fix_ids().intersection(ids)
    if con is not None and ids:
        rows = await con.fetch("select fix_id from public.locations where fix_id = any($1::uuid[])", ids)
        known.update(r["fix_id"] for r in rows)
    return known


def _flag_clock_skew(app: Any, bus: BusLive, fixes: list[Fix], now: datetime) -> float:
    """Return how far the batch's newest fix lags the server clock (s), flagging T13.

    A future timestamp is always skew. A lag only counts when the batch is not full,
    i.e. the phone's buffer is drained so its newest fix should be about now."""
    store = app.state.settings_store
    threshold = float(store.get_cached("clock_skew_flag_s"))
    lag = (now - max(f.recorded_at for f in fixes)).total_seconds()
    partial = len(fixes) < int(store.get_cached("location_batch_max"))
    if lag < -threshold or (partial and lag > threshold):
        if bus.clock_skew_s is None:
            log.warning("clock skew on bus %s trip %s: phone is %.0f s %s server time", bus.bus_id, bus.trip_id,
                        abs(lag), "behind" if lag > 0 else "ahead of")
        bus.clock_skew_s = round(lag, 1)
    elif partial:
        bus.clock_skew_s = None
    return lag


async def ingest(app: Any, bus: BusLive, fixes: list[Fix], con: asyncpg.Connection | None) -> IngestResult:
    """Validate and apply a batch. `con` None = DB down: duplicates checked in memory only (N5)."""
    store = app.state.settings_store
    acc_max = float(store.get_cached("gps_accuracy_max_m"))
    max_speed = float(store.get_cached("max_speed_kmh")) / 3.6
    grace = float(store.get_cached("fix_before_start_grace_s"))
    window = float(store.get_cached("eta_ema_window_s"))
    downsample = float(store.get_cached("history_downsample_s"))
    seen_limit = int(store.get_cached("live_seen_fix_ids_max"))
    tie = float(store.get_cached("snap_tie_tolerance_m"))
    moved_speed = float(store.get_cached("moved_speed_mps"))
    arrival_min_s = float(store.get_cached("arrival_min_trip_s"))
    writer = get_writer(app)
    result = IngestResult([], [])
    if not fixes:
        return result
    fixes = sorted((Fix(f.fix_id, f.lat, f.lng, f.accuracy, f.speed, f.heading, _utc(f.recorded_at))
                    for f in fixes), key=lambda f: f.recorded_at)
    moved = False
    arrival_at: datetime | None = None
    async with bus.lock:
        now = clock.now()
        known = await _known_fix_ids(app, bus, [f.fix_id for f in fixes], con)
        lag = _flag_clock_skew(app, bus, fixes, now)
        earliest_ok = bus.started_at - timedelta(seconds=grace + max(0.0, lag))
        in_batch: set[UUID] = set()
        for fix in fixes:
            reason = None
            implied = dist = dt = 0.0
            newer = bus.recorded_at is None or fix.recorded_at > bus.recorded_at
            if fix.fix_id in known or fix.fix_id in in_batch:
                reason = "DUPLICATE"
            elif fix.recorded_at < earliest_ok:
                reason = "OUT_OF_ORDER"
            elif fix.accuracy > acc_max:
                reason = "ACCURACY_TOO_LOW"
            elif newer and bus.has_position:
                dt = (fix.recorded_at - bus.recorded_at).total_seconds()  # type: ignore[operator]
                dist = haversine_m(bus.lat, bus.lng, fix.lat, fix.lng)  # type: ignore[arg-type]
                implied = dist / max(dt, 1.0)
                if implied > max_speed:
                    reason = "SPEED_IMPLAUSIBLE"
            in_batch.add(fix.fix_id)
            if reason is not None:
                result.rejected.append((fix.fix_id, reason))
                writer.queue_rejection(RejectedRow(bus.trip_id, fix.fix_id, reason, now))
                continue
            result.accepted.append(fix.fix_id)
            bus.remember_fix(fix.fix_id, seen_limit)
            skip_history = (newer and downsample > 0 and bus.last_stored_at is not None
                            and (fix.recorded_at - bus.last_stored_at).total_seconds() < downsample)
            if not skip_history:
                writer.queue_location(LocationRow(bus.trip_id, fix.fix_id, fix.lat, fix.lng, fix.accuracy,
                                                  fix.speed, fix.heading, fix.recorded_at, now))
                if newer:
                    bus.last_stored_at = fix.recorded_at
            if not newer:
                continue  # T12: history only
            had_position = bus.has_position
            bus.distance_m += dist
            sample = fix.speed if fix.speed is not None else (implied if had_position else None)
            if sample is not None:
                bus.update_ema(sample, dt, window)
            bus.lat, bus.lng, bus.heading = fix.lat, fix.lng, fix.heading
            bus.recorded_at, bus.received_at = fix.recorded_at, now
            bus.resnap(tie)
            moved = True
            if bus.moved_at is None and max(sample or 0.0, bus.ema_speed_mps or 0.0) > moved_speed:
                bus.moved_at = fix.recorded_at
                writer.queue_trip_moved(bus.trip_id, fix.recorded_at)
            if (con is not None and not bus.arriving and bus.moved_at is not None
                    and (fix.recorded_at - bus.started_at).total_seconds() >= arrival_min_s
                    and trips.inside_arrival_zone(app, bus)):
                bus.arriving = True   # one close only; a later fix or request cannot re-trigger
                arrival_at = min(fix.recorded_at, now)
        if moved:
            writer.queue_trip_progress(bus.trip_id, now, bus.distance_m)
    if moved:
        await broadcast(app, bus_position(bus), bus.route_id)
        await emit_fix(app, FixEvent(
            trip_id=bus.trip_id, bus_id=bus.bus_id, route_id=bus.route_id, bus_label=bus.bus_label,
            route_name=bus.route.name, lat=bus.lat, lng=bus.lng,  # type: ignore[arg-type]
            speed_mps=bus.ema_speed_mps, heading=bus.heading, recorded_at=bus.recorded_at,  # type: ignore[arg-type]
            received_at=bus.received_at, trip_status=bus.status,  # type: ignore[arg-type]
            direction=bus.direction,
        ))
    if arrival_at is not None and con is not None:
        await _close_on_arrival(app, bus, con, arrival_at)
    return result


async def _close_on_arrival(app: Any, bus: BusLive, con: asyncpg.Connection, at: datetime) -> None:
    """End the trip at the geofence (closed_by 'arrival'); a lost race with the driver's button is fine."""
    try:
        await trips.end_trip(app, con, bus.trip_id, closed_by="arrival", ended_at=at, actor_id=None, arrived_at=at)
    except Exception:
        bus.arriving = False   # not closed: the next accepted fix inside the zone tries again
        log.exception("arrival close failed for trip %s", bus.trip_id)
