"""Stop alerts (V1.3 decision 8): stationary episodes, the driver's reason, and driver prompt preferences.

A trip whose bus has not moved for `stopped_alert_after_s` gets one `stop_events` row per stationary
episode. The server then marks the trip `delayed` with the note "Stopped" (only if it was `on_time`, so a
driver-set status is never overwritten) and prompts the driver by push, unless the driver opted out or
snoozed. When the bus moves again the episode closes and an AUTO "Stopped" status goes back to `on_time`;
a status or reason the driver set stays until the driver changes it.

`reconcile` is the one state machine; the `stop_alerts` job calls it for every live bus and ingestion
calls it as soon as a moving fix arrives while an episode is open, so students see the status clear at once.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Any
from uuid import UUID

import asyncpg

from app.live.state import BusLive
from app.modules.trips.service import load_trip, set_status
from app.push import PushJob, get_push

log = logging.getLogger("ctms.stops")

STOP_TAG = "stop_alert"
AUTO_NOTE = "Stopped"
SNOOZE_MINUTES = (0, 15, 30, 60)
REASONS = ("waiting_for_student", "traffic", "breakdown", "fuel", "police_check", "other")
# What students read when the driver gives a reason without a note of their own.
REASON_NOTE = {
    "waiting_for_student": "Waiting for a student",
    "traffic": "Stuck in traffic",
    "breakdown": "Breakdown",
    "fuel": "Refuelling",
    "police_check": "Police check",
    "other": AUTO_NOTE,
}

EVENT_COLUMNS = "id, trip_id, started_at, ended_at, reason, note, auto_marked, driver_notified_at"


async def open_event(con: asyncpg.Connection, trip_id: UUID) -> asyncpg.Record | None:
    return await con.fetchrow(
        f"select {EVENT_COLUMNS} from public.stop_events where trip_id = $1 and ended_at is null",  # noqa: S608
        trip_id,
    )


async def driver_prefs(con: asyncpg.Connection, user_id: UUID) -> tuple[bool, datetime | None]:
    row = await con.fetchrow(
        "select stop_alerts_enabled, snooze_until from public.driver_prefs where user_id = $1", user_id)
    return (True, None) if row is None else (row["stop_alerts_enabled"], row["snooze_until"])


def prompt_allowed(enabled: bool, snooze_until: datetime | None, now: datetime) -> bool:
    return enabled and (snooze_until is None or snooze_until <= now)


def stationary(app: Any, bus: BusLive, now: datetime) -> bool:
    """Has a fresh live position and has not moved for `stopped_alert_after_s`.

    A bus with no recent fix is "offline", not "stopped": a lost GPS signal never raises this alert."""
    store = app.state.settings_store
    if not bus.has_position or bus.received_at is None:
        return False
    if (now - bus.received_at).total_seconds() >= float(store.get_cached("stale_after_s")):
        return False
    since = bus.last_moving_at or bus.started_at
    return (now - since).total_seconds() >= float(store.get_cached("stopped_alert_after_s"))


async def reconcile(app: Any, con: asyncpg.Connection, bus: BusLive, now: datetime) -> None:
    """Open, notify or close the stop episode of one live bus."""
    event = await open_event(con, bus.trip_id)
    bus.stop_open = event is not None
    if event is not None:
        if bus.last_moving_at is not None and bus.last_moving_at > event["started_at"]:
            await _resume(app, con, bus, event)
        else:
            await _notify_driver(app, con, bus, event, now)
        return
    if not stationary(app, bus, now):
        return
    since = bus.last_moving_at or bus.started_at
    event_id = await con.fetchval(
        """insert into public.stop_events (trip_id, started_at) values ($1, $2)
           on conflict (trip_id) where ended_at is null do nothing returning id""",
        bus.trip_id, since,
    )
    if event_id is None:
        return  # another pass opened it first
    bus.stop_open = True
    if bus.status == "on_time":
        row = await load_trip(con, bus.trip_id)
        if row is not None and row["ended_at"] is None:
            await set_status(app, con, row, "delayed", AUTO_NOTE)
            await con.execute("update public.stop_events set auto_marked = true where id = $1", event_id)
    event = await open_event(con, bus.trip_id)
    if event is not None:
        await _notify_driver(app, con, bus, event, now)


async def _notify_driver(app: Any, con: asyncpg.Connection, bus: BusLive, event: asyncpg.Record,
                         now: datetime) -> None:
    """One push per episode, sent once the driver's prefs allow it (a snooze that ends mid-stop still prompts)."""
    if event["driver_notified_at"] is not None or event["reason"] is not None:
        return
    enabled, snooze_until = await driver_prefs(con, bus.driver_id)
    if not prompt_allowed(enabled, snooze_until, now):
        return
    minutes = max(1, round((now - event["started_at"]).total_seconds() / 60))
    try:
        get_push(app).submit(PushJob(
            title="Your bus has stopped",
            body=f"Stopped for about {minutes} min. Tap to tell students why.",
            tag=STOP_TAG, user_ids=(bus.driver_id,),
            data={"type": STOP_TAG, "trip_id": str(bus.trip_id), "stop_event_id": str(event["id"])},
        ))
    except Exception:
        log.exception("stop alert push for trip %s failed", bus.trip_id)
        return
    await con.execute("update public.stop_events set driver_notified_at = $2 where id = $1", event["id"], now)


async def _resume(app: Any, con: asyncpg.Connection, bus: BusLive, event: asyncpg.Record) -> None:
    """The bus moves again: close the episode; clear a status the server set itself, never a driver's."""
    closed = await con.fetchrow(
        "update public.stop_events set ended_at = $2 where id = $1 and ended_at is null returning auto_marked",
        event["id"], bus.last_moving_at,
    )
    bus.stop_open = False
    if closed is None:
        return
    if closed["auto_marked"] and bus.status == "delayed" and bus.note == AUTO_NOTE:
        row = await load_trip(con, bus.trip_id)
        if row is not None and row["ended_at"] is None:
            await set_status(app, con, row, "on_time", None)


async def mark_driver_set(con: asyncpg.Connection, trip_id: UUID) -> None:
    """The driver changed the status by hand: an open episode's auto status must not be cleared later."""
    await con.execute(
        "update public.stop_events set auto_marked = false where trip_id = $1 and ended_at is null", trip_id)


async def record_reason(app: Any, con: asyncpg.Connection, trip: asyncpg.Record, reason: str,
                        note: str | None, now: datetime) -> asyncpg.Record:
    """The driver says why the bus is stopped: store it and show it to students as the trip status/note."""
    text = (note or "").strip() or REASON_NOTE[reason]
    async with con.transaction():
        event = await open_event(con, trip["id"])
        if event is None:
            await con.execute("insert into public.stop_events (trip_id, started_at) values ($1, $2)",
                              trip["id"], now)
        await con.execute(
            """update public.stop_events set reason = $2, note = $3, auto_marked = false
               where trip_id = $1 and ended_at is null""",
            trip["id"], reason, (note or "").strip() or None,
        )
    await set_status(app, con, trip, "breakdown" if reason == "breakdown" else "delayed", text)
    event = await open_event(con, trip["id"])
    assert event is not None
    return event


def snooze_until(minutes: int, now: datetime) -> datetime | None:
    return now + timedelta(minutes=minutes) if minutes else None
