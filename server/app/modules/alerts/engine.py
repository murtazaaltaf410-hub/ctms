"""Nearby-bus alert engine (TRD p.3-4, edge cases A1-A8).

Tracking calls `emit_fix` for every accepted live fix; our listener only queues the
event (bounded, oldest dropped) so ingestion never waits on alert work. One worker
evaluates fixes in order. For each fix:

1. Skip a breakdown trip (A8) or a bus fix older than `alert_bus_fix_max_age_s`.
2. Load students with alert mode on, whose latest location is newer than
   `student_fix_max_age_s` (A5) with accuracy under `student_fix_max_accuracy_m`,
   inside a bounding box of `alert_track_radius_factor` x `alert_radius_m`, on a
   trip that has not ended (A8).
3. Exact distance; remember it per (student, trip). Pairs not seen on this fix are
   forgotten, so "decreasing" always compares two consecutive fixes.
4. A student within `alert_rider_suppress_m` for `alert_rider_min_updates`
   consecutive fixes is riding (A1) and stays suppressed until they are farther than
   the alert radius.
5. Alert when distance < radius, a previous distance exists and it decreased (A3),
   not riding, and the `alert_log` insert wins (one per student per trip).
6. A second bus alerting the same student within `alert_combine_window_s` sends one
   combined push ("2 buses are nearby") that replaces the first on the device (A4).

State is in memory and dropped on trip end and on USER_DELETED (U2).
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from uuid import UUID

from fastapi import FastAPI

from app import clock
from app.live import USER_DELETED, on_shutdown, on_startup, subscribe
from app.live.hooks import FixEvent, TripEvent, register_fix_listener, register_trip_listener
from app.modules.alerts.geo import bounding_box, haversine_m
from app.push import PushJob, background_conn, get_push

log = logging.getLogger("ctms.alerts")

ALERT_TAG = "nearby_alert"
DISTANCE_STEP_M = 50
ENDED_TRIPS_KEPT = 1000

Key = tuple[UUID, UUID]  # (student_id, trip_id)

CANDIDATES_SQL = """
select sl.user_id, sl.lat, sl.lng,
       exists(select 1 from public.alert_log l where l.student_id = sl.user_id and l.trip_id = $7) as alerted
from public.student_locations sl
join public.alert_settings a on a.user_id = sl.user_id and a.enabled
join public.users u on u.id = sl.user_id and u.role = 'student' and u.active
where sl.lat between $1 and $2 and sl.lng between $3 and $4
  and sl.recorded_at > $5 and sl.accuracy_m < $6
  and exists(select 1 from public.trips t where t.id = $7 and t.ended_at is null and t.status <> 'breakdown')
"""


def alert_text(bus_label: str, route_name: str, distance_m: float) -> str:
    """TRD p.4: "Bus 2 (North Campus route) is about 400 m away"."""
    rounded = max(DISTANCE_STEP_M, round(distance_m / DISTANCE_STEP_M) * DISTANCE_STEP_M)
    route = route_name if route_name.lower().endswith("route") else f"{route_name} route"
    return f"{bus_label} ({route}) is about {rounded} m away"


@dataclass
class _Recent:
    at: datetime
    bus_id: UUID
    text: str


@dataclass
class AlertState:
    prev_distance: dict[Key, float] = field(default_factory=dict)
    near_count: dict[Key, int] = field(default_factory=dict)
    riders: set[Key] = field(default_factory=set)
    recent: dict[UUID, list[_Recent]] = field(default_factory=dict)
    ended_trips: OrderedDict[UUID, None] = field(default_factory=OrderedDict)

    def forget_keys(self, keys: list[Key]) -> None:
        for key in keys:
            self.prev_distance.pop(key, None)
            self.near_count.pop(key, None)
            self.riders.discard(key)

    def forget_trip(self, trip_id: UUID) -> None:
        self.forget_keys([k for k in self.prev_distance if k[1] == trip_id])
        self.ended_trips[trip_id] = None
        while len(self.ended_trips) > ENDED_TRIPS_KEPT:
            self.ended_trips.popitem(last=False)

    def forget_student(self, student_id: UUID) -> None:
        self.forget_keys([k for k in self.prev_distance if k[0] == student_id])
        self.recent.pop(student_id, None)

    def keys_for(self, *, student_id: UUID | None = None, trip_id: UUID | None = None) -> list[Key]:
        return [k for k in self.prev_distance
                if (student_id is None or k[0] == student_id) and (trip_id is None or k[1] == trip_id)]


class AlertEngine:
    def __init__(self, maxsize: int) -> None:
        self.state = AlertState()
        self.queue: asyncio.Queue[FixEvent] = asyncio.Queue(maxsize=maxsize)
        self._task: asyncio.Task | None = None

    def submit(self, ev: FixEvent) -> None:
        if self.queue.full():
            with contextlib.suppress(asyncio.QueueEmpty):
                self.queue.get_nowait()
                self.queue.task_done()
            log.warning("alert queue full; dropped the oldest fix")
        self.queue.put_nowait(ev)

    async def process(self, app: FastAPI, ev: FixEvent) -> list[UUID]:
        """Evaluate one fix at `clock.now()`; returns the students alerted (tests call this directly)."""
        now = clock.now()
        if ev.trip_status == "breakdown" or ev.trip_id in self.state.ended_trips:
            return []
        config = app.state.config
        store = app.state.settings_store
        async with background_conn(app) as con:
            radius = float(await store.get("alert_radius_m", con))
            if (now - ev.recorded_at).total_seconds() > float(store.get_cached("alert_bus_fix_max_age_s")):
                return []
            student_max_age = float(store.get_cached("student_fix_max_age_s"))
            max_accuracy = float(store.get_cached("student_fix_max_accuracy_m"))
            rider_m = float(store.get_cached("alert_rider_suppress_m"))
            box = bounding_box(ev.lat, ev.lng, radius * config.alert_track_radius_factor)
            rows = await con.fetch(CANDIDATES_SQL, *box, now - timedelta(seconds=student_max_age),
                                   max_accuracy, ev.trip_id)
            seen: set[Key] = set()
            alerted: list[tuple[UUID, float]] = []
            for row in rows:
                student_id = row["user_id"]
                key = (student_id, ev.trip_id)
                seen.add(key)
                distance = haversine_m(ev.lat, ev.lng, row["lat"], row["lng"])
                prev = self.state.prev_distance.get(key)
                self.state.prev_distance[key] = distance
                if self._is_rider(key, distance, rider_m, radius, config.alert_rider_min_updates):
                    continue
                if row["alerted"] or prev is None or distance >= radius or distance >= prev:
                    continue
                won = await con.fetchval(
                    """insert into public.alert_log (student_id, trip_id, sent_at) values ($1, $2, $3)
                       on conflict (student_id, trip_id) do nothing returning student_id""",
                    student_id, ev.trip_id, now)
                if won is not None:
                    alerted.append((student_id, distance))
        self.state.forget_keys([k for k in self.state.keys_for(trip_id=ev.trip_id) if k not in seen])
        for student_id, distance in alerted:
            self._push(app, ev, student_id, distance, now, float(store.get_cached("alert_combine_window_s")))
        return [s for s, _ in alerted]

    def _is_rider(self, key: Key, distance: float, rider_m: float, radius: float, min_updates: int) -> bool:
        """A1: within rider_m on `min_updates` consecutive fixes = riding, until beyond the radius."""
        count = self.state.near_count.get(key, 0) + 1 if distance <= rider_m else 0
        self.state.near_count[key] = count
        if count >= min_updates:
            self.state.riders.add(key)
        elif distance >= radius:
            self.state.riders.discard(key)
        return key in self.state.riders

    def _push(self, app: FastAPI, ev: FixEvent, student_id: UUID, distance: float, now: datetime,
              window_s: float) -> None:
        text = alert_text(ev.bus_label, ev.route_name, distance)
        recent = [r for r in self.state.recent.get(student_id, [])
                  if (now - r.at).total_seconds() < window_s and r.bus_id != ev.bus_id]
        recent.append(_Recent(now, ev.bus_id, text))
        self.state.recent[student_id] = recent
        if len(recent) == 1:
            title, body = "Bus nearby", text
        else:
            title, body = f"{len(recent)} buses are nearby", "; ".join(r.text for r in recent)
        get_push(app).submit(PushJob(
            title=title, body=body, tag=ALERT_TAG, user_ids=(student_id,),
            data={"type": ALERT_TAG, "trip_id": str(ev.trip_id), "bus_id": str(ev.bus_id),
                  "bus_count": str(len(recent))},
        ))

    async def drain(self, app: FastAPI) -> None:
        while not self.queue.empty():
            ev = self.queue.get_nowait()
            try:
                await self.process(app, ev)
            finally:
                self.queue.task_done()

    async def _run(self, app: FastAPI) -> None:
        while True:
            ev = await self.queue.get()
            try:
                await self.process(app, ev)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("alert evaluation failed for trip %s", ev.trip_id)
            finally:
                self.queue.task_done()

    def start(self, app: FastAPI) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._run(app), name="alert-engine")

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
            self._task = None


def get_engine(app: FastAPI) -> AlertEngine:
    engine: AlertEngine | None = getattr(app.state, "alert_engine", None)
    if engine is None:
        engine = app.state.alert_engine = AlertEngine(app.state.config.alert_queue_max)
    return engine


async def on_fix(app: FastAPI, ev: FixEvent) -> None:
    get_engine(app).submit(ev)


async def on_trip(app: FastAPI, ev: TripEvent) -> None:
    if ev.kind == "ended":
        get_engine(app).state.forget_trip(ev.trip_id)


@subscribe(USER_DELETED)
async def forget_student(app: FastAPI, *, user_id: UUID) -> None:
    get_engine(app).state.forget_student(user_id)


@on_startup
async def _start_engine(app: FastAPI) -> None:
    get_engine(app).start(app)


@on_shutdown
async def _stop_engine(app: FastAPI) -> None:
    await get_engine(app).stop()


register_fix_listener(on_fix)
register_trip_listener(on_trip)
