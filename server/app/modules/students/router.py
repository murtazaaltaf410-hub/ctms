"""Student registration (ADR-10): GET/PUT /me/registration, GET /routes/nearest, driver roster.

GET /me/registration           student: my registration, or null before the first submit
PUT /me/registration           student: create or update; a re-submit while pending/rejected goes back to
                               pending and clears the admin's note. An approved student may change name,
                               phone and department only; route and bus change through the admin.
PUT /me/registration/photo     student: raw JPEG/PNG body (<= student_photo_max_bytes), until approved
GET /students/{id}/photo       the student, an admin, or the driver of the student's bus (or of a pickup decision)
GET /routes/nearest?lat&lng    student: the active route whose line is closest to a point (null if too far)
GET /trips/{id}/roster         driver:  name and department of approved students on the trip's bus
                               (never phone numbers or e-mail)

This router is included before the routes router so "/routes/nearest" is not read as a route id.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request, Response

from app.audit import write_audit
from app.db import Conn
from app.deps import AuthUser, CurrentUser, require_role
from app.errors import ForbiddenRole, InUse, NotFound, ValidationFailed
from app.geo.snap import snap_forward
from app.live.state import RouteGeom
from app.modules.students.photos import read_image
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
            """select status, route_id, requested_bus_label, enrollment_no
                 from public.student_profiles where user_id = $1 for update""",
            user.id,
        )
        route_ok = await con.fetchval(
            "select exists(select 1 from public.routes where id = $1 and active and status = 'active')",
            body.route_id)
        if current is not None and current["status"] == "approved":
            if (body.route_id != current["route_id"] or body.requested_bus_label != current["requested_bus_label"]
                    or body.enrollment_no != current["enrollment_no"]):
                raise InUse("An approved registration cannot change route, bus or enrollment number; "
                            "ask an admin to reassign you")
            await con.execute(
                """update public.student_profiles set full_name = $2, phone = $3, department = $4, home_address = $5
                    where user_id = $1""",
                user.id, body.full_name, body.phone, body.department, body.home_address)
        else:
            # The route is chosen once: after the first submission only a rejected student may pick another.
            if current is not None and current["status"] != "rejected" and current["route_id"] != body.route_id:
                raise InUse("The route is locked once registered; ask an admin to reassign you")
            if not route_ok:
                raise ValidationFailed("route_id: route is unknown, draft or inactive")
            await con.execute(
                """insert into public.student_profiles
                     (user_id, full_name, phone, department, enrollment_no, home_address, route_id,
                      requested_bus_label, claims_registered)
                   values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                   on conflict (user_id) do update set
                     full_name = excluded.full_name, phone = excluded.phone, department = excluded.department,
                     enrollment_no = excluded.enrollment_no, home_address = excluded.home_address,
                     route_id = excluded.route_id, requested_bus_label = excluded.requested_bus_label,
                     claims_registered = excluded.claims_registered, status = 'pending', bus_id = null,
                     admin_note = null, reviewed_by = null, reviewed_at = null""",
                user.id, body.full_name, body.phone, body.department, body.enrollment_no, body.home_address,
                body.route_id, body.requested_bus_label, body.claims_registered)
            await write_audit(con, actor_id=user.id, action="student.register", target_type="user",
                              target_id=user.id, meta={"claims_registered": body.claims_registered})
    row = await load_profile(con, user.id)
    return RegistrationOut(**dict(row))


@router.put("/me/registration/photo", response_model=RegistrationOut,
            openapi_extra={"requestBody": {"required": True, "content": {
                "image/jpeg": {"schema": {"type": "string", "format": "binary"}},
                "image/png": {"schema": {"type": "string", "format": "binary"}}}}})
async def put_registration_photo(request: Request, user: Student, con: Conn) -> RegistrationOut:
    """Raw JPEG or PNG body. The registration must exist (submit it first) and not be approved yet: after
    approval the photo is the one the admin reviewed."""
    data, mime = await read_image(request)
    async with con.transaction():
        status = await con.fetchval(
            "select status from public.student_profiles where user_id = $1 for update", user.id)
        if status is None:
            raise NotFound("Submit your registration before uploading the photo")
        if status == "approved":
            raise InUse("An approved registration's photo cannot be changed; ask an admin")
        await con.execute(
            """update public.student_profiles set photo = $2, photo_mime = $3, photo_updated_at = now()
                where user_id = $1""", user.id, data, mime)
        await write_audit(con, actor_id=user.id, action="student.photo", target_type="user", target_id=user.id)
    return RegistrationOut(**dict(await load_profile(con, user.id)))


async def driver_may_view_student(con, driver_id: UUID, student_id: UUID) -> bool:
    """A driver sees the photo of students on their bus, and of a student whose waiting pickup needs the
    driver's decision on one of the driver's running trips (V1.3 decision 9). `decision` is added by
    migration 0012, so it is read through to_jsonb and is simply absent before that migration."""
    return bool(await con.fetchval(
        """select exists(select 1 from public.student_profiles sp
                           join public.buses b on b.id = sp.bus_id
                          where sp.user_id = $2 and sp.status = 'approved' and b.driver_id = $1)
               or exists(select 1 from public.pickup_requests pr
                           join public.trips t on t.route_id = pr.route_id and t.direction = pr.direction
                          where pr.student_id = $2 and pr.status = 'waiting'
                            and to_jsonb(pr) ->> 'decision' = 'needs_decision'
                            and t.driver_id = $1 and t.ended_at is null)""",
        driver_id, student_id))


@router.get("/students/{student_id}/photo", response_class=Response,
            responses={200: {"content": {"image/jpeg": {}, "image/png": {}}}})
async def get_student_photo(student_id: UUID, user: AuthUser, con: Conn) -> Response:
    allowed = (user.role == "admin" or user.id == student_id
               or (user.role == "driver" and await driver_may_view_student(con, user.id, student_id)))
    if not allowed:
        raise ForbiddenRole("You may not view this photo")
    row = await con.fetchrow(
        "select photo, photo_mime from public.student_profiles where user_id = $1 and photo is not null", student_id)
    if row is None:
        raise NotFound("No photo")
    return Response(content=bytes(row["photo"]), media_type=row["photo_mime"],
                    headers={"Cache-Control": "private, no-store"})


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
        """select user_id, full_name, department, enrollment_no, photo is not null as has_photo
           from public.student_profiles
           where bus_id = $1 and status = 'approved' order by lower(full_name), user_id""",
        trip["bus_id"])
    return RosterOut(items=[RosterStudent(student_id=r["user_id"], name=r["full_name"], department=r["department"],
                                         enrollment_no=r["enrollment_no"], has_photo=r["has_photo"]) for r in rows])
