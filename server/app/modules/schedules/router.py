"""Timetables (PRD A3): GET /schedules?route_id= (any signed-in user);
GET/POST /admin/schedules, PATCH /admin/schedules/{id} (admin; `active: false` is the soft delete).

`departure_time` is local campus time (settings `timezone`); `days_of_week` uses ISO numbering,
1 = Monday ... 7 = Sunday. Schedules are optional: ad hoc trips are always allowed.
"""

from __future__ import annotations

from datetime import time
from typing import Annotated, Literal
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Query, Request, status
from pydantic import Field, field_serializer, field_validator

from app.audit import write_audit
from app.db import Conn
from app.deps import AuthUser
from app.errors import NotFound, ValidationFailed
from app.modules.admin.common import AdminUser, Cursor, Limit, decode_cursor, page_limit, paginate
from app.schemas import ApiModel, UtcDateTime

public_router = APIRouter(prefix="/schedules", tags=["schedules"])
admin_router = APIRouter(prefix="/admin/schedules", tags=["admin: schedules"])

Direction = Literal["to_campus", "from_campus"]
RouteFilter = Annotated[UUID | None, Query(description="Only this route's slots")]


class _ScheduleFields(ApiModel):
    @field_validator("days_of_week", check_fields=False)
    @classmethod
    def _days(cls, value: list[int] | None) -> list[int] | None:
        if value is None:
            return None
        if not value or any(d < 1 or d > 7 for d in value):
            raise ValueError("days_of_week must list ISO weekdays 1 (Mon) to 7 (Sun)")
        return sorted(set(value))

    @field_validator("departure_time", check_fields=False)
    @classmethod
    def _local_time(cls, value: time | None) -> time | None:
        if value is None:
            return None
        if value.tzinfo is not None:
            raise ValueError("departure_time is local campus time; omit the UTC offset")
        return value.replace(second=0, microsecond=0)


class ScheduleIn(_ScheduleFields):
    route_id: UUID
    departure_time: time = Field(description="Local time HH:MM", examples=["08:30"])
    days_of_week: list[int] = Field(min_length=1, max_length=7, examples=[[1, 2, 3, 4, 5, 6]])
    direction: Direction = "to_campus"
    active: bool = True


class SchedulePatch(_ScheduleFields):
    route_id: UUID | None = None
    departure_time: time | None = None
    days_of_week: list[int] | None = Field(default=None, min_length=1, max_length=7)
    direction: Direction | None = None
    active: bool | None = None


class ScheduleOut(ApiModel):
    id: UUID
    route_id: UUID
    departure_time: time
    days_of_week: list[int]
    direction: Direction

    @field_serializer("departure_time")
    def _hhmm(self, value: time) -> str:
        return value.strftime("%H:%M")


class ScheduleAdminOut(ScheduleOut):
    active: bool
    created_at: UtcDateTime


class SchedulePage(ApiModel):
    items: list[ScheduleOut]
    next_cursor: str | None


class ScheduleAdminPage(ApiModel):
    items: list[ScheduleAdminOut]
    next_cursor: str | None


_COLUMNS = "s.id, s.route_id, s.departure_time, s.days_of_week, s.direction, s.active, s.created_at"


async def _load(con: asyncpg.Connection, schedule_id: UUID) -> ScheduleAdminOut:
    row = await con.fetchrow(f"select {_COLUMNS} from public.schedules s where s.id = $1",  # noqa: S608
                             schedule_id)
    if row is None:
        raise NotFound("Schedule not found")
    return ScheduleAdminOut(**dict(row))


async def _check_route(con: asyncpg.Connection, route_id: UUID) -> None:
    if not await con.fetchval("select exists(select 1 from public.routes where id = $1 and active)", route_id):
        raise ValidationFailed("route_id: unknown or removed route")


@public_router.get("", response_model=SchedulePage)
async def list_schedules(request: Request, user: AuthUser, con: Conn, route_id: RouteFilter = None,
                         cursor: Cursor = None, limit: Limit = None) -> SchedulePage:
    """Timetable slots (active schedules of active routes), by departure time."""
    n = page_limit(request, limit)
    after = decode_cursor(cursor)
    rows = await con.fetch(
        f"""select {_COLUMNS} from public.schedules s join public.routes r on r.id = s.route_id
            where s.active and r.active and ($1::uuid is null or s.route_id = $1)
              and ($2::timestamptz is null or (s.created_at, s.id) > ($2, $3))
            order by s.created_at, s.id limit $4""",  # noqa: S608 (constant SQL)
        route_id, after[0] if after else None, after[1] if after else None, n + 1,
    )
    page, next_cursor = paginate(rows, n, "created_at")
    items = sorted((ScheduleOut(**dict(r)) for r in page), key=lambda s: (s.departure_time, str(s.id)))
    return SchedulePage(items=items, next_cursor=next_cursor)


@admin_router.get("", response_model=ScheduleAdminPage)
async def admin_list_schedules(request: Request, user: AdminUser, con: Conn, route_id: RouteFilter = None,
                               cursor: Cursor = None, limit: Limit = None) -> ScheduleAdminPage:
    n = page_limit(request, limit)
    after = decode_cursor(cursor)
    rows = await con.fetch(
        f"""select {_COLUMNS} from public.schedules s
            where ($1::uuid is null or s.route_id = $1)
              and ($2::timestamptz is null or (s.created_at, s.id) > ($2, $3))
            order by s.created_at, s.id limit $4""",  # noqa: S608 (constant SQL)
        route_id, after[0] if after else None, after[1] if after else None, n + 1,
    )
    page, next_cursor = paginate(rows, n, "created_at")
    return ScheduleAdminPage(items=[ScheduleAdminOut(**dict(r)) for r in page], next_cursor=next_cursor)


@admin_router.post("", response_model=ScheduleAdminOut, status_code=status.HTTP_201_CREATED)
async def create_schedule(body: ScheduleIn, user: AdminUser, con: Conn) -> ScheduleAdminOut:
    async with con.transaction():
        await _check_route(con, body.route_id)
        schedule_id = await con.fetchval(
            """insert into public.schedules (route_id, departure_time, days_of_week, direction, active)
               values ($1, $2, $3, $4, $5) returning id""",
            body.route_id, body.departure_time, body.days_of_week, body.direction, body.active,
        )
        await write_audit(con, actor_id=user.id, action="schedule.create", target_type="schedule",
                          target_id=schedule_id, meta={"route_id": str(body.route_id)})
    return await _load(con, schedule_id)


@admin_router.patch("/{schedule_id}", response_model=ScheduleAdminOut)
async def update_schedule(schedule_id: UUID, body: SchedulePatch, user: AdminUser, con: Conn) -> ScheduleAdminOut:
    changes = {k: getattr(body, k) for k in body.model_fields_set}
    for key, value in changes.items():
        if value is None:
            raise ValidationFailed(f"{key}: may not be null")
    async with con.transaction():
        if not await con.fetchval("select exists(select 1 from public.schedules where id = $1)", schedule_id):
            raise NotFound("Schedule not found")
        if "route_id" in changes:
            await _check_route(con, changes["route_id"])
        if changes:
            cols = list(changes)
            sets = ", ".join(f"{col} = ${i + 2}" for i, col in enumerate(cols))
            await con.execute(f"update public.schedules set {sets} where id = $1",  # noqa: S608 (whitelisted)
                              schedule_id, *[changes[c] for c in cols])
            meta: dict = {"fields": sorted(cols)}
            if "active" in changes:
                meta["active"] = changes["active"]
            await write_audit(con, actor_id=user.id, action="schedule.update", target_type="schedule",
                              target_id=schedule_id, meta=meta)
    return await _load(con, schedule_id)
