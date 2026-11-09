"""POST /auth/google, /auth/firebase, /auth/login, /auth/change-password, /auth/refresh, /auth/logout."""

from __future__ import annotations

import asyncio
from datetime import timedelta
from typing import Annotated

from fastapi import APIRouter, Body, Depends, Request, Response, status

from app.audit import write_audit
from app.db import Conn
from app.deps import AuthUser, CurrentUser, require_role
from app.errors import InvalidCredentials, TokenExpired, TokenInvalid, ValidationFailed
from app.integrations.firebase import TokenExpiredError, TokenVerifier, get_firebase_token_verifier
from app.live import SESSIONS_REVOKED, publish
from app.modules.auth.google import GoogleTokenVerifier, get_google_verifier
from app.modules.auth.schemas import (
    ChangePasswordIn,
    FirebaseSignInIn,
    GoogleSignInIn,
    LoginIn,
    LoginOut,
    LogoutIn,
    RefreshIn,
    RefreshOut,
    TokensOut,
    normalise_identifier,
)
from app.modules.auth.service import (
    firebase_email_sign_in,
    google_sign_in,
    issue_tokens,
    revoke_user_sessions,
    rotate_refresh,
)
from app.ratelimit import rate_limit
from app.schemas import utcnow
from app.security import hash_password, verify_password

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
    "/login",
    response_model=LoginOut,
    dependencies=[rate_limit("login_ip", per="ip", limit_key="rate_login_per_ip")],
)
async def login(body: LoginIn, request: Request, con: Conn) -> LoginOut:
    """Driver sign-in with userid, email or phone plus password (ADR-10).

    Unknown identifier, inactive account, wrong password and a locked account all give the same
    401 INVALID_CREDENTIALS after the same amount of work, so nothing tells them apart.
    """
    store = request.app.state.settings_store
    max_failures = int(await store.get("login_max_failures", con))
    lock_s = int(await store.get("login_lock_s", con))
    ident, phone = normalise_identifier(body.identifier)
    now = utcnow()
    row = await con.fetchrow(
        """select id, password_hash, must_change_password, locked_until from public.users
           where role = 'driver' and active and (userid = $1 or email = $1 or phone = $2)
           order by created_at limit 1""",
        ident,
        phone,
    )
    # scrypt is CPU-bound: keep it off the event loop. verify_password burns the same cost with no hash.
    password_ok = await asyncio.to_thread(verify_password, body.password, row["password_hash"] if row else None)
    locked = row is not None and row["locked_until"] is not None and row["locked_until"] > now
    if row is None or locked or not password_ok:
        if row is not None and not locked:
            await con.execute(
                """update public.users set
                     failed_logins = case when failed_logins + 1 >= $2 then 0 else failed_logins + 1 end,
                     locked_until = case when failed_logins + 1 >= $2 then $3::timestamptz else locked_until end
                   where id = $1""",
                row["id"],
                max_failures,
                now + timedelta(seconds=lock_s),
            )
        raise InvalidCredentials()
    config = request.app.state.config
    async with con.transaction():
        await con.execute("update public.users set failed_logins = 0, locked_until = null where id = $1", row["id"])
        # Single active session per driver: the older device gets SESSION_REPLACED (T11, TC3).
        await revoke_user_sessions(request.app, con, row["id"], "replaced", now=now)
        tokens = await issue_tokens(con, config, user_id=row["id"], role="driver", now=now)
        await write_audit(
            con,
            actor_id=row["id"],
            action="auth.password.login",
            target_type="user",
            target_id=row["id"],
            meta={"provider": "password"},
        )
    return LoginOut(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        user=tokens.user,
        must_change_password=bool(row["must_change_password"]),
    )


@router.post("/change-password", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def change_password(
    body: ChangePasswordIn,
    request: Request,
    user: Annotated[CurrentUser, Depends(require_role("driver"))],
    con: Conn,
) -> Response:
    """Driver sets a new password (needs the current one); other sessions are signed out."""
    stored = await con.fetchval("select password_hash from public.users where id = $1", user.id)
    if not await asyncio.to_thread(verify_password, body.current_password, stored):
        raise InvalidCredentials("Current password is wrong")
    if body.new_password == body.current_password:
        raise ValidationFailed("new_password: must differ from the current password")
    new_hash = await asyncio.to_thread(hash_password, body.new_password)
    now = utcnow()
    async with con.transaction():
        await con.execute(
            "update public.users set password_hash = $2, must_change_password = false where id = $1",
            user.id,
            new_hash,
        )
        await revoke_user_sessions(
            request.app, con, user.id, "password_changed", now=now, except_session=user.session_id
        )
        await write_audit(con, actor_id=user.id, action="auth.password.change", target_type="user", target_id=user.id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


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
