from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import Field

from app.schemas import ApiModel, UtcDateTime

TripStatus = Literal["on_time", "delayed", "breakdown"]


class StartTripIn(ApiModel):
    route_id: UUID | None = Field(default=None, description="Omit to use the bus's default route")


class StatusIn(ApiModel):
    status: TripStatus
    note: str | None = Field(default=None, max_length=140)


class TripOut(ApiModel):
    id: UUID
    bus_id: UUID
    bus_label: str
    route_id: UUID
    route_name: str
    driver_id: UUID
    schedule_id: UUID | None
    type: Literal["scheduled", "ad_hoc"]
    scheduled_departure: UtcDateTime | None = Field(description="Planned slot time for scheduled trips")
    status: TripStatus
    note: str | None
    started_at: UtcDateTime
    ended_at: UtcDateTime | None
    closed_by: Literal["driver", "auto"] | None
    distance_m: float
    last_fix_at: UtcDateTime | None


class TripSummary(TripOut):
    duration_s: float
    avg_speed_mps: float
