"""Student registration helpers and the approval gate (ADR-10).

A student sees live buses, ETAs, alerts and pickups only once an admin has approved their
registration, and only for the route stored on their profile. The route is always read from
the profile in the database, never from the request.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

import asyncpg
from fastapi import Depends

from app.db import Conn
from app.deps import CurrentUser, require_role
from app.errors import RegistrationRequired

_Student = Annotated[CurrentUser, Depends(require_role("student"))]

PROFILE_SQL = """
select sp.user_id, sp.full_name, sp.phone, sp.department, sp.enrollment_no, sp.home_address,
       sp.photo is not null as has_photo,
       (nullif(trim(sp.full_name), '') is not null and nullif(trim(sp.phone), '') is not null
        and nullif(trim(sp.department), '') is not null and nullif(trim(sp.enrollment_no), '') is not null
        and nullif(trim(sp.home_address), '') is not null and sp.route_id is not null
        and sp.photo is not null) as complete,
       sp.route_id, r.name as route_name,
       sp.requested_bus_label, sp.claims_registered, sp.status, sp.bus_id, b.label as bus_label,
       sp.admin_note, sp.reviewed_at, sp.created_at, sp.updated_at
  from public.student_profiles sp
  left join public.routes r on r.id = sp.route_id
  left join public.buses b on b.id = sp.bus_id
"""


async def load_profile(con: asyncpg.Connection, user_id: UUID) -> asyncpg.Record | None:
    return await con.fetchrow(PROFILE_SQL + " where sp.user_id = $1", user_id)


# Stands for "no route" so an approved profile without one (never produced by the API, which always
# requires a route to approve) matches no bus instead of every bus.
NO_ROUTE = UUID(int=0)


async def approved_route_id(con: asyncpg.Connection, user_id: UUID) -> UUID:
    """The route of an approved student; REGISTRATION_REQUIRED for none, pending or rejected."""
    row = await con.fetchrow("select status, route_id from public.student_profiles where user_id = $1", user_id)
    if row is None or row["status"] != "approved":
        raise RegistrationRequired()
    return row["route_id"] or NO_ROUTE


async def student_scope(con: asyncpg.Connection, user: CurrentUser) -> UUID | None:
    """Route a user may see: the approved profile's route for a student (REGISTRATION_REQUIRED
    otherwise), None (= every route) for drivers and admins."""
    if user.role != "student":
        return None
    return await approved_route_id(con, user.id)


async def approved_student(user: _Student, con: Conn) -> CurrentUser:
    """Dependency: a student whose registration is approved."""
    await approved_route_id(con, user.id)
    return user


ApprovedStudent = Annotated[CurrentUser, Depends(approved_student)]
