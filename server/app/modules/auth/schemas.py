from __future__ import annotations

import re
from typing import Literal
from uuid import UUID

from pydantic import Field, field_validator

from app.schemas import ApiModel, UtcDateTime

E164 = re.compile(r"^\+[1-9][0-9]{6,14}$")
_PHONE_FILLER = re.compile(r"[\s\-().]")


def normalise_phone(value: str) -> str:
    phone = _PHONE_FILLER.sub("", value)
    if not E164.match(phone):
        raise ValueError("phone must be E.164, e.g. +919876543210")
    return phone


class GoogleSignInIn(ApiModel):
    id_token: str = Field(min_length=1, max_length=8192)


class FirebaseSignInIn(ApiModel):
    id_token: str = Field(min_length=1, max_length=8192)


class PhoneRequestIn(ApiModel):
    phone: str = Field(min_length=1, max_length=32)

    @field_validator("phone")
    @classmethod
    def _normalise(cls, value: str) -> str:
        return normalise_phone(value)


class PhoneVerifyIn(ApiModel):
    phone: str = Field(min_length=1, max_length=32)
    otp: str = Field(
        min_length=1,
        max_length=8192,
        description="The 6-digit code (console/SMS provider) or, with OTP_PROVIDER=firebase, the Firebase "
        "ID token from Firebase Phone Auth on the device (ADR-1/ADR-7).",
    )

    @field_validator("phone")
    @classmethod
    def _normalise(cls, value: str) -> str:
        return normalise_phone(value)


class RefreshIn(ApiModel):
    refresh_token: str = Field(min_length=1, max_length=512)


class LogoutIn(ApiModel):
    push_token: str | None = Field(
        default=None,
        max_length=4096,
        description="Extension: remove only this device's push token. Without a body all of the "
        "user's push tokens are removed.",
    )


class BusOut(ApiModel):
    id: UUID
    label: str
    plate: str
    default_route_id: UUID | None


class UserOut(ApiModel):
    id: UUID
    role: Literal["student", "driver", "admin"]
    name: str
    email: str | None
    phone: str | None
    created_at: UtcDateTime
    bus: BusOut | None = Field(default=None, description="The linked bus (drivers only)")


class TokensOut(ApiModel):
    access_token: str
    refresh_token: str
    user: UserOut


class RefreshOut(ApiModel):
    access_token: str
    refresh_token: str
