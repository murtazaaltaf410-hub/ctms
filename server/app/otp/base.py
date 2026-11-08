"""OtpProvider interface (ADR-7) and the shared request-row helpers.

The auth router owns everything common to all providers: phone validation, the
per-phone/per-IP limits, the uniform 202, the "is this an active driver" check,
sessions and audit. A provider only issues a code for a request and checks the
`otp` value on verify, raising OtpInvalid / OtpExpired.
"""

from __future__ import annotations

from datetime import datetime
from typing import Protocol

import asyncpg


class OtpProvider(Protocol):
    name: str

    async def issue(self, con: asyncpg.Connection, *, phone: str, ip: str | None, is_driver: bool,
                    now: datetime, ttl_s: int) -> None:
        """Record the request (one phone_otp_requests row) and send/prepare the code."""

    async def verify(self, con: asyncpg.Connection, *, phone: str, otp: str, now: datetime, ttl_s: int,
                     max_attempts: int) -> None:
        """Return if `otp` proves control of `phone`; raise OtpInvalid or OtpExpired otherwise."""


async def insert_request(con: asyncpg.Connection, *, provider: str, phone: str, ip: str | None,
                         now: datetime, code_hash: str | None = None, expires_at: datetime | None = None) -> None:
    await con.execute(
        """insert into public.phone_otp_requests (phone, ip, requested_at, code_hash, expires_at, provider)
           values ($1, $2::inet, $3, $4, $5, $6)""",
        phone, ip, now, code_hash, expires_at, provider,
    )
