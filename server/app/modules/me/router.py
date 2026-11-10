"""GET/PATCH /me, DELETE /me (always 403; see deregistration), PUT /me/push-token, PUT /me/consents (extension).

P4 adds POST /me/location and PUT /me/alert-settings in its own router.
"""

from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Response, status
from pydantic import Field

from app.db import Conn
from app.deps import AuthUser
from app.errors import ForbiddenRole
from app.modules.auth.schemas import UserOut
from app.modules.auth.service import load_user_out
from app.schemas import ApiModel

router = APIRouter(prefix="/me", tags=["me"])


class MeUpdateIn(ApiModel):
    name: str = Field(min_length=1, max_length=120)


class PushTokenIn(ApiModel):
    token: str = Field(min_length=1, max_length=4096)
    platform: Literal["android", "ios"]


class ConsentIn(ApiModel):
    kind: str = Field(min_length=1, max_length=64, pattern=r"^[a-z][a-z0-9_]*$",
                      description="e.g. privacy_notice, student_location, driver_location")
    version: str = Field(min_length=1, max_length=32)


@router.get("", response_model=UserOut)
async def get_me(user: AuthUser, con: Conn) -> UserOut:
    """The current user and role; drivers also get their linked bus."""
    return await load_user_out(con, user.id)


@router.patch("", response_model=UserOut)
async def update_me(body: MeUpdateIn, user: AuthUser, con: Conn) -> UserOut:
    await con.execute("update public.users set name = $2 where id = $1", user.id, body.name)
    return await load_user_out(con, user.id)


@router.put("/push-token", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def put_push_token(body: PushTokenIn, user: AuthUser, con: Conn) -> Response:
    """Register this device's FCM token (moves it to this user if another account had it)."""
    await con.execute(
        """insert into public.push_tokens (user_id, token, platform) values ($1, $2, $3)
           on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform""",
        user.id, body.token, body.platform,
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.put("/consents", status_code=status.HTTP_204_NO_CONTENT, response_class=Response,
            summary="Record a consent (extension, not in the API spec)")
async def put_consent(body: ConsentIn, user: AuthUser, con: Conn) -> Response:
    """Extension (runbook p.4): record that the user accepted a privacy notice / location consent."""
    await con.execute(
        """insert into public.consents (user_id, kind, version) values ($1, $2, $3)
           on conflict (user_id, kind, version) do nothing""",
        user.id, body.kind, body.version,
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def delete_me(user: AuthUser) -> Response:
    """Nobody deletes their own account here. Students request deregistration
    (`POST /me/deregistration-request`) and an admin approves it; drivers and admins are managed by admins."""
    if user.role == "student":
        raise ForbiddenRole("Students cannot delete their account; request deregistration instead")
    raise ForbiddenRole()
