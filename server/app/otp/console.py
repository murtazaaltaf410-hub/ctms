"""ConsoleOtpProvider: server-generated 6-digit code, logged to the console (dev only).

A code (and its HMAC) is stored for EVERY request, registered or not, so wrong
codes, expiry and the attempt limit behave identically for unknown numbers (no
enumeration, TC2). The code is only written to the log when the phone belongs
to an active driver, and it is never returned in a response.
"""

from __future__ import annotations

import hmac
import logging
from collections.abc import Callable
from datetime import datetime, timedelta

import asyncpg

from app.errors import OtpExpired, OtpInvalid
from app.otp.base import insert_request
from app.security import hash_otp, new_otp_code

log = logging.getLogger("ctms.otp")

CodeSink = Callable[[str, str], None]


def log_code(phone: str, code: str) -> None:
    log.warning("DEV OTP for %s: %s (console provider; never use in production)", phone, code)


class ConsoleOtpProvider:
    name = "console"

    def __init__(self, secret: str, sink: CodeSink = log_code) -> None:
        self._secret = secret
        self._sink = sink

    async def issue(self, con: asyncpg.Connection, *, phone: str, ip: str | None, is_driver: bool,
                    now: datetime, ttl_s: int) -> None:
        code = new_otp_code()
        await insert_request(con, provider=self.name, phone=phone, ip=ip, now=now,
                             code_hash=hash_otp(phone, code, self._secret),
                             expires_at=now + timedelta(seconds=ttl_s))
        if is_driver:
            self._sink(phone, code)

    async def verify(self, con: asyncpg.Connection, *, phone: str, otp: str, now: datetime, ttl_s: int,
                     max_attempts: int) -> None:
        row = await con.fetchrow(
            """select id, code_hash, expires_at, attempts, consumed_at
               from public.phone_otp_requests
               where phone = $1 and code_hash is not null
               order by requested_at desc, id desc limit 1""",
            phone,
        )
        if row is None:
            raise OtpInvalid()
        if row["consumed_at"] is not None or row["expires_at"] <= now:
            raise OtpExpired()
        if row["attempts"] >= max_attempts:
            raise OtpExpired("Too many wrong codes; request a new one")
        if not otp.isdigit() or not hmac.compare_digest(hash_otp(phone, otp, self._secret), row["code_hash"]):
            # Outside any transaction on purpose: the attempt must stick even though we raise.
            await con.execute("update public.phone_otp_requests set attempts = attempts + 1 where id = $1",
                              row["id"])
            raise OtpInvalid()
        await con.execute("update public.phone_otp_requests set consumed_at = $2 where id = $1",
                          row["id"], now)
