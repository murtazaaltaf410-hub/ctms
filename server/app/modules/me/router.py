"""GET/PATCH/DELETE /me, PUT /me/push-token, PUT /me/consents (extension).

P4 adds POST /me/location and PUT /me/alert-settings in its own router.
"""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Request, Response, status
from pydantic import Field

from app.audit import scrub_user_audit, write_audit
from app.db import Conn
from app.deps import AuthUser, CurrentUser, require_role
from app.live import USER_DELETED, publish
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
async def delete_me(request: Request, user: Annotated[CurrentUser, Depends(require_role("student"))],
                    con: Conn) -> Response:
    """Students only. Deletes the account and, by cascade, sessions, push tokens, consents, the latest
    location, alert settings and the alert log (U2, TC20). Audit rows keep no personal data."""
    async with con.transaction():
        await scrub_user_audit(con, user.id)
        await write_audit(con, actor_id=None, action="account.delete", target_type="user", target_id=user.id)
        await con.execute("delete from public.users where id = $1", user.id)
    await publish(request.app, USER_DELETED, user_id=user.id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
