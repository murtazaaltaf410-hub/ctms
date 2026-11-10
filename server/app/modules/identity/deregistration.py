"""Student deregistration (v13-spec decision 1): students cannot delete their account, they ask.

POST /me/deregistration-request      student: {reason?}; one pending request per student (a repeat returns it)
GET  /me/deregistration-request      student: my latest request, or null
GET  /admin/deregistrations?status   admin: requests, oldest first, with who asked (no address, no photo)
POST /admin/deregistrations/{id}/approve  admin: deletes the account and all its data, audited
POST /admin/deregistrations/{id}/reject   admin: {note}; the student may ask again
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Depends, Query, Request, Response
from pydantic import Field

from app import clock
from app.audit import write_audit
from app.db import Conn
from app.deps import CurrentUser, require_role
from app.errors import InUse, NotFound
from app.live import USER_DELETED, publish
from app.modules.admin.common import AdminUser, Cursor, Limit, decode_cursor, page_limit, paginate
from app.modules.me.accounts import delete_user_rows
from app.modules.students.schemas import DeregistrationOut
from app.schemas import ApiModel

router = APIRouter(tags=["deregistration"])
Student = Annotated[CurrentUser, Depends(require_role("student"))]

_COLUMNS = "id, status, reason, admin_note, created_at, reviewed_at"


class DeregistrationIn(ApiModel):
    reason: str | None = Field(default=None, min_length=1, max_length=500)


class RejectDeregistrationIn(ApiModel):
    note: str = Field(min_length=1, max_length=500)


class AdminDeregistration(DeregistrationOut):
    user_id: UUID
    name: str
    email: str | None
    enrollment_no: str | None
    department: str | None


class AdminDeregistrationPage(ApiModel):
    items: list[AdminDeregistration]
    next_cursor: str | None


@router.post("/me/deregistration-request", response_model=DeregistrationOut, status_code=201)
async def request_deregistration(body: DeregistrationIn, response: Response, user: Student,
                                 con: Conn) -> DeregistrationOut:
    async with con.transaction():
        # Serialise a double tap: the partial unique index is the last line of defence.
        await con.execute("select 1 from public.users where id = $1 for update", user.id)
        pending = await con.fetchrow(
            f"select {_COLUMNS} from public.deregistration_requests where user_id = $1 and status = 'pending'",  # noqa: S608
            user.id)
        if pending is not None:
            response.status_code = 200
            return DeregistrationOut(**dict(pending))
        row = await con.fetchrow(
            f"""insert into public.deregistration_requests (user_id, reason) values ($1, $2)
                returning {_COLUMNS}""",  # noqa: S608
            user.id, body.reason)
        await write_audit(con, actor_id=user.id, action="deregistration.request", target_type="user",
                          target_id=user.id)
    return DeregistrationOut(**dict(row))


@router.get("/me/deregistration-request", response_model=DeregistrationOut | None)
async def my_deregistration(user: Student, con: Conn) -> DeregistrationOut | None:
    row = await con.fetchrow(
        f"select {_COLUMNS} from public.deregistration_requests where user_id = $1 "  # noqa: S608
        "order by created_at desc, id limit 1", user.id)
    return None if row is None else DeregistrationOut(**dict(row))


_ADMIN_SELECT = """
select d.id, d.status, d.reason, d.admin_note, d.created_at, d.reviewed_at, d.user_id,
       coalesce(sp.full_name, u.name, 'Student') as name, u.email, sp.enrollment_no, sp.department
  from public.deregistration_requests d
  join public.users u on u.id = d.user_id
  left join public.student_profiles sp on sp.user_id = d.user_id
"""


@router.get("/admin/deregistrations", response_model=AdminDeregistrationPage)
async def list_deregistrations(
    request: Request, user: AdminUser, con: Conn, cursor: Cursor = None, limit: Limit = None,
    status: Annotated[Literal["pending", "approved", "rejected"] | None, Query()] = None,
) -> AdminDeregistrationPage:
    n = page_limit(request, limit)
    after: tuple[datetime, UUID] | None = decode_cursor(cursor)
    rows = await con.fetch(
        _ADMIN_SELECT + """
        where ($1::text is null or d.status = $1)
          and ($2::timestamptz is null or (d.created_at, d.id) > ($2, $3))
        order by d.created_at, d.id limit $4""",
        status, after[0] if after else None, after[1] if after else None, n + 1)
    page, next_cursor = paginate(rows, n, "created_at")
    return AdminDeregistrationPage(items=[AdminDeregistration(**dict(r)) for r in page], next_cursor=next_cursor)


async def _pending(con: asyncpg.Connection, request_id: UUID) -> asyncpg.Record:
    row = await con.fetchrow(_ADMIN_SELECT + " where d.id = $1 for update of d", request_id)
    if row is None:
        raise NotFound("Deregistration request not found")
    if row["status"] != "pending":
        raise InUse("This request was already reviewed")
    return row


@router.post("/admin/deregistrations/{request_id}/approve", response_model=AdminDeregistration)
async def approve_deregistration(request_id: UUID, request: Request, user: AdminUser,
                                 con: Conn) -> AdminDeregistration:
    """Deletes the student's account and every row that belongs to it. The response is the request as it
    was approved (the row itself goes with the account); the audit log keeps `deregistration.approve`."""
    async with con.transaction():
        row = await _pending(con, request_id)
        out = AdminDeregistration(**{**dict(row), "status": "approved", "reviewed_at": clock.now()})
        await delete_user_rows(con, row["user_id"], actor_id=user.id, action="deregistration.approve")
    await publish(request.app, USER_DELETED, user_id=row["user_id"])
    return out


@router.post("/admin/deregistrations/{request_id}/reject", response_model=AdminDeregistration)
async def reject_deregistration(request_id: UUID, body: RejectDeregistrationIn, user: AdminUser,
                                con: Conn) -> AdminDeregistration:
    async with con.transaction():
        row = await _pending(con, request_id)
        await con.execute(
            """update public.deregistration_requests
                  set status = 'rejected', admin_note = $2, reviewed_by = $3, reviewed_at = $4 where id = $1""",
            request_id, body.note, user.id, clock.now())
        await write_audit(con, actor_id=user.id, action="deregistration.reject", target_type="user",
                          target_id=row["user_id"])
    return AdminDeregistration(**dict(await con.fetchrow(_ADMIN_SELECT + " where d.id = $1", request_id)))
