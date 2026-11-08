"""Helpers shared by the P5 admin routers: admin dependency, keyset cursors, in-use checks."""

from __future__ import annotations

import base64
import json
from datetime import datetime
from typing import Annotated, Any
from uuid import UUID

import asyncpg
from fastapi import Depends, Query, Request

from app.deps import CurrentUser, require_role
from app.errors import ValidationFailed

AdminUser = Annotated[CurrentUser, Depends(require_role("admin"))]
Cursor = Annotated[str | None, Query(max_length=200, description="next_cursor from the previous page")]
Limit = Annotated[int | None, Query(ge=1, description="Page size (default 50, max 200)")]


def page_limit(request: Request, limit: int | None) -> int:
    config = request.app.state.config
    return min(limit or config.admin_list_limit_default, config.admin_list_limit_max)


def encode_cursor(at: datetime, row_id: UUID) -> str:
    raw = json.dumps([at.isoformat(), str(row_id)]).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(cursor: str | None) -> tuple[datetime, UUID] | None:
    if not cursor:
        return None
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4))
        at, row_id = json.loads(raw)
        return datetime.fromisoformat(at), UUID(row_id)
    except (ValueError, TypeError) as exc:
        raise ValidationFailed("cursor: invalid value") from exc


def paginate(rows: list[Any], limit: int, at_key: str, id_key: str = "id") -> tuple[list[Any], str | None]:
    """`rows` were fetched with `limit + 1`; returns (page, next_cursor)."""
    if len(rows) <= limit:
        return rows, None
    page = rows[:limit]
    last = page[-1]
    return page, encode_cursor(last[at_key], last[id_key])


async def route_has_active_trip(con: asyncpg.Connection, route_id: UUID) -> bool:
    return bool(await con.fetchval(
        "select exists(select 1 from public.trips where route_id = $1 and ended_at is null)", route_id))


async def bus_has_active_trip(con: asyncpg.Connection, bus_id: UUID) -> bool:
    return bool(await con.fetchval(
        "select exists(select 1 from public.trips where bus_id = $1 and ended_at is null)", bus_id))


ROUTE_IN_USE_WARNING = "A trip is running on this route; changes apply from the next trip."
