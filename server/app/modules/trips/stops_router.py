"""Stop alert endpoints (V1.3 decision 8), driver only.

GET  /trips/{id}/stop-event   the open stop episode of the driver's trip, or null (drives the in-app prompt)
POST /trips/{id}/stop-reason  say why the bus is stopped; students see it as the trip status/note
GET  /me/driver-prefs         stop-alert prompt preferences
PUT  /me/driver-prefs         opt out of / back into the prompts, snooze them (0, 15, 30, 60 minutes)
"""

from __future__ import annotations

from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from pydantic import Field, model_validator

from app import clock
from app.db import Conn
from app.deps import CurrentUser, require_role
from app.live.state import get_live
from app.modules.trips import service
from app.modules.trips import stops as stops_service
from app.schemas import ApiModel, UtcDateTime

router = APIRouter(tags=["stop alerts"])

Driver = Annotated[CurrentUser, Depends(require_role("driver"))]
Reason = Literal["waiting_for_student", "traffic", "breakdown", "fuel", "police_check", "other"]


class StopEventOut(ApiModel):
    id: UUID
    trip_id: UUID
    started_at: UtcDateTime
    ended_at: UtcDateTime | None
    reason: Reason | None
    note: str | None
    auto_marked: bool = Field(description="The server set the trip to delayed/'Stopped' itself")
    driver_notified_at: UtcDateTime | None


class StopReasonIn(ApiModel):
    reason: Reason
    note: str | None = Field(default=None, max_length=140)


class DriverPrefsOut(ApiModel):
    stop_alerts_enabled: bool
    snooze_until: UtcDateTime | None = Field(description="No prompts before this time; null = not snoozed")


class DriverPrefsIn(ApiModel):
    stop_alerts_enabled: bool | None = None
    snooze_minutes: int | None = Field(default=None, description="0 (clear), 15, 30 or 60")

    @model_validator(mode="after")
    def _check(self) -> DriverPrefsIn:
        if self.stop_alerts_enabled is None and self.snooze_minutes is None:
            raise ValueError("send stop_alerts_enabled and/or snooze_minutes")
        if self.snooze_minutes is not None and self.snooze_minutes not in stops_service.SNOOZE_MINUTES:
            raise ValueError(f"snooze_minutes must be one of {list(stops_service.SNOOZE_MINUTES)}")
        return self


def _out(row) -> StopEventOut:
    return StopEventOut(**dict(row))


@router.get("/trips/{trip_id}/stop-event", response_model=StopEventOut | None)
async def get_stop_event(trip_id: UUID, user: Driver, con: Conn) -> StopEventOut | None:
    """The open (not yet ended) stop episode of the driver's own trip, or null."""
    await service.owned_active_trip(con, user.id, trip_id)
    row = await stops_service.open_event(con, trip_id)
    return None if row is None else _out(row)


@router.post("/trips/{trip_id}/stop-reason", response_model=StopEventOut)
async def post_stop_reason(trip_id: UUID, body: StopReasonIn, request: Request, user: Driver,
                           con: Conn) -> StopEventOut:
    """Record why the bus is stopped. Sets the trip status (`breakdown` for the breakdown reason, else
    `delayed`) and its note (your note, else a standard text), which students receive live. A reason
    stays until the driver changes the status; it is not cleared when the bus moves."""
    trip = await service.owned_active_trip(con, user.id, trip_id)
    row = await stops_service.record_reason(request.app, con, trip, body.reason, body.note, clock.now())
    bus = get_live(request.app).by_trip(trip_id)
    if bus is not None:
        bus.stop_open = True
    return _out(row)


@router.get("/me/driver-prefs", response_model=DriverPrefsOut)
async def get_driver_prefs(user: Driver, con: Conn) -> DriverPrefsOut:
    enabled, snooze = await stops_service.driver_prefs(con, user.id)
    return DriverPrefsOut(stop_alerts_enabled=enabled, snooze_until=snooze)


@router.put("/me/driver-prefs", response_model=DriverPrefsOut)
async def put_driver_prefs(body: DriverPrefsIn, user: Driver, con: Conn) -> DriverPrefsOut:
    enabled, snooze = await stops_service.driver_prefs(con, user.id)
    if body.stop_alerts_enabled is not None:
        enabled = body.stop_alerts_enabled
    if body.snooze_minutes is not None:
        snooze = stops_service.snooze_until(body.snooze_minutes, clock.now())
    await con.execute(
        """insert into public.driver_prefs (user_id, stop_alerts_enabled, snooze_until) values ($1, $2, $3)
           on conflict (user_id) do update set stop_alerts_enabled = excluded.stop_alerts_enabled,
             snooze_until = excluded.snooze_until, updated_at = now()""",
        user.id, enabled, snooze,
    )
    return DriverPrefsOut(stop_alerts_enabled=enabled, snooze_until=snooze)
