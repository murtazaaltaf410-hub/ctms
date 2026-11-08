"""POST /auth/google, /auth/phone/request, /auth/phone/verify, /auth/refresh, /auth/logout."""

from __future__ import annotations

import math
from datetime import timedelta
from typing import Annotated

from fastapi import APIRouter, Body, Depends, Request, Response, status

from app.audit import write_audit
from app.db import Conn
from app.deps import AuthUser
from app.errors import OtpInvalid, RateLimited, TokenExpired, TokenInvalid
from app.live import SESSIONS_REVOKED, publish
from app.modules.auth.google import GoogleTokenVerifier, get_google_verifier
from app.modules.auth.schemas import (
    FirebaseSignInIn,
    GoogleSignInIn,
    LogoutIn,
    PhoneRequestIn,
    PhoneVerifyIn,
    RefreshIn,
    RefreshOut,
    TokensOut,
)
from app.modules.auth.service import (
    firebase_email_sign_in,
    google_sign_in,
    issue_tokens,
    revoke_user_sessions,
    rotate_refresh,
)
from app.otp import OtpProvider, get_otp_provider
from app.otp.firebase import TokenExpiredError, TokenVerifier, get_firebase_token_verifier
from app.ratelimit import client_ip, rate_limit
from app.schemas import utcnow

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/google", response_model=TokensOut)
async def sign_in_google(
    body: GoogleSignInIn,
    request: Request,
    con: Conn,
    verify: Annotated[GoogleTokenVerifier, Depends(get_google_verifier)],
) -> TokensOut:
    """Verify a Google ID token. Creates a student on first sign-in; the email allow-list makes admins."""
    claims = await verify(body.id_token)
    return await google_sign_in(con, request.app.state.config, claims, now=utcnow())


@router.post("/firebase", response_model=TokensOut)
async def sign_in_firebase(
    body: FirebaseSignInIn,
    request: Request,
    con: Conn,
    verify: Annotated[TokenVerifier, Depends(get_firebase_token_verifier)],
) -> TokensOut:
    """Exchange a verified Firebase email/password token for CTMS session tokens."""
    try:
        claims = await verify(body.id_token)
    except TokenExpiredError as exc:
        raise TokenExpired("Firebase ID token expired") from exc
    except Exception as exc:
        raise TokenInvalid("Firebase ID token rejected") from exc
    return await firebase_email_sign_in(con, request.app.state.config, claims, now=utcnow())


@router.post(
    "/phone/request",
    status_code=status.HTTP_202_ACCEPTED,
    response_class=Response,
    dependencies=[rate_limit("otp_request_ip", per="ip", limit_key="rate_otp_request_per_ip")],
)
async def phone_request(
    body: PhoneRequestIn, request: Request, con: Conn, otp: Annotated[OtpProvider, Depends(get_otp_provider)]
) -> Response:
    """Always 202 with an empty body, whether or not the number is a registered driver (TC2).

    Limited to `otp_max_sends_per_window` per `otp_window_seconds` per phone (U4), plus a per-IP limit.
    """
    store = request.app.state.settings_store
    per_phone = int(await store.get("otp_max_sends_per_window", con))
    window_s = int(await store.get("otp_window_seconds", con))
    ttl_s = int(await store.get("otp_ttl_seconds", con))
    now = utcnow()
    since = now - timedelta(seconds=window_s)
    recent = await con.fetchrow(
        """select count(*) as n, min(requested_at) as oldest from public.phone_otp_requests
           where phone = $1 and requested_at > $2""",
        body.phone,
        since,
    )
    if recent["n"] >= per_phone:
        retry = (recent["oldest"] + timedelta(seconds=window_s) - now).total_seconds()
        raise RateLimited(math.ceil(retry), "Too many codes requested; wait, or contact an admin")
    is_driver = bool(
        await con.fetchval(
            "select exists(select 1 from public.users where phone = $1 and role = 'driver' and active)",
            body.phone,
        )
    )
    await otp.issue(con, phone=body.phone, ip=client_ip(request), is_driver=is_driver, now=now, ttl_s=ttl_s)
    return Response(status_code=status.HTTP_202_ACCEPTED)


@router.post("/phone/verify", response_model=TokensOut)
async def phone_verify(
    body: PhoneVerifyIn, request: Request, con: Conn, otp: Annotated[OtpProvider, Depends(get_otp_provider)]
) -> TokensOut:
    """Exchange the OTP for tokens. 400 OTP_INVALID / OTP_EXPIRED. Signs out the driver's other devices."""
    store = request.app.state.settings_store
    ttl_s = int(await store.get("otp_ttl_seconds", con))
    max_attempts = int(await store.get("otp_max_attempts", con))
    now = utcnow()
    await otp.verify(con, phone=body.phone, otp=body.otp, now=now, ttl_s=ttl_s, max_attempts=max_attempts)
    driver = await con.fetchrow(
        "select id from public.users where phone = $1 and role = 'driver' and active",
        body.phone,
    )
    if driver is None:
        raise OtpInvalid()  # same code as a wrong OTP: no enumeration
    config = request.app.state.config
    async with con.transaction():
        # Single active session per driver: the older device gets SESSION_REPLACED (T11, TC3).
        await revoke_user_sessions(request.app, con, driver["id"], "replaced", now=now)
        tokens = await issue_tokens(con, config, user_id=driver["id"], role="driver", now=now)
        await write_audit(
            con,
            actor_id=driver["id"],
            action="auth.phone.verify",
            target_type="user",
            target_id=driver["id"],
            meta={"provider": otp.name},
        )
    return tokens


@router.post("/refresh", response_model=RefreshOut)
async def refresh(body: RefreshIn, request: Request, con: Conn) -> RefreshOut:
    """Rotate the refresh token (sent in the body). Re-using an old one revokes the session."""
    return await rotate_refresh(request.app, con, request.app.state.config, body.refresh_token, now=utcnow())


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def logout(
    request: Request, user: AuthUser, con: Conn, body: Annotated[LogoutIn | None, Body()] = None
) -> Response:
    """Revoke this session's refresh token and remove the push token."""
    now = utcnow()
    async with con.transaction():
        await con.execute(
            """update public.sessions set revoked_at = $2, revoked_reason = 'logout'
               where id = $1 and revoked_at is null""",
            user.session_id,
            now,
        )
        if body is not None and body.push_token:
            await con.execute(
                "delete from public.push_tokens where user_id = $1 and token = $2", user.id, body.push_token
            )
        else:
            await con.execute("delete from public.push_tokens where user_id = $1", user.id)
    await publish(request.app, SESSIONS_REVOKED, user_id=user.id, reason="logout", session_ids=[user.session_id])
    return Response(status_code=status.HTTP_204_NO_CONTENT)
