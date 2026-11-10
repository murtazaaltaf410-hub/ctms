"""Student pickup pins and the driver's waiting list (ADR-9, requirements X2-X3).

POST   /pickups               student: place a pin for a route and leg (replaces the waiting one)
GET    /me/pickup             student: my waiting request (with its decision), or null
GET    /me/eta                student: ETAs of my route's buses to my pickup pin, else to the route's first stop
DELETE /pickups/{id}          student: cancel my waiting request
GET    /trips/{id}/pickups    driver:  students waiting on this trip's route and leg
POST   /pickups/{id}/decision driver:  accept or reject a pin from a student of another bus (V1.3 decision 9)

A pin is temporary: it expires after `pickup_request_ttl_s`, and it never changes a route.
The driver sees location, label and distance. Only a `needs_decision` (or accepted) pin from a student of
another bus also carries a student card (name, department, enrollment number, photo flag).
"""

from __future__ import annotations

from datetime import timedelta
from typing import Annotated, Literal
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Depends, Request, Response, status
from pydantic import Field

from app import clock
from app.db import Conn
from app.deps import CurrentUser, require_role
from app.errors import NotFound, ValidationFailed
from app.geo import haversine_m
from app.geo.snap import snap_forward
from app.live.state import RouteGeom, get_live
from app.modules.pickups.decisions import (
    effective_decision_sql,
    flag_for_active_trips,
    identity_sql,
    notify_student,
)
from app.modules.students.service import ApprovedStudent, approved_route_id
from app.modules.trips.service import active_trip_for_driver as service_active_trip
from app.modules.trips.service import owned_active_trip
from app.schemas import ApiModel, UtcDateTime

router = APIRouter(tags=["pickups"])

Student = Annotated[CurrentUser, Depends(require_role("student"))]
Driver = Annotated[CurrentUser, Depends(require_role("driver"))]
Direction = Literal["to_campus", "from_campus"]
Decision = Literal["auto", "needs_decision", "accepted", "rejected"]


class PickupIn(ApiModel):
    route_id: UUID
    direction: Direction = "to_campus"
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    label: str | None = Field(default=None, min_length=1, max_length=60, description="e.g. 'Near the mosque'")


class PickupOut(ApiModel):
    id: UUID
    route_id: UUID
    route_name: str
    direction: Direction
    lat: float
    lng: float
    label: str | None
    status: Literal["waiting", "picked_up", "cancelled", "expired"]
    decision: Decision = Field(description="auto | needs_decision (waiting for a driver) | accepted | rejected")
    decided_at: UtcDateTime | None
    created_at: UtcDateTime
    expires_at: UtcDateTime


class StudentCard(ApiModel):
    student_id: UUID
    name: str
    department: str | None
    enrollment_no: str | None
    has_photo: bool


class WaitingStudent(ApiModel):
    id: UUID
    lat: float
    lng: float
    label: str | None
    distance_m: float | None = Field(description="Straight-line distance from the bus, when it has a position")
    created_at: UtcDateTime
    decision: Decision = Field(description="As this trip's bus sees it: auto | needs_decision | accepted")
    student: StudentCard | None = Field(description="Set for needs_decision and accepted pins of another bus's student")


class DecisionIn(ApiModel):
    decision: Literal["accept", "reject"]


class DecisionOut(ApiModel):
    id: UUID
    decision: Literal["accepted", "rejected"]


class WaitingOut(ApiModel):
    items: list[WaitingStudent]


_SELECT = """
select p.id, p.route_id, r.name as route_name, p.direction, p.lat, p.lng, p.label, p.status,
       p.decision, p.decided_at, p.created_at, p.expires_at
  from public.pickup_requests p join public.routes r on r.id = p.route_id
"""


async def _route_geom(con: asyncpg.Connection, route_id: UUID) -> RouteGeom:
    row = await con.fetchrow(
        "select id, name, polyline, cum_dist_m from public.routes where id = $1 and active and status = 'active'",
        route_id,
    )
    if row is None:
        raise ValidationFailed("route_id: route is unknown, draft or inactive")
    geom = RouteGeom.from_row(row["id"], row["name"], row["polyline"], row["cum_dist_m"])
    if not geom.usable:
        raise ValidationFailed("route_id: route has no usable line")
    return geom


@router.post("/pickups", response_model=PickupOut, status_code=status.HTTP_201_CREATED)
async def create_pickup(body: PickupIn, request: Request, user: ApprovedStudent, con: Conn) -> PickupOut:
    """Place a pickup pin. It must lie close to the route line; a student has one waiting pin at a time.
    Needs an approved registration, and the pin's route must be the one on the student's profile."""
    if body.route_id != await approved_route_id(con, user.id):
        raise ValidationFailed("route_id: must be the route on your registration")
    store = request.app.state.settings_store
    geom = await _route_geom(con, body.route_id)
    max_offset = float(store.get_cached("pickup_max_route_distance_m"))
    offset = snap_forward(geom.points, geom.cum, body.lat, body.lng,
                          tie_tolerance_m=float(store.get_cached("snap_tie_tolerance_m"))).offset_m
    if offset > max_offset:
        raise ValidationFailed(
            f"lat/lng: the pin is {offset:.0f} m from the route; it must be within {max_offset:.0f} m"
        )
    now = clock.now()
    expires_at = now + timedelta(seconds=float(store.get_cached("pickup_request_ttl_s")))
    async with con.transaction():
        await con.execute(
            "update public.pickup_requests set status = 'cancelled' where student_id = $1 and status = 'waiting'",
            user.id,
        )
        pickup_id = await con.fetchval(
            """insert into public.pickup_requests (student_id, route_id, direction, lat, lng, label, expires_at)
               values ($1, $2, $3, $4, $5, $6, $7) returning id""",
            user.id, body.route_id, body.direction, body.lat, body.lng, body.label, expires_at,
        )
    await flag_for_active_trips(request.app, con, body.route_id, body.direction, pickup_id)
    row = await con.fetchrow(_SELECT + " where p.id = $1", pickup_id)
    return PickupOut(**dict(row))


@router.get("/me/pickup", response_model=PickupOut | None)
async def my_pickup(request: Request, user: ApprovedStudent, con: Conn) -> PickupOut | None:
    """My waiting pin with its decision. A pin a driver rejected is still returned (status `cancelled`,
    decision `rejected`) for `pickup_request_ttl_s` after the decision, so the app can tell me why it vanished."""
    now = clock.now()
    row = await con.fetchrow(
        _SELECT + " where p.student_id = $1 and p.status = 'waiting' and p.expires_at > $2", user.id, now)
    if row is None:
        ttl = float(request.app.state.settings_store.get_cached("pickup_request_ttl_s"))
        row = await con.fetchrow(
            _SELECT + """ where p.student_id = $1 and p.decision = 'rejected' and p.decided_at > $2
                          and not exists (select 1 from public.pickup_requests n
                                           where n.student_id = $1 and n.created_at > p.created_at)
                          order by p.decided_at desc limit 1""",  # noqa: S608
            user.id, now - timedelta(seconds=ttl),
        )
    return None if row is None else PickupOut(**dict(row))


@router.delete("/pickups/{pickup_id}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def cancel_pickup(pickup_id: UUID, user: Student, con: Conn) -> Response:
    cancelled = await con.fetchval(
        """update public.pickup_requests set status = 'cancelled'
           where id = $1 and student_id = $2 and status = 'waiting' returning id""",
        pickup_id, user.id,
    )
    if cancelled is None:
        raise NotFound("Pickup request not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/trips/{trip_id}/pickups", response_model=WaitingOut)
async def waiting_students(trip_id: UUID, request: Request, user: Driver, con: Conn) -> WaitingOut:
    """Students with a waiting pin on this trip's route and leg, nearest to the bus first.
    `decision` is what this trip's bus sees: `needs_decision` for a student of another bus (with a `student`
    card to decide on), `accepted` once accepted, else `auto`."""
    trip = await owned_active_trip(con, user.id, trip_id)
    enrollment, has_photo = await identity_sql(con)
    rows = await con.fetch(
        f"""select p.id, p.lat, p.lng, p.label, p.created_at, p.student_id, sp.full_name, sp.department,
                   {enrollment} as enrollment_no, {has_photo} as has_photo,
                   {effective_decision_sql("$4")} as decision
              from public.pickup_requests p
              left join public.student_profiles sp on sp.user_id = p.student_id
             where p.route_id = $1 and p.direction = $2 and p.status = 'waiting' and p.expires_at > $3
             order by p.created_at""",  # noqa: S608
        trip["route_id"], trip["direction"], clock.now(), trip["bus_id"],
    )
    bus = get_live(request.app).by_trip(trip_id)
    here = (bus.lat, bus.lng) if bus is not None and bus.has_position else None
    items = [
        WaitingStudent(
            id=r["id"], lat=r["lat"], lng=r["lng"], label=r["label"], created_at=r["created_at"],
            distance_m=None if here is None else round(haversine_m(here[0], here[1], r["lat"], r["lng"]), 1),
            decision=r["decision"],
            student=StudentCard(student_id=r["student_id"], name=r["full_name"] or "Student",
                                department=r["department"], enrollment_no=r["enrollment_no"],
                                has_photo=r["has_photo"])
            if r["decision"] in ("needs_decision", "accepted") else None,
        )
        for r in rows
    ]
    items.sort(key=lambda s: (s.distance_m is None, s.distance_m or 0.0))
    return WaitingOut(items=items)


@router.post("/pickups/{pickup_id}/decision", response_model=DecisionOut)
async def decide_pickup(pickup_id: UUID, body: DecisionIn, request: Request, user: Driver,
                        con: Conn) -> DecisionOut:
    """Accept or reject a pin from a student of another bus. The pin must be waiting on the route and leg of
    the driver's active trip and not belong to the driver's own bus (404 otherwise). A rejected pin is
    removed (the student sees `decision: rejected` on GET /me/pickup); accepting again is a no-op."""
    trip = await service_active_trip(con, user.id)
    if trip is None:
        raise NotFound("No active trip")
    row = await con.fetchrow(
        """select p.id, p.student_id, p.decision from public.pickup_requests p
             join public.student_profiles sp on sp.user_id = p.student_id
            where p.id = $1 and p.status = 'waiting' and p.expires_at > $2
              and p.route_id = $3 and p.direction = $4
              and sp.bus_id is not null and sp.bus_id <> $5 and p.decision in ('needs_decision', 'accepted')""",
        pickup_id, clock.now(), trip["route_id"], trip["direction"], trip["bus_id"],
    )
    if row is None:
        raise NotFound("Pickup request not found or not waiting for a decision")
    accepted = body.decision == "accept"
    now = clock.now()
    await con.execute(
        """update public.pickup_requests
              set decision = $2, status = case when $3 then status else 'cancelled' end, decided_at = $4
            where id = $1""",
        pickup_id, "accepted" if accepted else "rejected", accepted, now,
    )
    if row["decision"] != ("accepted" if accepted else "rejected"):
        notify_student(request.app, row["student_id"], trip, accepted, now)
    return DecisionOut(id=pickup_id, decision="accepted" if accepted else "rejected")
