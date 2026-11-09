"""Student pickup pins and the driver's waiting list (ADR-9, requirements X2-X3).

POST   /pickups               student: place a pin for a route and leg (replaces the waiting one)
GET    /me/pickup             student: my waiting request, or null
DELETE /pickups/{id}          student: cancel my waiting request
GET    /trips/{id}/pickups    driver:  students waiting on this trip's route and leg

A pin is temporary: it expires after `pickup_request_ttl_s`, and it never changes a route.
The driver sees location, label and distance only, never the student's identity.
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
from app.modules.students.service import ApprovedStudent, approved_route_id
from app.modules.trips.service import owned_active_trip
from app.schemas import ApiModel, UtcDateTime

router = APIRouter(tags=["pickups"])

Student = Annotated[CurrentUser, Depends(require_role("student"))]
Driver = Annotated[CurrentUser, Depends(require_role("driver"))]
Direction = Literal["to_campus", "from_campus"]


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
    created_at: UtcDateTime
    expires_at: UtcDateTime


class WaitingStudent(ApiModel):
    id: UUID
    lat: float
    lng: float
    label: str | None
    distance_m: float | None = Field(description="Straight-line distance from the bus, when it has a position")
    created_at: UtcDateTime


class WaitingOut(ApiModel):
    items: list[WaitingStudent]


_SELECT = """
select p.id, p.route_id, r.name as route_name, p.direction, p.lat, p.lng, p.label, p.status,
       p.created_at, p.expires_at
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
    row = await con.fetchrow(_SELECT + " where p.id = $1", pickup_id)
    return PickupOut(**dict(row))


@router.get("/me/pickup", response_model=PickupOut | None)
async def my_pickup(user: ApprovedStudent, con: Conn) -> PickupOut | None:
    row = await con.fetchrow(
        _SELECT + " where p.student_id = $1 and p.status = 'waiting' and p.expires_at > $2",
        user.id, clock.now(),
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
    """Students with a waiting pin on this trip's route and leg, nearest to the bus first."""
    trip = await owned_active_trip(con, user.id, trip_id)
    rows = await con.fetch(
        """select id, lat, lng, label, created_at from public.pickup_requests
           where route_id = $1 and direction = $2 and status = 'waiting' and expires_at > $3
           order by created_at""",
        trip["route_id"], trip["direction"], clock.now(),
    )
    bus = get_live(request.app).by_trip(trip_id)
    here = (bus.lat, bus.lng) if bus is not None and bus.has_position else None
    items = [
        WaitingStudent(
            id=r["id"], lat=r["lat"], lng=r["lng"], label=r["label"], created_at=r["created_at"],
            distance_m=None if here is None else round(haversine_m(here[0], here[1], r["lat"], r["lng"]), 1),
        )
        for r in rows
    ]
    items.sort(key=lambda s: (s.distance_m is None, s.distance_m or 0.0))
    return WaitingOut(items=items)
