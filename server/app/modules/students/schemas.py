"""Request and response bodies for student registration and the admin student screens."""

from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import Field, field_validator

from app.modules.auth.schemas import normalise_phone
from app.schemas import ApiModel, UtcDateTime

Status = Literal["pending", "approved", "rejected"]


class RegistrationIn(ApiModel):
    full_name: str = Field(min_length=1, max_length=120)
    phone: str = Field(min_length=1, max_length=32, description="E.164, e.g. +919876543210")
    department: str = Field(min_length=1, max_length=120)
    route_id: UUID
    requested_bus_label: str | None = Field(default=None, min_length=1, max_length=60)
    claims_registered: bool = Field(default=False, description="The student says they are registered with the facility")

    @field_validator("phone")
    @classmethod
    def _phone(cls, value: str) -> str:
        return normalise_phone(value)


class RegistrationOut(ApiModel):
    status: Status
    full_name: str
    phone: str | None
    department: str | None
    route_id: UUID | None
    route_name: str | None
    requested_bus_label: str | None
    claims_registered: bool
    bus_id: UUID | None
    bus_label: str | None
    admin_note: str | None
    reviewed_at: UtcDateTime | None
    created_at: UtcDateTime
    updated_at: UtcDateTime


class NearestRouteOut(ApiModel):
    route_id: UUID
    route_name: str
    offset_m: float = Field(description="Distance from the point to the route line, metres")


class RosterStudent(ApiModel):
    name: str
    department: str | None


class RosterOut(ApiModel):
    items: list[RosterStudent]


# --- admin ---------------------------------------------------------------------------------------
class AdminStudent(ApiModel):
    id: UUID = Field(description="The student's user id")
    full_name: str
    email: str | None
    phone: str | None
    department: str | None
    route_id: UUID | None
    route_name: str | None
    requested_bus_label: str | None
    claims_registered: bool
    status: Status
    bus_id: UUID | None
    bus_label: str | None
    admin_note: str | None
    reviewed_at: UtcDateTime | None
    created_at: UtcDateTime


class AdminStudentPage(ApiModel):
    items: list[AdminStudent]
    next_cursor: str | None


class ApproveIn(ApiModel):
    bus_id: UUID


class RejectIn(ApiModel):
    note: str = Field(min_length=1, max_length=500)


class StatusCounts(ApiModel):
    pending: int = 0
    approved: int = 0
    rejected: int = 0
    total: int = 0


class BusSeats(ApiModel):
    bus_id: UUID
    label: str
    route_id: UUID | None
    capacity: int | None
    assigned: int
    seats_left: int | None = Field(description="null when capacity is not set")


class RouteTotals(ApiModel):
    route_id: UUID
    route_name: str
    pending: int
    approved: int
    rejected: int


class StudentSummary(ApiModel):
    totals: StatusCounts
    buses: list[BusSeats]
    routes: list[RouteTotals]
