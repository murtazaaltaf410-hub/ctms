"""GET/POST /admin/drivers, PATCH /admin/drivers/{id}, POST /admin/drivers/{id}/reset-password
(PRD A1, edge cases U3, U8, ADR-10).

* Accounts are admin-managed: a driver signs in with a userid, email or phone plus a password. The
  server generates a temporary password, returns it ONCE (create / reset-password) and stores only
  its scrypt hash; the driver must change it on first sign-in (`must_change_password`).
* One driver per bus (`buses.driver_id` is unique). Linking a driver to a bus that already has
  one replaces that driver (substitute driver, U8); every relink is audited.
* Deactivating a driver (or changing a sign-in identifier) revokes their sessions (U3) and, for a
  deactivation, unlinks the bus so a replacement can be linked. Trips keep the driver who actually
  drove (`trips.driver_id`).
"""

from __future__ import annotations

import asyncio
import re
from datetime import date
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Request, status
from pydantic import Field, field_validator, model_validator

from app.audit import write_audit
from app.db import Conn
from app.errors import NotFound, ValidationFailed
from app.modules.admin.common import AdminUser, Cursor, Limit, decode_cursor, page_limit, paginate
from app.modules.auth.schemas import normalise_phone
from app.modules.auth.service import revoke_user_sessions
from app.schemas import ApiModel, UtcDateTime, utcnow
from app.security import generate_temporary_password, hash_password

router = APIRouter(prefix="/admin/drivers", tags=["admin: drivers"])

_USERID = re.compile(r"^[a-z0-9][a-z0-9._-]{2,39}$")
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_PROFILE_FIELDS = ("employee_id", "licence_no", "licence_expiry", "address", "emergency_name",
                   "emergency_phone", "notes")
_IDENTIFIER_FIELDS = ("phone", "email", "userid")


def _clean_userid(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip().lower()
    if not _USERID.match(value):
        raise ValueError("userid must be 3-40 characters: letters, digits, '.', '_' or '-'")
    return value


def _clean_email(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip().lower()
    if len(value) > 254 or not _EMAIL.match(value):
        raise ValueError("email is not valid")
    return value


def _clean_phone(value: str | None) -> str | None:
    return None if value is None else normalise_phone(value)


class DriverProfileFields(ApiModel):
    employee_id: str | None = Field(default=None, max_length=60)
    licence_no: str | None = Field(default=None, max_length=60)
    licence_expiry: date | None = None
    address: str | None = Field(default=None, max_length=500)
    emergency_name: str | None = Field(default=None, max_length=120)
    emergency_phone: str | None = Field(default=None, max_length=32)
    notes: str | None = Field(default=None, max_length=1000)


class _IdentifierCleaning(DriverProfileFields):
    @field_validator("phone", check_fields=False)
    @classmethod
    def _phone(cls, value: str | None) -> str | None:
        return _clean_phone(value)

    @field_validator("email", check_fields=False)
    @classmethod
    def _email(cls, value: str | None) -> str | None:
        return _clean_email(value)

    @field_validator("userid", check_fields=False)
    @classmethod
    def _userid(cls, value: str | None) -> str | None:
        return _clean_userid(value)


class DriverIn(_IdentifierCleaning):
    name: str = Field(min_length=1, max_length=120)
    phone: str | None = Field(default=None, max_length=32, description="E.164, e.g. +919876543210")
    email: str | None = Field(default=None, max_length=254)
    userid: str | None = Field(default=None, max_length=40, description="3-40 chars, lower-case")
    bus_id: UUID | None = None
    active: bool = True

    @model_validator(mode="after")
    def _has_identifier(self) -> DriverIn:
        if not (self.phone or self.email or self.userid):
            raise ValueError("at least one of phone, email or userid is required")
        return self


class DriverPatch(_IdentifierCleaning):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    phone: str | None = Field(default=None, max_length=32)
    email: str | None = Field(default=None, max_length=254)
    userid: str | None = Field(default=None, max_length=40)
    bus_id: UUID | None = Field(default=None, description="null unlinks the driver from their bus")
    active: bool | None = None


class DriverOut(DriverProfileFields):
    id: UUID
    name: str
    phone: str | None
    userid: str | None
    email: str | None
    active: bool
    must_change_password: bool
    locked: bool = Field(description="True while the account is locked after too many wrong passwords")
    bus_id: UUID | None
    bus_label: str | None
    created_at: UtcDateTime


class DriverCreated(DriverOut):
    temporary_password: str = Field(description="Shown once; only its hash is stored")


class PasswordResetOut(ApiModel):
    temporary_password: str = Field(description="Shown once; only its hash is stored")


class DriverPage(ApiModel):
    items: list[DriverOut]
    next_cursor: str | None


_SELECT = """select u.id, u.name, u.phone, u.userid, u.email, u.active, u.must_change_password,
                    (u.locked_until is not null and u.locked_until > now()) as locked, u.created_at,
                    b.id as bus_id, b.label as bus_label,
                    p.employee_id, p.licence_no, p.licence_expiry, p.address, p.emergency_name,
                    p.emergency_phone, p.notes
             from public.users u
             left join public.buses b on b.driver_id = u.id
             left join public.driver_profiles p on p.user_id = u.id
             where u.role = 'driver'"""

_TAKEN = {
    "users_phone_active_uniq": "phone: already registered to another active user",
    "users_userid_uniq": "userid: already taken",
    "users_email_key": "email: already registered to another user",
}


async def load_driver(con: asyncpg.Connection, driver_id: UUID) -> DriverOut:
    row = await con.fetchrow(f"{_SELECT} and u.id = $1", driver_id)
    if row is None:
        raise NotFound("Driver not found")
    return DriverOut(**dict(row))


def _taken(exc: asyncpg.UniqueViolationError) -> ValidationFailed:
    return ValidationFailed(_TAKEN.get(exc.constraint_name or "", "phone, email or userid already in use"))


async def _upsert_profile(con: asyncpg.Connection, driver_id: UUID, values: dict) -> None:
    cols = [c for c in _PROFILE_FIELDS if c in values]
    if not cols:
        return
    names = ", ".join(cols)
    marks = ", ".join(f"${i + 2}" for i in range(len(cols)))
    updates = ", ".join(f"{c} = excluded.{c}" for c in cols)
    await con.execute(
        f"""insert into public.driver_profiles (user_id, {names}) values ($1, {marks})
            on conflict (user_id) do update set {updates}""",  # noqa: S608 (whitelisted columns)
        driver_id, *[values[c] for c in cols],
    )


async def _new_password() -> tuple[str, str]:
    """(plain temporary password, scrypt hash). The plain value is only ever returned once."""
    plain = generate_temporary_password()
    return plain, await asyncio.to_thread(hash_password, plain)


async def link_bus(con: asyncpg.Connection, *, actor_id: UUID, driver_id: UUID, bus_id: UUID | None) -> None:
    """Make `bus_id` (or no bus) the driver's only bus, replacing any driver the bus had (U8)."""
    old_bus = await con.fetchval("select id from public.buses where driver_id = $1", driver_id)
    if old_bus == bus_id:
        return
    previous_driver = None
    if bus_id is not None:
        bus = await con.fetchrow("select id, active, driver_id from public.buses where id = $1 for update", bus_id)
        if bus is None or not bus["active"]:
            raise ValidationFailed("bus_id: unknown or inactive bus")
        previous_driver = bus["driver_id"]
    if old_bus is not None:
        await con.execute("update public.buses set driver_id = null where id = $1", old_bus)
    if bus_id is not None:
        await con.execute("update public.buses set driver_id = $2 where id = $1", bus_id, driver_id)
    await write_audit(con, actor_id=actor_id, action="bus.driver_relink", target_type="bus",
                      target_id=bus_id or old_bus,
                      meta={"driver_id": str(driver_id),
                            "from_bus_id": str(old_bus) if old_bus else None,
                            "to_bus_id": str(bus_id) if bus_id else None,
                            "replaced_driver_id": str(previous_driver) if previous_driver else None})


@router.get("", response_model=DriverPage)
async def list_drivers(request: Request, user: AdminUser, con: Conn, cursor: Cursor = None,
                       limit: Limit = None) -> DriverPage:
    n = page_limit(request, limit)
    after = decode_cursor(cursor)
    rows = await con.fetch(
        f"""{_SELECT} and ($1::timestamptz is null or (u.created_at, u.id) > ($1, $2))
            order by u.created_at, u.id limit $3""",
        after[0] if after else None, after[1] if after else None, n + 1,
    )
    page, next_cursor = paginate(rows, n, "created_at")
    return DriverPage(items=[DriverOut(**dict(r)) for r in page], next_cursor=next_cursor)


@router.post("", response_model=DriverCreated, status_code=status.HTTP_201_CREATED)
async def create_driver(body: DriverIn, user: AdminUser, con: Conn) -> DriverCreated:
    if body.bus_id is not None and not body.active:
        raise ValidationFailed("bus_id: an inactive driver cannot be linked to a bus")
    temporary, password_hash = await _new_password()
    async with con.transaction():
        try:
            driver_id = await con.fetchval(
                """insert into public.users (role, name, phone, email, userid, active, password_hash,
                                             must_change_password)
                   values ('driver', $1, $2, $3, $4, $5, $6, true) returning id""",
                body.name, body.phone, body.email, body.userid, body.active, password_hash,
            )
        except asyncpg.UniqueViolationError as exc:
            raise _taken(exc) from exc
        await _upsert_profile(con, driver_id, {c: getattr(body, c) for c in _PROFILE_FIELDS
                                               if c in body.model_fields_set})
        await write_audit(con, actor_id=user.id, action="driver.create", target_type="user", target_id=driver_id,
                          meta={"role": "driver", "active": body.active})
        if body.bus_id is not None:
            await link_bus(con, actor_id=user.id, driver_id=driver_id, bus_id=body.bus_id)
    driver = await load_driver(con, driver_id)
    return DriverCreated(**driver.model_dump(), temporary_password=temporary)


@router.post("/{driver_id}/reset-password", response_model=PasswordResetOut)
async def reset_driver_password(driver_id: UUID, request: Request, user: AdminUser,
                                con: Conn) -> PasswordResetOut:
    """New temporary password (shown once). Unlocks the account, forces a change, signs the driver out."""
    temporary, password_hash = await _new_password()
    async with con.transaction():
        found = await con.fetchval(
            """update public.users set password_hash = $2, must_change_password = true, failed_logins = 0,
                      locked_until = null
               where id = $1 and role = 'driver' returning id""",
            driver_id, password_hash,
        )
        if found is None:
            raise NotFound("Driver not found")
        await revoke_user_sessions(request.app, con, driver_id, "password_reset", now=utcnow())
        await write_audit(con, actor_id=user.id, action="driver.reset_password", target_type="user",
                          target_id=driver_id)
    return PasswordResetOut(temporary_password=temporary)


@router.patch("/{driver_id}", response_model=DriverOut)
async def update_driver(driver_id: UUID, body: DriverPatch, request: Request, user: AdminUser,
                        con: Conn) -> DriverOut:
    changes = {k: getattr(body, k) for k in body.model_fields_set}
    for key in ("name", "active"):
        if key in changes and changes[key] is None:
            raise ValidationFailed(f"{key}: may not be null")
    async with con.transaction():
        current = await con.fetchrow(
            "select id, phone, email, userid, active from public.users where id = $1 and role = 'driver' for update",
            driver_id)
        if current is None:
            raise NotFound("Driver not found")
        will_be_active = changes.get("active", current["active"])
        if changes.get("bus_id") is not None and not will_be_active:
            raise ValidationFailed("bus_id: an inactive driver cannot be linked to a bus")
        final = {c: changes[c] if c in changes else current[c] for c in _IDENTIFIER_FIELDS}
        if not any(final.values()):
            raise ValidationFailed("phone: at least one of phone, email or userid must remain")
        user_cols = [c for c in ("name", "phone", "email", "userid", "active") if c in changes]
        if user_cols:
            sets = ", ".join(f"{col} = ${i + 2}" for i, col in enumerate(user_cols))
            try:
                await con.execute(f"update public.users set {sets} where id = $1",  # noqa: S608 (whitelisted)
                                  driver_id, *[changes[c] for c in user_cols])
            except asyncpg.UniqueViolationError as exc:
                raise _taken(exc) from exc
        profile = {c: changes[c] for c in _PROFILE_FIELDS if c in changes}
        await _upsert_profile(con, driver_id, profile)
        deactivated = current["active"] and changes.get("active") is False
        identifier_changed = any(c in changes and changes[c] != current[c] for c in _IDENTIFIER_FIELDS)
        if user_cols or profile:
            meta: dict = {"fields": sorted(user_cols + list(profile))}
            if "active" in changes:
                meta["active"] = changes["active"]
            await write_audit(con, actor_id=user.id, action="driver.update", target_type="user",
                              target_id=driver_id, meta=meta)
        if deactivated:
            await link_bus(con, actor_id=user.id, driver_id=driver_id, bus_id=None)
        elif "bus_id" in changes:
            await link_bus(con, actor_id=user.id, driver_id=driver_id, bus_id=changes["bus_id"])
        if deactivated or identifier_changed:
            reason = "deactivated" if deactivated else "identifier_changed"
            await revoke_user_sessions(request.app, con, driver_id, reason, now=utcnow())
    return await load_driver(con, driver_id)
