from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import Field

from app.schemas import ApiModel, UtcDateTime

TripStatus = Literal["on_time", "delayed", "breakdown"]
Direction = Literal["to_campus", "from_campus"]


class StartTripIn(ApiModel):
    route_id: UUID | None = Field(default=None, description="Omit to use the bus's default route")
    direction: Direction = Field(
        default="to_campus",
        description="to_campus = the route in stored stop order (home -> campus); from_campus = reversed",
    )


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
    direction: Direction
    scheduled_departure: UtcDateTime | None = Field(description="Planned slot time for scheduled trips")
    status: TripStatus
    note: str | None
    started_at: UtcDateTime
    ended_at: UtcDateTime | None
    closed_by: Literal["driver", "auto", "arrival"] | None
    moved_at: UtcDateTime | None = Field(default=None, description="First fix above the moved-speed threshold")
    arrived_at: UtcDateTime | None = Field(default=None, description="When the bus reached the geofence, if it did")
    distance_m: float
    last_fix_at: UtcDateTime | None


class TripSummary(TripOut):
    duration_s: float
    avg_speed_mps: float
