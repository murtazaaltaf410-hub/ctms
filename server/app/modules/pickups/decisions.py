"""Pickup decisions (V1.3 decision 9).

A pickup pin from an approved student whose assigned bus is NOT the trip's bus is `needs_decision`: the
driver gets a push "Unknown student wants a pickup", sees a student card and accepts or rejects. A student
with no bus yet, or whose own bus is running that route and leg, stays `auto` (the existing behaviour).
`decision` is stored on the pin; what a given driver sees is `effective_decision` (the student's own bus
always sees `auto`).
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any
from uuid import UUID

import asyncpg

from app import clock
from app.push import PushJob, get_push

log = logging.getLogger("ctms.pickups")

DECISION_TAG = "pickup_decision"
RESULT_TAG = "pickup_decision_result"

# Identity columns arrive with migration 0011; read them defensively so this works before it is applied.
_IDENTITY: dict[str, tuple[str, str]] = {}


async def identity_sql(con: asyncpg.Connection) -> tuple[str, str]:
    """SQL fragments (enrollment number, has-photo flag) over `student_profiles sp`."""
    if "sql" in _IDENTITY:
        return _IDENTITY["sql"]
    cols = {r["column_name"] for r in await con.fetch(
        """select column_name from information_schema.columns
            where table_schema = 'public' and table_name = 'student_profiles'
              and column_name in ('enrollment_no', 'photo')""")}
    sql = ("sp.enrollment_no" if "enrollment_no" in cols else "null::text",
           "(sp.photo is not null)" if "photo" in cols else "false")
    if len(cols) == 2:
        _IDENTITY["sql"] = sql
    return sql


def effective_decision_sql(trip_bus_param: str) -> str:
    """`decision` as the viewing trip's bus sees it (a student's own bus always sees `auto`)."""
    return f"case when sp.bus_id is null or sp.bus_id = {trip_bus_param} then 'auto' else p.decision end"


async def flag_unknown_pickups(app: Any, con: asyncpg.Connection, trip: asyncpg.Record,
                               pickup_id: UUID | None = None) -> list[UUID]:
    """Mark waiting pins on this trip's route and leg that this bus does not own as `needs_decision`, and
    push the driver once per pin. Never raises into the caller's flow (a push failure is only logged)."""
    rows = await con.fetch(
        """update public.pickup_requests p set decision = 'needs_decision'
             from public.student_profiles sp
            where sp.user_id = p.student_id and sp.status = 'approved'
              and sp.bus_id is not null and sp.bus_id <> $3
              and p.status = 'waiting' and p.decision = 'auto'
              and p.route_id = $1 and p.direction = $2 and p.expires_at > $4
              and ($5::uuid is null or p.id = $5)
              and not exists (select 1 from public.trips t
                               where t.bus_id = sp.bus_id and t.ended_at is null
                                 and t.route_id = $1 and t.direction = $2)
        returning p.id""",
        trip["route_id"], trip["direction"], trip["bus_id"], clock.now(), pickup_id,
    )
    ids = [r["id"] for r in rows]
    for pid in ids:
        try:
            get_push(app).submit(PushJob(
                title="Unknown student wants a pickup",
                body="A student from another bus asked to be picked up. Open the pickup list to accept or reject.",
                tag=DECISION_TAG, user_ids=(trip["driver_id"],),
                data={"type": DECISION_TAG, "trip_id": str(trip["id"]), "request_id": str(pid)},
            ))
        except Exception:
            log.exception("pickup decision push for pin %s failed", pid)
    return ids


async def flag_for_active_trips(app: Any, con: asyncpg.Connection, route_id: UUID, direction: str,
                                pickup_id: UUID) -> None:
    trips = await con.fetch(
        """select id, route_id, direction, bus_id, driver_id from public.trips
            where route_id = $1 and direction = $2 and ended_at is null""", route_id, direction)
    for trip in trips:
        await flag_unknown_pickups(app, con, trip, pickup_id)


def notify_student(app: Any, student_id: UUID, trip: asyncpg.Record, accepted: bool, at: datetime) -> None:
    try:
        get_push(app).submit(PushJob(
            title="Pickup request accepted" if accepted else "Pickup request declined",
            body=(f"{trip['bus_label']} will pick you up." if accepted
                  else f"{trip['bus_label']} cannot pick you up. Try another bus."),
            tag=RESULT_TAG, user_ids=(student_id,),
            data={"type": RESULT_TAG, "decision": "accepted" if accepted else "rejected",
                  "decided_at": at.isoformat()},
        ))
    except Exception:
        log.exception("pickup decision result push failed")
