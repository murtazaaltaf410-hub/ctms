"""Driver trip endpoints (API spec p.2–3)."""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Request, Response

from app import clock
from app.db import Conn
from app.deps import CurrentUser, require_role
from app.errors import NotFound, NotYourTrip
from app.modules.trips import service
from app.modules.trips.schemas import StartTripIn, StatusIn, TripOut, TripSummary

router = APIRouter(prefix="/trips", tags=["trips"])

Driver = Annotated[CurrentUser, Depends(require_role("driver"))]


@router.get("/active", response_model=TripOut | None)
async def get_active_trip(request: Request, user: Driver, con: Conn) -> TripOut | None:
    """The driver's active trip, or null."""
    row = await service.active_trip_for_driver(con, user.id)
    return None if row is None else service.trip_out(request.app, row)


@router.post("/start", response_model=TripOut, status_code=201)
async def start_trip(request: Request, user: Driver, con: Conn, body: StartTripIn | None = None) -> TripOut:
    """Start a trip on the driver's linked bus (default route unless `route_id` is given).

    `type` is `scheduled` when the start is within `schedule_match_window_s` of a
    timetable slot (campus time zone), else `ad_hoc`. 409 TRIP_ALREADY_ACTIVE if the
    driver or the bus already has an active trip (T10)."""
    return await service.start_trip(request.app, con, user.id, body.route_id if body else None)


@router.post("/{trip_id}/status", status_code=204)
async def set_trip_status(trip_id: UUID, body: StatusIn, request: Request, user: Driver, con: Conn) -> Response:
    """Set on_time / delayed / breakdown and an optional note (≤140 chars); broadcast `bus_status`."""
    row = await service.owned_active_trip(con, user.id, trip_id)
    await service.set_status(request.app, con, row, body.status, body.note)
    return Response(status_code=204)


@router.post("/{trip_id}/end", response_model=TripSummary)
async def end_trip(trip_id: UUID, request: Request, user: Driver, con: Conn) -> TripSummary:
    """End the trip; returns the summary (distance_m, started_at, ended_at, ...).
    Ending an already-ended trip returns its summary again (safe retry)."""
    row = await service.load_trip(con, trip_id)
    if row is None:
        raise NotFound("Trip not found")
    if row["driver_id"] != user.id:
        raise NotYourTrip()
    if row["ended_at"] is not None:
        return service.summarize(request.app, row)
    return await service.end_trip(request.app, con, trip_id, closed_by="driver", ended_at=clock.now(),
                                  actor_id=user.id)
