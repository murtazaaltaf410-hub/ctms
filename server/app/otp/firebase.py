"""FirebaseOtpProvider (ADR-1 behind ADR-7): the device runs Firebase Phone Auth and
sends the resulting Firebase ID token as `otp`.

The token verifier is injected so tests never call Firebase. The default one
uses `firebase_admin.auth.verify_id_token` in a worker thread.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from datetime import datetime, timedelta

import asyncpg
import firebase_admin
from fastapi import Request
from firebase_admin import auth, credentials

from app.config import Settings
from app.errors import OtpExpired, OtpInvalid
from app.otp.base import insert_request

log = logging.getLogger("ctms.otp")


class TokenExpiredError(Exception):
    """Raised by a verifier when the Firebase ID token is expired."""


TokenVerifier = Callable[[str], Awaitable[dict]]


def ensure_firebase_app(config: Settings) -> firebase_admin.App:
    """Initialise the default firebase_admin app once (shared with FCM push, P4)."""
    try:
        return firebase_admin.get_app()
    except ValueError:
        info = config.fcm_credentials_info()
        cred = credentials.Certificate(info) if info is not None else None
        return firebase_admin.initialize_app(cred)


def firebase_token_verifier(config: Settings) -> TokenVerifier:
    async def verify(token: str) -> dict:
        ensure_firebase_app(config)
        try:
            return await asyncio.to_thread(auth.verify_id_token, token, None, False, 0)
        except auth.ExpiredIdTokenError as exc:
            raise TokenExpiredError() from exc

    return verify


def get_firebase_token_verifier(request: Request) -> TokenVerifier:
    """Return the app override in tests, otherwise verify Firebase Admin tokens."""
    override = getattr(request.app.state, "firebase_token_verifier", None)
    return override or firebase_token_verifier(request.app.state.config)


class FirebaseOtpProvider:
    name = "firebase"

    def __init__(self, verifier: TokenVerifier) -> None:
        self._verifier = verifier

    async def issue(
        self, con: asyncpg.Connection, *, phone: str, ip: str | None, is_driver: bool, now: datetime, ttl_s: int
    ) -> None:
        # Firebase sends the SMS from the device; the row proves a recent request.
        await insert_request(con, provider=self.name, phone=phone, ip=ip, now=now)

    async def verify(
        self, con: asyncpg.Connection, *, phone: str, otp: str, now: datetime, ttl_s: int, max_attempts: int
    ) -> None:
        try:
            claims = await self._verifier(otp)
        except TokenExpiredError as exc:
            raise OtpExpired() from exc
        except Exception as exc:  # any verification failure is a failed sign-in
            log.info("firebase token rejected: %s", type(exc).__name__)
            raise OtpInvalid() from exc
        auth_time = claims.get("auth_time")
        if not isinstance(auth_time, int | float) or now.timestamp() - auth_time > ttl_s:
            raise OtpExpired()
        recent = await con.fetchval(
            "select exists(select 1 from public.phone_otp_requests where phone = $1 and requested_at > $2)",
            phone,
            now - timedelta(seconds=ttl_s),
        )
        if not recent:
            raise OtpExpired()
        if claims.get("phone_number") != phone:
            raise OtpInvalid()
