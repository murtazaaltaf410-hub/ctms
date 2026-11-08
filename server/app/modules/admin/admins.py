"""GET/POST /admin/admins, DELETE /admin/admins/{id} (PRD A7, edge case U5, runbook: role changes logged).

`admin_allowlist` is the source of truth for admin (TRD p.4), plus SEED_ADMIN_EMAIL from the env.
* POST {email} adds the email to the allow-list and makes the matching account admin. If nobody has
  signed in with that email yet, an admin account without a Google link is created, so every admin
  has an id; the first Google sign-in with that email links it.
* DELETE removes the allow-list row, demotes the user to student and revokes their sessions.
  The last admin (including yourself while last) cannot be removed -> 409 LAST_ADMIN. The
  SEED_ADMIN_EMAIL admin always counts as an admin and can only be removed by changing the env.
"""

from __future__ import annotations

from uuid import UUID

import asyncpg
from fastapi import APIRouter, Request, Response, status
from pydantic import Field, field_validator

from app.audit import write_audit
from app.db import Conn
from app.errors import LastAdmin, NotFound, ValidationFailed
from app.modules.admin.common import AdminUser
from app.modules.auth.service import revoke_user_sessions
from app.schemas import ApiModel, UtcDateTime, utcnow

router = APIRouter(prefix="/admin/admins", tags=["admin: admins"])


class AdminIn(ApiModel):
    # Validated by hand: pydantic's EmailStr needs the email-validator package, which is not installed.
    email: str = Field(min_length=3, max_length=254)

    @field_validator("email")
    @classmethod
    def _email(cls, value: str) -> str:
        value = value.strip().lower()
        if "@" not in value or value.startswith("@") or value.endswith("@") or " " in value:
            raise ValueError("email must be a valid address")
        return value


class AdminOut(ApiModel):
    id: UUID | None = Field(description="null for an allow-listed email with no account yet")
    email: str
    name: str
    signed_in: bool = Field(description="Has signed in with Google at least once")
    seed: bool = Field(description="Configured by SEED_ADMIN_EMAIL (remove it from the env instead)")
    created_at: UtcDateTime | None


class AdminList(ApiModel):
    items: list[AdminOut]
    next_cursor: str | None = None


async def remaining_admins(con: asyncpg.Connection, seed_email: str | None, excluding: UUID) -> int:
    """Admins left if `excluding` were removed. SEED_ADMIN_EMAIL always counts once."""
    count = await con.fetchval(
        "select count(*) from public.users where role = 'admin' and active and id <> $1", excluding)
    if seed_email:
        seed_owner = await con.fetchrow(
            "select id, role, active from public.users where email = $1", seed_email)
        # An account already admin is in `count`; one not yet promoted becomes admin on its next sign-in.
        if seed_owner is None or (seed_owner["active"] and seed_owner["role"] != "admin"):
            count += 1
    return count


@router.get("", response_model=AdminList)
async def list_admins(request: Request, user: AdminUser, con: Conn) -> AdminList:
    seed = request.app.state.config.seed_admin_email
    rows = await con.fetch(
        """select u.id, u.email, u.name, u.google_sub is not null as signed_in, u.created_at
           from public.users u where u.role = 'admin' and u.active
           union all
           select null, a.email, '', false, a.created_at
           from public.admin_allowlist a
           where not exists (select 1 from public.users u where u.email = a.email and u.role = 'admin' and u.active)
           order by 5, 2""")
    items = [AdminOut(**dict(r), seed=r["email"] == seed) for r in rows]
    if seed and not any(i.email == seed for i in items):
        items.append(AdminOut(id=None, email=seed, name="", signed_in=False, seed=True, created_at=None))
    return AdminList(items=items)


@router.post("", response_model=AdminOut, status_code=status.HTTP_201_CREATED)
async def add_admin(body: AdminIn, request: Request, user: AdminUser, con: Conn) -> AdminOut:
    async with con.transaction():
        await con.execute(
            "insert into public.admin_allowlist (email, added_by) values ($1, $2) on conflict (email) do nothing",
            body.email, user.id,
        )
        row = await con.fetchrow("select id, role, active from public.users where email = $1 for update",
                                 body.email)
        if row is None:
            target_id = await con.fetchval(
                "insert into public.users (role, email) values ('admin', $1) returning id", body.email)
            await write_audit(con, actor_id=user.id, action="user.role_change", target_type="user",
                              target_id=target_id, meta={"from": None, "to": "admin", "reason": "admin_added"})
        else:
            target_id = row["id"]
            if row["role"] == "driver":
                raise ValidationFailed("email: belongs to a driver account")
            if not row["active"]:
                raise ValidationFailed("email: the account is deactivated")
            if row["role"] != "admin":
                await con.execute("update public.users set role = 'admin' where id = $1", target_id)
                await write_audit(con, actor_id=user.id, action="user.role_change", target_type="user",
                                  target_id=target_id,
                                  meta={"from": row["role"], "to": "admin", "reason": "admin_added"})
        await write_audit(con, actor_id=user.id, action="admin.add", target_type="user", target_id=target_id)
        out = await con.fetchrow(
            "select id, email, name, google_sub is not null as signed_in, created_at from public.users where id = $1",
            target_id)
    return AdminOut(**dict(out), seed=body.email == request.app.state.config.seed_admin_email)


@router.delete("/{admin_id}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def remove_admin(admin_id: UUID, request: Request, user: AdminUser, con: Conn) -> Response:
    seed = request.app.state.config.seed_admin_email
    async with con.transaction():
        # Serialise admin removals so two admins cannot remove each other at the same time.
        await con.execute("select pg_advisory_xact_lock(hashtext('ctms.admin_removal'))")
        row = await con.fetchrow("select id, email, role, active from public.users where id = $1 for update",
                                 admin_id)
        if row is None or row["role"] != "admin" or not row["active"]:
            raise NotFound("Admin not found")
        if seed and row["email"] == seed:
            raise ValidationFailed("This admin is configured by SEED_ADMIN_EMAIL on the server; change it there")
        if await remaining_admins(con, seed, admin_id) < 1:
            raise LastAdmin("The last admin cannot be removed; add another admin first")
        await con.execute("delete from public.admin_allowlist where email = $1", row["email"])
        await con.execute("update public.users set role = 'student' where id = $1", admin_id)
        await write_audit(con, actor_id=user.id, action="user.role_change", target_type="user", target_id=admin_id,
                          meta={"from": "admin", "to": "student", "reason": "admin_removed",
                                "self": admin_id == user.id})
        await write_audit(con, actor_id=user.id, action="admin.remove", target_type="user", target_id=admin_id)
        await revoke_user_sessions(request.app, con, admin_id, "role_change", now=utcnow())
    return Response(status_code=status.HTTP_204_NO_CONTENT)
