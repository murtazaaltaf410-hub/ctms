"""Shared API types: every response datetime is UTC ISO-8601 with a 'Z' suffix."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, PlainSerializer


def iso_utc(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


UtcDateTime = Annotated[datetime, PlainSerializer(iso_utc, return_type=str, when_used="json")]


class ApiModel(BaseModel):
    """Base for request/response bodies (snake_case fields, as in the spec)."""

    model_config = ConfigDict(str_strip_whitespace=True)


def utcnow() -> datetime:
    return datetime.now(UTC)
