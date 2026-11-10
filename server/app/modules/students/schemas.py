"""Request and response bodies for student registration and the admin student screens."""

from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import Field, field_validator

from app.modules.auth.schemas import normalise_phone
from app.schemas import ApiModel, UtcDateTime

Status = Literal["pending", "approved", "rejected"]
RegistrationState = Literal["unregistered", "incomplete", "registered"]


class RegistrationIn(ApiModel):
    full_name: str = Field(min_length=1, max_length=120)
    phone: str = Field(min_length=1, max_length=32, description="E.164, e.g. +919876543210")
    department: str = Field(min_length=1, max_length=120)
    enrollment_no: str = Field(min_length=1, max_length=40)
    home_address: str = Field(min_length=1, max_length=500)
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
    enrollment_no: str | None
    home_address: str | None
    has_photo: bool = Field(description="PUT /me/registration/photo uploads it; GET /students/{id}/photo serves it")
    complete: bool = Field(description="Name, phone, department, enrollment, address, route and photo are all set")
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
    student_id: UUID
    name: str
    department: str | None
    enrollment_no: str | None
    has_photo: bool


class RosterOut(ApiModel):
    items: list[RosterStudent]


# --- admin ---------------------------------------------------------------------------------------
class AdminStudent(ApiModel):
    id: UUID = Field(description="The student's user id")
    full_name: str
    email: str | None
    phone: str | None
    department: str | None
    enrollment_no: str | None
    has_photo: bool
    route_id: UUID | None
    route_name: str | None
    requested_bus_label: str | None
    claims_registered: bool
    # `None` is reserved for an account that has not submitted a registration.
    # Keep the review status distinct from the registration's completeness.
    status: Status | None
    registration_state: RegistrationState
    approval_diagnostic: str | None
    bus_id: UUID | None
    bus_label: str | None
    admin_note: str | None
    reviewed_at: UtcDateTime | None
    created_at: UtcDateTime


class DeregistrationOut(ApiModel):
    id: UUID
    status: Literal["pending", "approved", "rejected"]
    reason: str | None
    admin_note: str | None
    created_at: UtcDateTime
    reviewed_at: UtcDateTime | None


class AdminStudentDetail(AdminStudent):
    """Everything an admin sees on the student's page (the list rows leave address and phone out)."""

    home_address: str | None
    deregistration: DeregistrationOut | None = Field(description="The student's latest deregistration request")


class AdminStudentPage(ApiModel):
    items: list[AdminStudent]
    next_cursor: str | None


class ApproveIn(ApiModel):
    bus_id: UUID


class ApproveOptIn(ApiModel):
    bus_id: UUID | None = Field(default=None, description="Omit to auto-assign (requested bus, else most free seats)")


class RejectIn(ApiModel):
    note: str = Field(min_length=1, max_length=500)


class StatusCounts(ApiModel):
    unregistered: int = 0
    pending: int = 0
    approved: int = 0
    rejected: int = 0
    total: int = 0


class BusSeats(ApiModel):
    bus_id: UUID
    label: str
    route_id: UUID | None = Field(description="The bus's own student route (default_route_id)")
    route_ids: list[UUID] = Field(
        default_factory=list,
        description="Every route this bus serves: its own route plus the routes its driver is assigned to")
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
