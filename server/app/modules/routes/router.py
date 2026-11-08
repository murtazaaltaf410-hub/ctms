"""Routes and stops.

Public (any signed-in user): GET /routes, GET /routes/{id}.
Admin: GET/POST /admin/routes, GET (extension)/PATCH /admin/routes/{id}, POST /admin/routes/{id}/stops,
PATCH /admin/stops/{id}.

* Changing a route's stops regenerates the polyline once (Routes API, ADR-8). If that fails the
  route is saved as a draft and the response is 422 POLYLINE_FAILED with the saved route in a
  `route` field next to `error` (U7, TC16). A route cannot be set active without a polyline.
* Deactivating a route or stop while an active trip uses the route -> 409 IN_USE (U6, TC17).
  Other edits apply from the next trip; responses carry `warning` while a trip is running.
"""

from __future__ import annotations

from typing import Annotated, Literal
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Depends, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from pydantic import Field

from app.audit import write_audit
from app.db import Conn
from app.deps import AuthUser
from app.errors import InUse, NotFound, PolylineFailed, ValidationFailed, error_body
from app.integrations.routes_api import RouteProvider, get_route_provider
from app.modules.admin.common import (
    ROUTE_IN_USE_WARNING,
    AdminUser,
    Cursor,
    Limit,
    decode_cursor,
    page_limit,
    paginate,
    route_has_active_trip,
)
from app.modules.routes.service import active_stops, place, regenerate_polyline, renumber_stops
from app.schemas import ApiModel, UtcDateTime

public_router = APIRouter(prefix="/routes", tags=["routes"])
admin_router = APIRouter(tags=["admin: routes"])

Provider = Annotated[RouteProvider, Depends(get_route_provider)]


# --- Schemas ---------------------------------------------------------------------------------------

class StopOut(ApiModel):
    id: UUID
    name: str
    lat: float
    lng: float
    sequence: int
    dist_along_m: float | None


class RouteSummaryOut(ApiModel):
    id: UUID
    name: str
    stop_count: int
    length_m: float | None


class RouteSummaryPage(ApiModel):
    items: list[RouteSummaryOut]
    next_cursor: str | None


class RouteDetailOut(ApiModel):
    id: UUID
    name: str
    status: Literal["draft", "active"]
    polyline: str | None = Field(description="Google encoded polyline (precision 1e5)")
    length_m: float | None
    stops: list[StopOut]


class RouteAdminSummaryOut(RouteSummaryOut):
    status: Literal["draft", "active"]
    active: bool
    polyline_error: str | None
    created_at: UtcDateTime
    updated_at: UtcDateTime


class RouteAdminSummaryPage(ApiModel):
    items: list[RouteAdminSummaryOut]
    next_cursor: str | None


class RouteAdminOut(RouteDetailOut):
    active: bool
    polyline_error: str | None
    created_at: UtcDateTime
    updated_at: UtcDateTime
    warning: str | None = Field(default=None, description="Set while a trip is running on this route (U6)")


class NewStopIn(ApiModel):
    name: str = Field(min_length=1, max_length=120)
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class StopIn(NewStopIn):
    sequence: int | None = Field(default=None, ge=1, description="1-based position; omitted = last")


class StopPatch(ApiModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)
    sequence: int | None = Field(default=None, ge=1)
    active: bool | None = Field(default=None, description="false removes the stop (soft delete)")


class RouteIn(ApiModel):
    name: str = Field(min_length=1, max_length=120)
    active: bool = True
    stops: list[NewStopIn] = Field(default_factory=list, description="Optional ordered stops (extension)")


class RoutePatch(ApiModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    active: bool | None = Field(default=None, description="false removes the route (soft delete)")
    status: Literal["draft", "active"] | None = Field(default=None, description="active requires a polyline")
    regenerate: bool = Field(default=False, description="Extension: retry the Routes API for the current stops")


# --- Loading ---------------------------------------------------------------------------------------

async def load_route_admin(con: asyncpg.Connection, route_id: UUID) -> RouteAdminOut:
    row = await con.fetchrow(
        """select id, name, status, polyline, length_m, active, polyline_error, created_at, updated_at
           from public.routes where id = $1""",
        route_id,
    )
    if row is None:
        raise NotFound("Route not found")
    stops = [StopOut(**dict(s)) for s in await active_stops(con, route_id)]
    warning = ROUTE_IN_USE_WARNING if await route_has_active_trip(con, route_id) else None
    return RouteAdminOut(**dict(row), stops=stops, warning=warning)


async def _result(con: asyncpg.Connection, route_id: UUID, error: str | None,
                  status_code: int = status.HTTP_200_OK) -> JSONResponse:
    route = await load_route_admin(con, route_id)
    if error is not None:
        body = error_body(PolylineFailed.code, error) | {"route": jsonable_encoder(route)}
        return JSONResponse(body, status_code=PolylineFailed.status_code)
    return JSONResponse(jsonable_encoder(route), status_code=status_code)


def _max_stops(request: Request) -> int:
    return request.app.state.config.routes_api_max_intermediates + 2


async def _lock_route(con: asyncpg.Connection, route_id: UUID) -> asyncpg.Record:
    row = await con.fetchrow("select id, active, status, polyline from public.routes where id = $1 for update",
                             route_id)
    if row is None:
        raise NotFound("Route not found")
    return row


_POLYLINE_FAILED_RESPONSE = {422: {"description": "POLYLINE_FAILED: `error` plus the saved draft in `route`"}}


# --- Public ----------------------------------------------------------------------------------------

@public_router.get("", response_model=RouteSummaryPage)
async def list_routes(request: Request, user: AuthUser, con: Conn, cursor: Cursor = None,
                      limit: Limit = None) -> RouteSummaryPage:
    """Active routes with name and stop count."""
    n = page_limit(request, limit)
    after = decode_cursor(cursor)
    rows = await con.fetch(
        """select r.id, r.name, r.length_m, r.created_at,
                  (select count(*) from public.stops s where s.route_id = r.id and s.active) as stop_count
           from public.routes r
           where r.active and r.status = 'active'
             and ($1::timestamptz is null or (r.created_at, r.id) > ($1, $2))
           order by r.created_at, r.id limit $3""",
        after[0] if after else None, after[1] if after else None, n + 1,
    )
    page, next_cursor = paginate(rows, n, "created_at")
    return RouteSummaryPage(items=[RouteSummaryOut(**dict(r)) for r in page], next_cursor=next_cursor)


@public_router.get("/{route_id}", response_model=RouteDetailOut)
async def get_route(route_id: UUID, user: AuthUser, con: Conn) -> RouteDetailOut:
    """Route with encoded polyline and ordered stops."""
    row = await con.fetchrow(
        "select id, name, status, polyline, length_m from public.routes where id = $1 and active", route_id)
    if row is None:
        raise NotFound("Route not found")
    stops = [StopOut(**dict(s)) for s in await active_stops(con, route_id)]
    return RouteDetailOut(**dict(row), stops=stops)


# --- Admin -----------------------------------------------------------------------------------------

@admin_router.get("/admin/routes", response_model=RouteAdminSummaryPage)
async def admin_list_routes(request: Request, user: AdminUser, con: Conn, cursor: Cursor = None,
                            limit: Limit = None) -> RouteAdminSummaryPage:
    """All routes, including drafts and removed (active=false) ones."""
    n = page_limit(request, limit)
    after = decode_cursor(cursor)
    rows = await con.fetch(
        """select r.id, r.name, r.length_m, r.status, r.active, r.polyline_error, r.created_at, r.updated_at,
                  (select count(*) from public.stops s where s.route_id = r.id and s.active) as stop_count
           from public.routes r
           where ($1::timestamptz is null or (r.created_at, r.id) > ($1, $2))
           order by r.created_at, r.id limit $3""",
        after[0] if after else None, after[1] if after else None, n + 1,
    )
    page, next_cursor = paginate(rows, n, "created_at")
    return RouteAdminSummaryPage(items=[RouteAdminSummaryOut(**dict(r)) for r in page], next_cursor=next_cursor)


@admin_router.get("/admin/routes/{route_id}", response_model=RouteAdminOut,
                  summary="Admin route detail (extension, not in the API spec)")
async def admin_get_route(route_id: UUID, user: AdminUser, con: Conn) -> RouteAdminOut:
    return await load_route_admin(con, route_id)


@admin_router.post("/admin/routes", response_model=RouteAdminOut, status_code=status.HTTP_201_CREATED,
                   responses=_POLYLINE_FAILED_RESPONSE)
async def create_route(body: RouteIn, request: Request, user: AdminUser, con: Conn,
                       provider: Provider) -> JSONResponse:
    if len(body.stops) > _max_stops(request):
        raise ValidationFailed(f"stops: at most {_max_stops(request)} stops per route")
    async with con.transaction():
        route_id = await con.fetchval("insert into public.routes (name, active) values ($1, $2) returning id",
                                      body.name, body.active)
        for seq, stop in enumerate(body.stops, start=1):
            await con.execute(
                "insert into public.stops (route_id, name, lat, lng, sequence) values ($1, $2, $3, $4, $5)",
                route_id, stop.name, stop.lat, stop.lng, seq,
            )
        await write_audit(con, actor_id=user.id, action="route.create", target_type="route", target_id=route_id,
                          meta={"stops": len(body.stops), "active": body.active})
    error = await regenerate_polyline(con, provider, route_id, actor_id=user.id) if body.stops else None
    return await _result(con, route_id, error, status.HTTP_201_CREATED)


@admin_router.patch("/admin/routes/{route_id}", response_model=RouteAdminOut, responses=_POLYLINE_FAILED_RESPONSE)
async def update_route(route_id: UUID, body: RoutePatch, user: AdminUser, con: Conn,
                       provider: Provider) -> JSONResponse:
    changes = {k: getattr(body, k) for k in body.model_fields_set if k != "regenerate"}
    for key in ("name", "active", "status"):
        if key in changes and changes[key] is None:
            raise ValidationFailed(f"{key}: may not be null")
    async with con.transaction():
        current = await _lock_route(con, route_id)
        if changes.get("active") is False and current["active"] and await route_has_active_trip(con, route_id):
            raise InUse("A trip is running on this route; end it before removing the route")
        if changes.get("status") == "active" and current["polyline"] is None:
            raise PolylineFailed("The route has no polyline yet; fix its stops before activating it")
        if changes:
            cols = list(changes)
            sets = ", ".join(f"{col} = ${i + 2}" for i, col in enumerate(cols))
            await con.execute(f"update public.routes set {sets} where id = $1",  # noqa: S608 (whitelisted)
                              route_id, *[changes[c] for c in cols])
            meta: dict = {"fields": sorted(cols)}
            for key in ("active", "status"):
                if key in changes:
                    meta[key] = changes[key]
            if changes.get("active") is False:
                cleared = await con.fetch(
                    "update public.buses set default_route_id = null where default_route_id = $1 returning id",
                    route_id)
                meta["cleared_default_on_buses"] = len(cleared)
            await write_audit(con, actor_id=user.id, action="route.update", target_type="route",
                              target_id=route_id, meta=meta)
    error = await regenerate_polyline(con, provider, route_id, actor_id=user.id) if body.regenerate else None
    return await _result(con, route_id, error)


@admin_router.post("/admin/routes/{route_id}/stops", response_model=RouteAdminOut,
                   status_code=status.HTTP_201_CREATED, responses=_POLYLINE_FAILED_RESPONSE)
async def add_stop(route_id: UUID, body: StopIn, request: Request, user: AdminUser, con: Conn,
                   provider: Provider) -> JSONResponse:
    """Add a stop (at `sequence`, default last); the polyline is regenerated once."""
    async with con.transaction():
        current = await _lock_route(con, route_id)
        if not current["active"]:
            raise ValidationFailed("route_id: the route has been removed")
        stops = await active_stops(con, route_id)
        if len(stops) + 1 > _max_stops(request):
            raise ValidationFailed(f"stops: at most {_max_stops(request)} stops per route")
        stop_id = await con.fetchval(
            "insert into public.stops (route_id, name, lat, lng, sequence) values ($1, $2, $3, $4, $5) returning id",
            route_id, body.name, body.lat, body.lng, len(stops) + 1,
        )
        if body.sequence is not None:
            await renumber_stops(con, route_id, place([s["id"] for s in stops], stop_id, body.sequence))
        await write_audit(con, actor_id=user.id, action="stop.create", target_type="stop", target_id=stop_id,
                          meta={"route_id": str(route_id)})
    error = await regenerate_polyline(con, provider, route_id, actor_id=user.id)
    return await _result(con, route_id, error, status.HTTP_201_CREATED)


@admin_router.patch("/admin/stops/{stop_id}", response_model=RouteAdminOut, responses=_POLYLINE_FAILED_RESPONSE)
async def update_stop(stop_id: UUID, body: StopPatch, user: AdminUser, con: Conn,
                      provider: Provider) -> JSONResponse:
    """Edit a stop; moving, reordering or removing it regenerates the polyline once. Returns the route."""
    changes = {k: getattr(body, k) for k in body.model_fields_set}
    for key in ("name", "lat", "lng", "sequence", "active"):
        if key in changes and changes[key] is None:
            raise ValidationFailed(f"{key}: may not be null")
    async with con.transaction():
        stop = await con.fetchrow("select id, route_id, active from public.stops where id = $1", stop_id)
        if stop is None:
            raise NotFound("Stop not found")
        route_id = stop["route_id"]
        await _lock_route(con, route_id)
        if not stop["active"] and changes.get("active") is not True:
            raise NotFound("Stop not found")
        if changes.get("active") is False and await route_has_active_trip(con, route_id):
            raise InUse("A trip is running on this route; end it before removing the stop")
        cols = [c for c in ("name", "lat", "lng", "active") if c in changes]
        if cols:
            sets = ", ".join(f"{col} = ${i + 2}" for i, col in enumerate(cols))
            await con.execute(f"update public.stops set {sets} where id = $1",  # noqa: S608 (whitelisted)
                              stop_id, *[changes[c] for c in cols])
        ordered = [s["id"] for s in await active_stops(con, route_id)]
        if not changes.get("active", stop["active"]):
            ordered = [i for i in ordered if i != stop_id]
        elif "sequence" in changes or not stop["active"]:
            ordered = place(ordered, stop_id, changes.get("sequence"))
        await renumber_stops(con, route_id, ordered)
        if changes:
            meta: dict = {"route_id": str(route_id), "fields": sorted(changes)}
            if "active" in changes:
                meta["active"] = changes["active"]
            await write_audit(con, actor_id=user.id, action="stop.update", target_type="stop", target_id=stop_id,
                              meta=meta)
    error = None
    if changes.keys() & {"lat", "lng", "sequence", "active"}:
        error = await regenerate_polyline(con, provider, route_id, actor_id=user.id)
    return await _result(con, route_id, error)
