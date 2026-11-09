"""Student registration (ADR-10): GET/PUT /me/registration, GET /routes/nearest, driver roster.

GET /me/registration           student: my registration, or null before the first submit
PUT /me/registration           student: create or update; a re-submit while pending/rejected goes back to
                               pending and clears the admin's note. An approved student may change name,
                               phone and department only; route and bus change through the admin.
GET /routes/nearest?lat&lng    student: the active route whose line is closest to a point (null if too far)
GET /trips/{id}/roster         driver:  name and department of approved students on the trip's bus
                               (never phone numbers or e-mail)

This router is included before the routes router so "/routes/nearest" is not read as a route id.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request

from app.audit import write_audit
from app.db import Conn
from app.deps import CurrentUser, require_role
from app.errors import InUse, ValidationFailed
from app.geo.snap import snap_forward
from app.live.state import RouteGeom
from app.modules.students.schemas import (
    NearestRouteOut,
    RegistrationIn,
    RegistrationOut,
    RosterOut,
    RosterStudent,
)
from app.modules.students.service import load_profile
from app.modules.trips.service import owned_active_trip

router = APIRouter(tags=["students"])

Student = Annotated[CurrentUser, Depends(require_role("student"))]
Driver = Annotated[CurrentUser, Depends(require_role("driver"))]


@router.get("/me/registration", response_model=RegistrationOut | None)
async def get_registration(user: Student, con: Conn) -> RegistrationOut | None:
    row = await load_profile(con, user.id)
    return None if row is None else RegistrationOut(**dict(row))


@router.put("/me/registration", response_model=RegistrationOut)
async def put_registration(body: RegistrationIn, user: Student, con: Conn) -> RegistrationOut:
    async with con.transaction():
        current = await con.fetchrow(
            "select status, route_id, requested_bus_label from public.student_profiles where user_id = $1 for update",
            user.id,
        )
        route_ok = await con.fetchval(
            "select exists(select 1 from public.routes where id = $1 and active and status = 'active')",
            body.route_id)
        if current is not None and current["status"] == "approved":
            if body.route_id != current["route_id"] or (
                    body.requested_bus_label != current["requested_bus_label"]):
                raise InUse("An approved registration cannot change route or bus; ask an admin to reassign you")
            await con.execute(
                "update public.student_profiles set full_name = $2, phone = $3, department = $4 where user_id = $1",
                user.id, body.full_name, body.phone, body.department)
        else:
            if not route_ok:
                raise ValidationFailed("route_id: route is unknown, draft or inactive")
            await con.execute(
                """insert into public.student_profiles
                     (user_id, full_name, phone, department, route_id, requested_bus_label, claims_registered)
                   values ($1, $2, $3, $4, $5, $6, $7)
                   on conflict (user_id) do update set
                     full_name = excluded.full_name, phone = excluded.phone, department = excluded.department,
                     route_id = excluded.route_id, requested_bus_label = excluded.requested_bus_label,
                     claims_registered = excluded.claims_registered, status = 'pending', bus_id = null,
                     admin_note = null, reviewed_by = null, reviewed_at = null""",
                user.id, body.full_name, body.phone, body.department, body.route_id,
                body.requested_bus_label, body.claims_registered)
            await write_audit(con, actor_id=user.id, action="student.register", target_type="user",
                              target_id=user.id, meta={"claims_registered": body.claims_registered})
    row = await load_profile(con, user.id)
    return RegistrationOut(**dict(row))


@router.get("/routes/nearest", response_model=NearestRouteOut | None)
async def nearest_route(
    request: Request, user: Student, con: Conn,
    lat: Annotated[float, Query(ge=-90, le=90)],
    lng: Annotated[float, Query(ge=-180, le=180)],
) -> NearestRouteOut | None:
    """Preselects the route for the registration form from the student's detected location."""
    store = request.app.state.settings_store
    max_m = float(store.get_cached("nearest_route_max_m"))
    tie = float(store.get_cached("snap_tie_tolerance_m"))
    rows = await con.fetch(
        "select id, name, polyline, cum_dist_m from public.routes where active and status = 'active'")
    best: NearestRouteOut | None = None
    for row in rows:
        geom = RouteGeom.from_row(row["id"], row["name"], row["polyline"], row["cum_dist_m"])
        if not geom.usable:
            continue
        offset = snap_forward(geom.points, geom.cum, lat, lng, tie_tolerance_m=tie).offset_m
        if best is None or offset < best.offset_m:
            best = NearestRouteOut(route_id=row["id"], route_name=row["name"], offset_m=round(offset, 1))
    return best if best is not None and best.offset_m <= max_m else None


@router.get("/trips/{trip_id}/roster", response_model=RosterOut)
async def trip_roster(trip_id: UUID, user: Driver, con: Conn) -> RosterOut:
    """Approved students assigned to this trip's bus: name and department only."""
    trip = await owned_active_trip(con, user.id, trip_id)
    rows = await con.fetch(
        """select full_name, department from public.student_profiles
           where bus_id = $1 and status = 'approved' order by lower(full_name), user_id""",
        trip["bus_id"])
    return RosterOut(items=[RosterStudent(name=r["full_name"], department=r["department"]) for r in rows])
