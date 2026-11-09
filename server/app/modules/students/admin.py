"""Admin student management (ADR-10): list, summary, approve, reject, reassign.

Approve and reassign run in ONE transaction that locks the student's profile and then the bus row
(`select ... for update`), so two admins competing for the last seat are serialised: exactly one
wins and the other gets 409 NO_SEAT. A bus must be active, run the student's route
(`buses.default_route_id`, or any route its driver is assigned to in `driver_route_assignments`: the
driver runs one at a time but the bus has ONE pool of seats), have a capacity set (null = not set ->
NO_SEAT) and a free seat.
There is no attendance tracking: only registration, assignment, roster and seat counts.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Query, Request

from app import clock
from app.audit import write_audit
from app.db import Conn
from app.errors import NoSeat, NotFound, ValidationFailed
from app.live.hub import get_hub
from app.modules.admin.common import AdminUser, Cursor, Limit, decode_cursor, page_limit, paginate
from app.modules.students.schemas import (
    AdminStudent,
    AdminStudentPage,
    ApproveIn,
    BusSeats,
    RejectIn,
    RouteTotals,
    StatusCounts,
    StudentSummary,
)
from app.modules.students.schemas import Status as StudentStatus

router = APIRouter(prefix="/admin/students", tags=["admin: students"])

_SELECT = """
select u.id, coalesce(sp.full_name, u.name, 'Student') as full_name, u.email, sp.phone, sp.department,
       sp.route_id, r.name as route_name,
       sp.requested_bus_label, coalesce(sp.claims_registered, false) as claims_registered,
       sp.status, sp.bus_id, b.label as bus_label,
       sp.admin_note, sp.reviewed_at, coalesce(sp.created_at, u.created_at) as created_at,
       case
         when sp.user_id is null then 'unregistered'
         when nullif(trim(sp.full_name), '') is null
           or nullif(trim(sp.phone), '') is null
           or nullif(trim(sp.department), '') is null
           or sp.route_id is null then 'incomplete'
         else 'registered'
       end as registration_state,
       case
         when sp.user_id is null then 'Student has not submitted a registration.'
         when nullif(trim(sp.full_name), '') is null
           or nullif(trim(sp.phone), '') is null
           or nullif(trim(sp.department), '') is null
           or sp.route_id is null then 'Registration is incomplete: name, phone, department, or route is missing.'
         else null
       end as approval_diagnostic
  from public.users u
  left join public.student_profiles sp on sp.user_id = u.id
  left join public.routes r on r.id = sp.route_id
  left join public.buses b on b.id = sp.bus_id
"""


async def load_student(con: asyncpg.Connection, student_id: UUID) -> AdminStudent:
    row = await con.fetchrow(_SELECT + " where u.id = $1 and u.role = 'student'", student_id)
    if row is None:
        raise NotFound("Student registration not found")
    return AdminStudent(**dict(row))


def _like(q: str) -> str:
    escaped = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


@router.get("", response_model=AdminStudentPage)
async def list_students(
    request: Request, user: AdminUser, con: Conn, cursor: Cursor = None, limit: Limit = None,
    status: Annotated[StudentStatus | None, Query()] = None,
    route_id: UUID | None = None, bus_id: UUID | None = None,
    q: Annotated[str | None, Query(max_length=100, description="Search name, e-mail, phone, department")] = None,
) -> AdminStudentPage:
    n = page_limit(request, limit)
    after: tuple[datetime, UUID] | None = decode_cursor(cursor)
    pattern = _like(q.strip()) if q and q.strip() else None
    rows = await con.fetch(
        _SELECT + """
        where u.role = 'student'
          and ($1::text is null or sp.status = $1)
          and ($2::uuid is null or sp.route_id = $2)
          and ($3::uuid is null or sp.bus_id = $3)
           and ($4::text is null or coalesce(sp.full_name, u.name, '') ilike $4 or u.email ilike $4 or sp.phone ilike $4
               or sp.department ilike $4)
           and ($5::timestamptz is null or (coalesce(sp.created_at, u.created_at), u.id) > ($5, $6))
        order by coalesce(sp.created_at, u.created_at), u.id limit $7""",
        status, route_id, bus_id, pattern,
        after[0] if after else None, after[1] if after else None, n + 1,
    )
    page, next_cursor = paginate(rows, n, "created_at")
    return AdminStudentPage(items=[AdminStudent(**dict(r)) for r in page], next_cursor=next_cursor)


@router.get("/summary", response_model=StudentSummary)
async def summary(user: AdminUser, con: Conn) -> StudentSummary:
    """Counts by status, seats per bus and totals per route. Counts only, no attendance."""
    counts = {r["status"]: r["n"] for r in await con.fetch(
        "select status, count(*)::int as n from public.student_profiles group by status")}
    unregistered = await con.fetchval(
        """select count(*)::int from public.users u
             where u.role = 'student'
               and not exists (select 1 from public.student_profiles sp where sp.user_id = u.id)""")
    totals = StatusCounts(unregistered=unregistered, pending=counts.get("pending", 0),
                           approved=counts.get("approved", 0), rejected=counts.get("rejected", 0),
                           total=sum(counts.values()) + unregistered)
    buses = await con.fetch(
        """select b.id as bus_id, b.label, b.default_route_id as route_id, b.capacity,
                  coalesce((select array_agg(distinct x) from (
                              select b.default_route_id as x
                              union select dra.route_id from public.driver_route_assignments dra
                                     where dra.driver_id = b.driver_id) s where x is not null), '{}') as route_ids,
                  (select count(*)::int from public.student_profiles sp
                    where sp.bus_id = b.id and sp.status = 'approved') as assigned
             from public.buses b where b.active order by b.label, b.id""")
    routes = await con.fetch(
        """select r.id as route_id, r.name as route_name,
                  count(*) filter (where sp.status = 'pending')::int as pending,
                  count(*) filter (where sp.status = 'approved')::int as approved,
                  count(*) filter (where sp.status = 'rejected')::int as rejected
             from public.routes r join public.student_profiles sp on sp.route_id = r.id
            group by r.id, r.name order by r.name, r.id""")
    return StudentSummary(
        totals=totals,
        buses=[BusSeats(bus_id=b["bus_id"], label=b["label"], route_id=b["route_id"], route_ids=b["route_ids"],
                        capacity=b["capacity"],
                        assigned=b["assigned"],
                        seats_left=None if b["capacity"] is None else max(0, b["capacity"] - b["assigned"]))
               for b in buses],
        routes=[RouteTotals(**dict(r)) for r in routes],
    )


@router.get("/{student_id}", response_model=AdminStudent)
async def get_student(student_id: UUID, user: AdminUser, con: Conn) -> AdminStudent:
    return await load_student(con, student_id)


async def _assign(request: Request, con: asyncpg.Connection, admin_id: UUID, student_id: UUID, bus_id: UUID,
                  *, reassign: bool) -> AdminStudent:
    async with con.transaction():
        prof = await con.fetchrow(
            """select full_name, phone, department, route_id, status, bus_id
                 from public.student_profiles where user_id = $1 for update""",
            student_id)
        if prof is None:
            raise NotFound("Student registration not found")
        if any(not isinstance(prof[field], str) or not prof[field].strip()
               for field in ("full_name", "phone", "department")) or prof["route_id"] is None:
            raise ValidationFailed("Student registration is incomplete; ask the student to complete it before approval")
        if reassign and prof["status"] != "approved":
            raise ValidationFailed("status: only an approved student can be reassigned; approve first")
        bus = await con.fetchrow(
            """select id, label, active, default_route_id, driver_id, capacity
                 from public.buses where id = $1 for update""",
            bus_id)
        if bus is None:
            raise NotFound("Bus not found")
        if not bus["active"]:
            raise ValidationFailed("bus_id: the bus is not active")
        serves = bus["default_route_id"] == prof["route_id"] or await con.fetchval(
            """select exists(select 1 from public.driver_route_assignments
                              where driver_id = $1 and route_id = $2)""",
            bus["driver_id"], prof["route_id"])
        if prof["route_id"] is None or not serves:
            raise ValidationFailed("bus_id: the bus does not run the student's route "
                                   "(bus route and student route differ)")
        if bus["capacity"] is None:
            raise NoSeat("The bus has no capacity set; set it before assigning students")
        assigned = await con.fetchval(
            """select count(*) from public.student_profiles
                where bus_id = $1 and status = 'approved' and user_id <> $2""", bus_id, student_id)
        if assigned >= bus["capacity"]:
            raise NoSeat(f"{bus['label']} is full ({assigned} of {bus['capacity']} seats taken)")
        await con.execute(
            """update public.student_profiles
                  set status = 'approved', bus_id = $2, admin_note = null, reviewed_by = $3, reviewed_at = $4
                where user_id = $1""",
            student_id, bus_id, admin_id, clock.now())
        await write_audit(
            con, actor_id=admin_id, action="student.reassign" if reassign else "student.approve",
            target_type="user", target_id=student_id,
            meta={"bus_id": str(bus_id), "from_bus_id": str(prof["bus_id"]) if prof["bus_id"] else None})
    get_hub(request.app).set_student_route(student_id, prof["route_id"])
    return await load_student(con, student_id)


@router.post("/{student_id}/approve", response_model=AdminStudent)
async def approve(student_id: UUID, body: ApproveIn, request: Request, user: AdminUser,
                  con: Conn) -> AdminStudent:
    return await _assign(request, con, user.id, student_id, body.bus_id, reassign=False)


@router.post("/{student_id}/reassign", response_model=AdminStudent)
async def reassign(student_id: UUID, body: ApproveIn, request: Request, user: AdminUser,
                   con: Conn) -> AdminStudent:
    return await _assign(request, con, user.id, student_id, body.bus_id, reassign=True)


@router.post("/{student_id}/reject", response_model=AdminStudent)
async def reject(student_id: UUID, body: RejectIn, request: Request, user: AdminUser,
                 con: Conn) -> AdminStudent:
    async with con.transaction():
        updated = await con.fetchval(
            """update public.student_profiles
                  set status = 'rejected', bus_id = null, admin_note = $2, reviewed_by = $3, reviewed_at = $4
                where user_id = $1 returning user_id""",
            student_id, body.note, user.id, clock.now())
        if updated is None:
            raise NotFound("Student registration not found")
        await write_audit(con, actor_id=user.id, action="student.reject", target_type="user",
                          target_id=student_id)
    get_hub(request.app).set_student_route(student_id, None)
    return await load_student(con, student_id)
