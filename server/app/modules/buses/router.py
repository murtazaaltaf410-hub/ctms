"""GET/POST /admin/buses, PATCH /admin/buses/{id} (PRD A1).

Deactivating (the soft delete) is blocked while the bus has an active trip -> 409 IN_USE.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Request, status
from pydantic import Field

from app.audit import write_audit
from app.db import Conn
from app.errors import InUse, NotFound, ValidationFailed
from app.modules.admin.common import (
    AdminUser,
    Cursor,
    Limit,
    bus_has_active_trip,
    decode_cursor,
    page_limit,
    paginate,
)
from app.schemas import ApiModel, UtcDateTime

router = APIRouter(prefix="/admin/buses", tags=["admin: buses"])


class BusIn(ApiModel):
    label: str = Field(min_length=1, max_length=60)
    plate: str = Field(min_length=1, max_length=20)
    active: bool = True
    default_route_id: UUID | None = None
    capacity: int | None = Field(default=None, ge=0, le=500, description="Seats for students; null = not set")


class BusPatch(ApiModel):
    label: str | None = Field(default=None, min_length=1, max_length=60)
    plate: str | None = Field(default=None, min_length=1, max_length=20)
    active: bool | None = None
    default_route_id: UUID | None = Field(default=None, description="null clears the default route")
    capacity: int | None = Field(default=None, ge=0, le=500, description="null = not set")


class BusAdminOut(ApiModel):
    id: UUID
    label: str
    plate: str
    active: bool
    driver_id: UUID | None
    driver_name: str | None
    default_route_id: UUID | None
    capacity: int | None
    has_active_trip: bool
    created_at: UtcDateTime


class BusPage(ApiModel):
    items: list[BusAdminOut]
    next_cursor: str | None


_SELECT = """select b.id, b.label, b.plate, b.active, b.driver_id, u.name as driver_name, b.default_route_id,
                    b.capacity, b.created_at,
                    exists(select 1 from public.trips t where t.bus_id = b.id and t.ended_at is null)
                      as has_active_trip
             from public.buses b left join public.users u on u.id = b.driver_id"""


async def load_bus(con: asyncpg.Connection, bus_id: UUID) -> BusAdminOut:
    row = await con.fetchrow(f"{_SELECT} where b.id = $1", bus_id)
    if row is None:
        raise NotFound("Bus not found")
    return BusAdminOut(**dict(row))


async def _check_route(con: asyncpg.Connection, route_id: UUID | None) -> None:
    if route_id is not None and not await con.fetchval(
            "select exists(select 1 from public.routes where id = $1 and active)", route_id):
        raise ValidationFailed("default_route_id: unknown or inactive route")


def _plate_taken() -> ValidationFailed:
    return ValidationFailed("plate: already registered to another bus")


@router.get("", response_model=BusPage)
async def list_buses(request: Request, user: AdminUser, con: Conn, cursor: Cursor = None,
                     limit: Limit = None) -> BusPage:
    n = page_limit(request, limit)
    after: tuple[datetime, UUID] | None = decode_cursor(cursor)
    rows = await con.fetch(
        f"""{_SELECT} where ($1::timestamptz is null or (b.created_at, b.id) > ($1, $2))
            order by b.created_at, b.id limit $3""",
        after[0] if after else None, after[1] if after else None, n + 1,
    )
    page, next_cursor = paginate(rows, n, "created_at")
    return BusPage(items=[BusAdminOut(**dict(r)) for r in page], next_cursor=next_cursor)


@router.post("", response_model=BusAdminOut, status_code=status.HTTP_201_CREATED)
async def create_bus(body: BusIn, user: AdminUser, con: Conn) -> BusAdminOut:
    async with con.transaction():
        await _check_route(con, body.default_route_id)
        try:
            bus_id = await con.fetchval(
                """insert into public.buses (label, plate, active, default_route_id, capacity)
                   values ($1, $2, $3, $4, $5) returning id""",
                body.label, body.plate, body.active, body.default_route_id, body.capacity,
            )
        except asyncpg.UniqueViolationError as exc:
            raise _plate_taken() from exc
        await write_audit(con, actor_id=user.id, action="bus.create", target_type="bus", target_id=bus_id,
                          meta={"active": body.active})
    return await load_bus(con, bus_id)


@router.patch("/{bus_id}", response_model=BusAdminOut)
async def update_bus(bus_id: UUID, body: BusPatch, user: AdminUser, con: Conn) -> BusAdminOut:
    changes = {k: getattr(body, k) for k in body.model_fields_set}
    for key in ("label", "plate", "active"):
        if key in changes and changes[key] is None:
            raise ValidationFailed(f"{key}: may not be null")
    async with con.transaction():
        current = await con.fetchrow("select id, active from public.buses where id = $1 for update", bus_id)
        if current is None:
            raise NotFound("Bus not found")
        if changes.get("active") is False and current["active"] and await bus_has_active_trip(con, bus_id):
            raise InUse("The bus has an active trip; end it before deactivating the bus")
        if "default_route_id" in changes:
            await _check_route(con, changes["default_route_id"])
        if changes:
            cols = list(changes)
            sets = ", ".join(f"{col} = ${i + 2}" for i, col in enumerate(cols))
            try:
                await con.execute(f"update public.buses set {sets} where id = $1",  # noqa: S608 (whitelisted)
                                  bus_id, *[changes[c] for c in cols])
            except asyncpg.UniqueViolationError as exc:
                raise _plate_taken() from exc
            meta: dict = {"fields": sorted(cols)}
            if "active" in changes:
                meta["active"] = changes["active"]
            await write_audit(con, actor_id=user.id, action="bus.update", target_type="bus", target_id=bus_id,
                              meta=meta)
    return await load_bus(con, bus_id)
