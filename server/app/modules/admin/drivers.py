"""GET/POST /admin/drivers, PATCH /admin/drivers/{id} (PRD A1, edge cases U3, U8).

* One driver per bus (`buses.driver_id` is unique). Linking a driver to a bus that already has
  one replaces that driver (substitute driver, U8); every relink is audited.
* Deactivating a driver (or changing their phone) revokes their sessions (U3) and unlinks the bus
  so a replacement can be linked. Trips keep the driver who actually drove (`trips.driver_id`).
"""

from __future__ import annotations

from uuid import UUID

import asyncpg
from fastapi import APIRouter, Request, status
from pydantic import Field, field_validator

from app.audit import write_audit
from app.db import Conn
from app.errors import NotFound, ValidationFailed
from app.modules.admin.common import AdminUser, Cursor, Limit, decode_cursor, page_limit, paginate
from app.modules.auth.schemas import normalise_phone
from app.modules.auth.service import revoke_user_sessions
from app.schemas import ApiModel, UtcDateTime, utcnow

router = APIRouter(prefix="/admin/drivers", tags=["admin: drivers"])


class DriverIn(ApiModel):
    name: str = Field(min_length=1, max_length=120)
    phone: str = Field(min_length=1, max_length=32, description="E.164, e.g. +919876543210")
    bus_id: UUID | None = None
    active: bool = True

    @field_validator("phone")
    @classmethod
    def _phone(cls, value: str) -> str:
        return normalise_phone(value)


class DriverPatch(ApiModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    phone: str | None = Field(default=None, min_length=1, max_length=32)
    bus_id: UUID | None = Field(default=None, description="null unlinks the driver from their bus")
    active: bool | None = None

    @field_validator("phone")
    @classmethod
    def _phone(cls, value: str | None) -> str | None:
        return None if value is None else normalise_phone(value)


class DriverOut(ApiModel):
    id: UUID
    name: str
    phone: str | None
    active: bool
    bus_id: UUID | None
    bus_label: str | None
    created_at: UtcDateTime


class DriverPage(ApiModel):
    items: list[DriverOut]
    next_cursor: str | None


_SELECT = """select u.id, u.name, u.phone, u.active, u.created_at, b.id as bus_id, b.label as bus_label
             from public.users u left join public.buses b on b.driver_id = u.id
             where u.role = 'driver'"""


async def load_driver(con: asyncpg.Connection, driver_id: UUID) -> DriverOut:
    row = await con.fetchrow(f"{_SELECT} and u.id = $1", driver_id)
    if row is None:
        raise NotFound("Driver not found")
    return DriverOut(**dict(row))


def _phone_taken() -> ValidationFailed:
    return ValidationFailed("phone: already registered to another active user")


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


@router.post("", response_model=DriverOut, status_code=status.HTTP_201_CREATED)
async def create_driver(body: DriverIn, user: AdminUser, con: Conn) -> DriverOut:
    if body.bus_id is not None and not body.active:
        raise ValidationFailed("bus_id: an inactive driver cannot be linked to a bus")
    async with con.transaction():
        try:
            driver_id = await con.fetchval(
                "insert into public.users (role, name, phone, active) values ('driver', $1, $2, $3) returning id",
                body.name, body.phone, body.active,
            )
        except asyncpg.UniqueViolationError as exc:
            raise _phone_taken() from exc
        await write_audit(con, actor_id=user.id, action="driver.create", target_type="user", target_id=driver_id,
                          meta={"role": "driver", "active": body.active})
        if body.bus_id is not None:
            await link_bus(con, actor_id=user.id, driver_id=driver_id, bus_id=body.bus_id)
    return await load_driver(con, driver_id)


@router.patch("/{driver_id}", response_model=DriverOut)
async def update_driver(driver_id: UUID, body: DriverPatch, request: Request, user: AdminUser,
                        con: Conn) -> DriverOut:
    changes = {k: getattr(body, k) for k in body.model_fields_set}
    for key in ("name", "phone", "active"):
        if key in changes and changes[key] is None:
            raise ValidationFailed(f"{key}: may not be null")
    async with con.transaction():
        current = await con.fetchrow(
            "select id, phone, active from public.users where id = $1 and role = 'driver' for update", driver_id)
        if current is None:
            raise NotFound("Driver not found")
        will_be_active = changes.get("active", current["active"])
        if changes.get("bus_id") is not None and not will_be_active:
            raise ValidationFailed("bus_id: an inactive driver cannot be linked to a bus")
        user_cols = [c for c in ("name", "phone", "active") if c in changes]
        if user_cols:
            sets = ", ".join(f"{col} = ${i + 2}" for i, col in enumerate(user_cols))
            try:
                await con.execute(f"update public.users set {sets} where id = $1",  # noqa: S608 (whitelisted)
                                  driver_id, *[changes[c] for c in user_cols])
            except asyncpg.UniqueViolationError as exc:
                raise _phone_taken() from exc
        deactivated = current["active"] and changes.get("active") is False
        phone_changed = "phone" in changes and changes["phone"] != current["phone"]
        if user_cols:
            meta: dict = {"fields": sorted(user_cols)}
            if "active" in changes:
                meta["active"] = changes["active"]
            await write_audit(con, actor_id=user.id, action="driver.update", target_type="user",
                              target_id=driver_id, meta=meta)
        if deactivated:
            await link_bus(con, actor_id=user.id, driver_id=driver_id, bus_id=None)
        elif "bus_id" in changes:
            await link_bus(con, actor_id=user.id, driver_id=driver_id, bus_id=changes["bus_id"])
        if deactivated or phone_changed:
            reason = "deactivated" if deactivated else "phone_changed"
            await revoke_user_sessions(request.app, con, driver_id, reason, now=utcnow())
    return await load_driver(con, driver_id)
