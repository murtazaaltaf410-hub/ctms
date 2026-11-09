"""Location upload and live buses (API spec p.3–4); also mounts the trips and ETA routers.

`POST /trips/{id}/locations` keeps working while the DB is down (N5): the bearer
JWT is verified offline, ownership comes from the in-memory trip, sessions
revoked since startup are refused, and writes queue in the batched writer.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import Field

import app.jobs.retention
import app.jobs.trips
import app.live.writer
import app.live.ws  # noqa: F401  (registers jobs, shutdown flush and WS revocation handlers)
from app import clock
from app.deps import AuthUser, bearer, get_current_user
from app.errors import (
    DB_CONNECTION_ERRORS,
    DbUnavailable,
    ForbiddenRole,
    NotYourTrip,
    TokenInvalid,
    ValidationFailed,
)
from app.live.conn import live_conn
from app.live.state import BusLive, LiveState, classify, get_live
from app.modules.eta.router import router as eta_router
from app.modules.tracking.service import Fix, ingest
from app.modules.trips import service as trips
from app.modules.trips.router import router as trips_router
from app.ratelimit import check_rate
from app.schemas import ApiModel, UtcDateTime
from app.security import decode_access_token

router = APIRouter()
router.include_router(trips_router)
router.include_router(eta_router)

tracking = APIRouter(tags=["tracking"])


class FixIn(ApiModel):
    fix_id: UUID = Field(description="Client-generated; repeats are ignored (DUPLICATE)")
    lat: float = Field(ge=-90, le=90, allow_inf_nan=False)
    lng: float = Field(ge=-180, le=180, allow_inf_nan=False)
    accuracy: float = Field(ge=0, allow_inf_nan=False, description="Metres")
    speed: float | None = Field(default=None, ge=0, allow_inf_nan=False, description="m/s")
    heading: float | None = Field(default=None, ge=0, le=360, allow_inf_nan=False)
    recorded_at: datetime


class LocationBatch(ApiModel):
    fixes: list[FixIn] = Field(min_length=1)


class RejectedFix(ApiModel):
    fix_id: UUID
    reason: str


class LocationsOut(ApiModel):
    accepted: list[UUID]
    rejected: list[RejectedFix]


class LiveBus(ApiModel):
    bus_id: UUID
    label: str
    trip_id: UUID
    route_id: UUID
    route_name: str
    direction: Literal["to_campus", "from_campus"]
    lat: float
    lng: float
    heading: float | None
    speed: float | None = Field(description="Smoothed speed, m/s")
    status: str
    note: str | None
    last_fix_at: UtcDateTime = Field(description="Server receive time of the live fix")
    recorded_at: UtcDateTime = Field(description="Phone time of the live fix")
    state: str = Field(description="live | stopped | stale | offline")
    clock_skew_s: float | None = Field(description="Set when the phone clock differs from the server (T13)")


async def _bus_for_trip(app, con, driver_id: UUID, trip_id: UUID) -> BusLive:
    live = get_live(app)
    bus = live.by_trip(trip_id)
    if bus is not None:
        if bus.driver_id != driver_id:
            raise NotYourTrip()
        return bus
    row = await trips.owned_active_trip(con, driver_id, trip_id)
    bus = await trips.load_bus(app, con, row)   # N4: an active trip missing from memory resumes from this fix
    live.add(bus)
    return bus


def _fixes(app, body: LocationBatch) -> list[Fix]:
    limit = int(app.state.settings_store.get_cached("location_batch_max"))
    if len(body.fixes) > limit:
        raise ValidationFailed(f"fixes: at most {limit} per batch")
    return [Fix(f.fix_id, f.lat, f.lng, f.accuracy, f.speed, f.heading, f.recorded_at) for f in body.fixes]


def _out(result) -> LocationsOut:
    return LocationsOut(accepted=result.accepted,
                        rejected=[RejectedFix(fix_id=fid, reason=reason) for fid, reason in result.rejected])


@tracking.post("/trips/{trip_id}/locations", response_model=LocationsOut, tags=["trips"])
async def post_locations(
    trip_id: UUID, body: LocationBatch, request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> LocationsOut:
    """Upload up to `location_batch_max` (20) fixes for the driver's own active trip.

    Each fix is accepted or rejected (ACCURACY_TOO_LOW, SPEED_IMPLAUSIBLE, DUPLICATE,
    OUT_OF_ORDER); rejections never fail the request, so the app clears its buffer
    after any 200. 403 NOT_YOUR_TRIP for another driver's trip, 404 for an unknown
    or ended trip."""
    app = request.app
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise TokenInvalid("Missing bearer token")
    claims = decode_access_token(credentials.credentials, app.state.config.jwt_secret)
    fixes = _fixes(app, body)
    try:
        async with live_conn(app) as con:
            user = await get_current_user(request, con, credentials)
            if user.role != "driver":
                raise ForbiddenRole()
            await check_rate(request, "locations", str(user.id), "rate_locations_per_user")
            bus = await _bus_for_trip(app, con, user.id, trip_id)
            return _out(await ingest(app, bus, fixes, con))
    except (DbUnavailable, *DB_CONNECTION_ERRORS):
        live: LiveState = get_live(app)
        if claims.session_id in live.revoked_sessions or claims.role != "driver":
            raise TokenInvalid() from None
        bus = live.by_trip(trip_id)
        if bus is None:
            raise DbUnavailable() from None
        if bus.driver_id != claims.user_id:
            raise NotYourTrip() from None
        await check_rate(request, "locations", str(claims.user_id), "rate_locations_per_user")
        return _out(await ingest(app, bus, fixes, None))


@tracking.get("/buses/live", response_model=list[LiveBus], tags=["buses"])
async def live_buses(request: Request, user: AuthUser) -> list[LiveBus]:
    """Buses on an active trip that have reported a position (T1: no trip, not listed)."""
    store = request.app.state.settings_store
    now = clock.now()
    thresholds = {k: float(store.get_cached(k)) for k in ("stale_after_s", "offline_after_s", "stopped_speed_mps")}
    out = []
    for bus in get_live(request.app).buses.values():
        if not bus.has_position:
            continue
        out.append(LiveBus(
            bus_id=bus.bus_id, label=bus.bus_label, trip_id=bus.trip_id, route_id=bus.route_id,
            route_name=bus.route.name, direction=bus.direction, lat=bus.lat, lng=bus.lng, heading=bus.heading,
            speed=None if bus.ema_speed_mps is None else round(bus.ema_speed_mps, 2), status=bus.status,
            note=bus.note, last_fix_at=bus.received_at, recorded_at=bus.recorded_at,
            state=classify(bus, now, **thresholds), clock_skew_s=bus.clock_skew_s,
        ))
    return sorted(out, key=lambda b: b.label)


router.include_router(tracking)
