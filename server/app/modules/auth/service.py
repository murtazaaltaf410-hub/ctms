"""Sessions, user lookup and sign-in rules shared by the auth and me routers.

Public helpers for later phases:
  * `revoke_user_sessions(app, con, user_id, reason)` - e.g. P5 deactivating a
    driver (reason "deactivated", U3); publishes SESSIONS_REVOKED.
  * `load_user_out(con, user_id)` - the `user` object returned by the API.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from uuid import UUID, uuid4

import asyncpg
from fastapi import FastAPI

from app.audit import write_audit
from app.config import Settings
from app.errors import ForbiddenRole, NotFound, SessionReplaced, TokenExpired, TokenInvalid
from app.live import SESSIONS_REVOKED, publish
from app.modules.auth.schemas import BusOut, RefreshOut, TokensOut, UserOut
from app.security import (
    create_access_token,
    hash_matches,
    new_refresh_token,
    parse_refresh_token,
    sha256_hex,
)

# Constant column list interpolated into SQL below (never user input), hence the S608 noqa markers.
USER_COLUMNS = "id, role, name, email, phone, active, google_sub, firebase_uid, created_at"


async def load_user_out(con: asyncpg.Connection, user_id: UUID) -> UserOut:
    row = await con.fetchrow(f"select {USER_COLUMNS} from public.users where id = $1", user_id)  # noqa: S608
    if row is None:
        raise NotFound("User not found")
    bus = None
    if row["role"] == "driver":
        bus_row = await con.fetchrow(
            "select id, label, plate, default_route_id from public.buses where driver_id = $1 and active",
            user_id,
        )
        bus = BusOut(**dict(bus_row)) if bus_row else None
    return UserOut(
        id=row["id"],
        role=row["role"],
        name=row["name"],
        email=row["email"],
        phone=row["phone"],
        created_at=row["created_at"],
        bus=bus,
    )


async def create_session(
    con: asyncpg.Connection, config: Settings, *, user_id: UUID, role: str, now: datetime
) -> tuple[str, str]:
    """Insert a session; return (access_token, refresh_token)."""
    session_id = uuid4()
    refresh = new_refresh_token(session_id)
    await con.execute(
        """insert into public.sessions (id, user_id, refresh_hash, created_at, last_used_at, expires_at)
           values ($1, $2, $3, $4, $4, $5)""",
        session_id,
        user_id,
        sha256_hex(refresh),
        now,
        now + timedelta(days=config.refresh_token_ttl_days),
    )
    access = create_access_token(
        user_id=user_id,
        session_id=session_id,
        role=role,
        secret=config.jwt_secret,
        ttl_s=config.access_token_ttl_s,
        now=now,
    )
    return access, refresh


async def issue_tokens(
    con: asyncpg.Connection, config: Settings, *, user_id: UUID, role: str, now: datetime
) -> TokensOut:
    access, refresh = await create_session(con, config, user_id=user_id, role=role, now=now)
    return TokensOut(access_token=access, refresh_token=refresh, user=await load_user_out(con, user_id))


async def revoke_user_sessions(
    app: FastAPI,
    con: asyncpg.Connection,
    user_id: UUID,
    reason: str,
    *,
    now: datetime,
    except_session: UUID | None = None,
) -> list[UUID]:
    rows = await con.fetch(
        """update public.sessions set revoked_at = $3, revoked_reason = $2
           where user_id = $1 and revoked_at is null and ($4::uuid is null or id <> $4)
           returning id""",
        user_id,
        reason,
        now,
        except_session,
    )
    session_ids = [row["id"] for row in rows]
    if session_ids:
        await publish(app, SESSIONS_REVOKED, user_id=user_id, reason=reason, session_ids=session_ids)
    return session_ids


async def is_admin_email(con: asyncpg.Connection, config: Settings, email: str) -> bool:
    if config.seed_admin_email and email == config.seed_admin_email:
        return True
    return bool(await con.fetchval("select exists(select 1 from public.admin_allowlist where email = $1)", email))


def _email_verified(claims: dict) -> bool:
    value = claims.get("email_verified")
    return value is True or (isinstance(value, str) and value.lower() == "true")


async def google_sign_in(con: asyncpg.Connection, config: Settings, claims: dict, *, now: datetime) -> TokensOut:
    """Find or create the Google user, apply the admin allow-list, issue tokens."""
    sub = claims.get("sub")
    email = (claims.get("email") or "").strip().lower()
    if not sub or not email or not _email_verified(claims):
        raise TokenInvalid("Google account has no verified email")
    name = str(claims.get("name") or "")[:120]
    admin = await is_admin_email(con, config, email)
    wanted_role = "admin" if admin else "student"

    async with con.transaction():
        row = await con.fetchrow(f"select {USER_COLUMNS} from public.users where google_sub = $1", sub)  # noqa: S608
        if row is None:
            row = await con.fetchrow(
                f"select {USER_COLUMNS} from public.users where email = $1 for update",  # noqa: S608
                email,
            )
            if row is not None and row["google_sub"] not in (None, sub):
                raise TokenInvalid("This email is linked to another Google account")
        if row is None:
            user_id = await con.fetchval(
                """insert into public.users (role, name, email, google_sub) values ($1, $2, $3, $4)
                   returning id""",
                wanted_role,
                name,
                email,
                sub,
            )
            await write_audit(
                con,
                actor_id=user_id,
                action="auth.google.sign_up",
                target_type="user",
                target_id=user_id,
                meta={"role": wanted_role},
            )
            role = wanted_role
        else:
            user_id, role = row["id"], row["role"]
            if not row["active"]:
                raise TokenInvalid("Account is deactivated")
            if role == "driver":
                raise ForbiddenRole("Drivers sign in with their userid, email or phone and password")
            await con.execute(
                "update public.users set google_sub = $2, email = $3 where id = $1 and "
                "(google_sub is distinct from $2 or email is distinct from $3)",
                user_id,
                sub,
                email,
            )
            if role != wanted_role:
                # The allow-list is the source of truth for admin (TRD p.4); log every change.
                await con.execute("update public.users set role = $2 where id = $1", user_id, wanted_role)
                await write_audit(
                    con,
                    actor_id=None,
                    action="user.role_change",
                    target_type="user",
                    target_id=user_id,
                    meta={"from": role, "to": wanted_role, "reason": "admin_allowlist"},
                )
                role = wanted_role
            await write_audit(
                con, actor_id=user_id, action="auth.google.sign_in", target_type="user", target_id=user_id
            )
        return await issue_tokens(con, config, user_id=user_id, role=role, now=now)


async def firebase_email_sign_in(
    con: asyncpg.Connection, config: Settings, claims: dict, *, now: datetime
) -> TokensOut:
    """Link a verified Firebase email identity, then issue a CTMS session."""
    uid = claims.get("uid") or claims.get("sub")
    email = (claims.get("email") or "").strip().lower()
    if not isinstance(uid, str) or not uid or not email or not _email_verified(claims):
        raise TokenInvalid("Firebase account has no verified email")
    name = str(claims.get("name") or email.split("@", 1)[0])[:120]
    wanted_role = "admin" if await is_admin_email(con, config, email) else "student"

    async with con.transaction():
        row = await con.fetchrow(f"select {USER_COLUMNS} from public.users where firebase_uid = $1", uid)  # noqa: S608
        if row is None:
            row = await con.fetchrow(
                f"select {USER_COLUMNS} from public.users where email = $1 for update",  # noqa: S608
                email,
            )
            if row is not None and row["firebase_uid"] not in (None, uid):
                raise TokenInvalid("This email is linked to another Firebase account")
        if row is None:
            user_id = await con.fetchval(
                """insert into public.users (role, name, email, firebase_uid) values ($1, $2, $3, $4)
                   returning id""",
                wanted_role,
                name,
                email,
                uid,
            )
            await write_audit(
                con,
                actor_id=user_id,
                action="auth.firebase_email.sign_up",
                target_type="user",
                target_id=user_id,
                meta={"role": wanted_role},
            )
            role = wanted_role
        else:
            user_id, role = row["id"], row["role"]
            if not row["active"]:
                raise TokenInvalid("Account is deactivated")
            if role == "driver":
                raise ForbiddenRole("Drivers sign in with their userid, email or phone and password")
            await con.execute(
                "update public.users set firebase_uid = $2, email = $3 where id = $1 and "
                "(firebase_uid is distinct from $2 or email is distinct from $3)",
                user_id,
                uid,
                email,
            )
            if role != wanted_role:
                await con.execute("update public.users set role = $2 where id = $1", user_id, wanted_role)
                await write_audit(
                    con,
                    actor_id=None,
                    action="user.role_change",
                    target_type="user",
                    target_id=user_id,
                    meta={"from": role, "to": wanted_role, "reason": "admin_allowlist"},
                )
                role = wanted_role
            await write_audit(
                con, actor_id=user_id, action="auth.firebase_email.sign_in", target_type="user", target_id=user_id
            )
        return await issue_tokens(con, config, user_id=user_id, role=role, now=now)


async def rotate_refresh(
    app: FastAPI, con: asyncpg.Connection, config: Settings, token: str, *, now: datetime
) -> RefreshOut:
    """Rotate a refresh token. A replay of an already-rotated token revokes the session."""
    session_id = parse_refresh_token(token)
    async with con.transaction():
        row = await con.fetchrow(
            """select s.id, s.user_id, s.refresh_hash, s.expires_at, s.revoked_at, s.revoked_reason,
                      u.role, u.active
               from public.sessions s join public.users u on u.id = s.user_id
               where s.id = $1 for update of s""",
            session_id,
        )
        if row is None or not row["active"]:
            raise TokenInvalid()
        if row["revoked_at"] is not None:
            raise SessionReplaced() if row["revoked_reason"] == "replaced" else TokenInvalid()
        if not hash_matches(row["refresh_hash"], token):
            # Reuse of an old (rotated) token: someone else may hold the current one.
            await con.execute(
                "update public.sessions set revoked_at = $2, revoked_reason = 'rotated_reuse' where id = $1",
                session_id,
                now,
            )
            await write_audit(
                con,
                actor_id=row["user_id"],
                action="auth.refresh.reuse_detected",
                target_type="session",
                target_id=session_id,
            )
            reused = True
        else:
            reused = False
        if not reused:
            if row["expires_at"] <= now:
                raise TokenExpired("Session expired; sign in again")
            refresh = new_refresh_token(session_id)
            await con.execute(
                "update public.sessions set refresh_hash = $2, last_used_at = $3 where id = $1",
                session_id,
                sha256_hex(refresh),
                now,
            )
    if reused:
        await publish(app, SESSIONS_REVOKED, user_id=row["user_id"], reason="rotated_reuse", session_ids=[session_id])
        raise TokenInvalid("Refresh token was already used; sign in again")
    access = create_access_token(
        user_id=row["user_id"],
        session_id=session_id,
        role=row["role"],
        secret=config.jwt_secret,
        ttl_s=config.access_token_ttl_s,
        now=now,
    )
    return RefreshOut(access_token=access, refresh_token=refresh)
