"""Authentication and role dependencies.

    from app.deps import CurrentUser, require_role

    @router.get("/admin/buses")
    async def list_buses(user: Annotated[CurrentUser, Depends(require_role("admin"))], con: Conn): ...

`get_current_user` validates the bearer JWT, then loads the session and the user
from the DB on every request (TRD p.4: the role is never trusted from the token).
A revoked session gives SESSION_REPLACED (driver signed in elsewhere) or
TOKEN_INVALID; an inactive or deleted user gives TOKEN_INVALID.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated
from uuid import UUID

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import Settings
from app.db import Conn
from app.errors import ForbiddenRole, SessionReplaced, TokenInvalid
from app.ratelimit import check_rate
from app.security import decode_access_token

bearer = HTTPBearer(auto_error=False, description="Access token from /auth/google or /auth/phone/verify")


@dataclass(frozen=True, slots=True)
class CurrentUser:
    id: UUID
    session_id: UUID
    role: str
    name: str
    email: str | None
    phone: str | None


def get_app_config(request: Request) -> Settings:
    return request.app.state.config


async def get_current_user(
    request: Request,
    con: Conn,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> CurrentUser:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise TokenInvalid("Missing bearer token")
    claims = decode_access_token(credentials.credentials, request.app.state.config.jwt_secret)
    row = await con.fetchrow(
        """select u.id, u.role, u.name, u.email, u.phone, u.active,
                  s.revoked_at, s.revoked_reason
           from public.sessions s join public.users u on u.id = s.user_id
           where s.id = $1 and s.user_id = $2""",
        claims.session_id, claims.user_id,
    )
    if row is None or not row["active"]:
        raise TokenInvalid()
    if row["revoked_at"] is not None:
        raise SessionReplaced() if row["revoked_reason"] == "replaced" else TokenInvalid()
    store = request.app.state.settings_store
    if store.is_stale():
        await store.refresh(con)
    await check_rate(request, "general_user", str(row["id"]), "rate_general_per_user")
    return CurrentUser(id=row["id"], session_id=claims.session_id, role=row["role"], name=row["name"],
                       email=row["email"], phone=row["phone"])


def require_role(*roles: str):
    """Dependency returning the current user if their DB role is one of `roles`."""
    allowed = frozenset(roles)

    async def checker(user: Annotated[CurrentUser, Depends(get_current_user)]) -> CurrentUser:
        if user.role not in allowed:
            raise ForbiddenRole()
        return user

    return checker


AuthUser = Annotated[CurrentUser, Depends(get_current_user)]
