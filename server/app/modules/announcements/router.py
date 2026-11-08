"""GET /announcements and POST/PATCH/DELETE /admin/announcements (API spec p.4-5).

Lists use `?limit=` (default 50, max 200) and an opaque `?cursor=`; the response is
`{"items": [...], "next_cursor": "..." | null}`. Deletes are soft (active=false).
Every new announcement is broadcast on the WebSocket as
`{"type": "announcement", "id", "title", "urgent"}`; `push: true` also sends FCM to all students.
"""

from __future__ import annotations

import base64
import binascii
from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request, Response, status
from pydantic import Field, model_validator

from app.audit import write_audit
from app.db import Conn
from app.deps import AuthUser, CurrentUser, require_role
from app.errors import NotFound, ValidationFailed
from app.live.hub import broadcast
from app.push import PushJob, get_push
from app.schemas import ApiModel, UtcDateTime, utcnow

router = APIRouter(tags=["announcements"])

Admin = Annotated[CurrentUser, Depends(require_role("admin"))]

PUSH_BODY_MAX = 240
COLUMNS = "id, title, body, urgent, created_at, updated_at"


class AnnouncementOut(ApiModel):
    id: UUID
    title: str
    body: str
    urgent: bool
    created_at: UtcDateTime
    updated_at: UtcDateTime


class AnnouncementPage(ApiModel):
    items: list[AnnouncementOut]
    next_cursor: str | None


class AnnouncementIn(ApiModel):
    title: str = Field(min_length=1, max_length=200)
    body: str = Field(max_length=4000)
    urgent: bool = False
    push: bool = False


class AnnouncementPatch(ApiModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    body: str | None = Field(default=None, max_length=4000)
    urgent: bool | None = None

    @model_validator(mode="after")
    def _not_empty(self) -> AnnouncementPatch:
        if self.title is None and self.body is None and self.urgent is None:
            raise ValueError("give at least one of title, body, urgent")
        return self


def encode_cursor(created_at: datetime, ann_id: UUID) -> str:
    return base64.urlsafe_b64encode(f"{created_at.isoformat()}|{ann_id}".encode()).decode().rstrip("=")


def decode_cursor(cursor: str) -> tuple[datetime, UUID]:
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
        stamp, ann_id = raw.split("|", 1)
        return datetime.fromisoformat(stamp), UUID(ann_id)
    except (ValueError, binascii.Error, UnicodeDecodeError) as exc:
        raise ValidationFailed("cursor: invalid") from exc


@router.get("/announcements", response_model=AnnouncementPage)
async def list_announcements(user: AuthUser, con: Conn,
                             limit: Annotated[int, Query(ge=1, le=200)] = 50,
                             cursor: Annotated[str | None, Query(max_length=200)] = None) -> AnnouncementPage:
    """Active announcements, newest first, with the urgent flag."""
    after_at, after_id = decode_cursor(cursor) if cursor else (None, None)
    rows = await con.fetch(
        f"""select {COLUMNS} from public.announcements
            where active and ($1::timestamptz is null or (created_at, id) < ($1, $2::uuid))
            order by created_at desc, id desc
            limit $3""",  # noqa: S608 (constant column list)
        after_at, after_id, limit + 1,
    )
    items = [AnnouncementOut(**dict(row)) for row in rows[:limit]]
    next_cursor = encode_cursor(rows[limit - 1]["created_at"], rows[limit - 1]["id"]) if len(rows) > limit else None
    return AnnouncementPage(items=items, next_cursor=next_cursor)


@router.post("/admin/announcements", response_model=AnnouncementOut, status_code=status.HTTP_201_CREATED)
async def create_announcement(body: AnnouncementIn, request: Request, user: Admin, con: Conn) -> AnnouncementOut:
    now = utcnow()
    async with con.transaction():
        row = await con.fetchrow(
            f"""insert into public.announcements (title, body, urgent, created_by, created_at, updated_at)
                values ($1, $2, $3, $4, $5, $5) returning {COLUMNS}""",  # noqa: S608
            body.title, body.body, body.urgent, user.id, now,
        )
        await write_audit(con, actor_id=user.id, action="announcement.create", target_type="announcement",
                          target_id=row["id"], meta={"urgent": body.urgent, "push": body.push})
    ann = AnnouncementOut(**dict(row))
    await broadcast(request.app, {"type": "announcement", "id": str(ann.id), "title": ann.title,
                                  "urgent": ann.urgent})
    if body.push:
        text = ann.body if len(ann.body) <= PUSH_BODY_MAX else ann.body[:PUSH_BODY_MAX - 1] + "…"
        get_push(request.app).submit(PushJob(
            title=ann.title, body=text, user_ids=None,
            data={"type": "announcement", "id": str(ann.id), "urgent": str(ann.urgent).lower()},
        ))
    return ann


@router.patch("/admin/announcements/{announcement_id}", response_model=AnnouncementOut)
async def update_announcement(announcement_id: UUID, body: AnnouncementPatch, user: Admin,
                              con: Conn) -> AnnouncementOut:
    async with con.transaction():
        row = await con.fetchrow(
            f"""update public.announcements
                set title = coalesce($2, title), body = coalesce($3, body), urgent = coalesce($4, urgent)
                where id = $1 and active returning {COLUMNS}""",  # noqa: S608
            announcement_id, body.title, body.body, body.urgent,
        )
        if row is None:
            raise NotFound("Announcement not found")
        changed = sorted(k for k, v in body.model_dump().items() if v is not None)
        await write_audit(con, actor_id=user.id, action="announcement.update", target_type="announcement",
                          target_id=announcement_id, meta={"fields": changed})
    return AnnouncementOut(**dict(row))


@router.delete("/admin/announcements/{announcement_id}", status_code=status.HTTP_204_NO_CONTENT,
               response_class=Response)
async def delete_announcement(announcement_id: UUID, user: Admin, con: Conn) -> Response:
    """Soft delete: the announcement leaves the feed but stays in the database."""
    async with con.transaction():
        found = await con.fetchval(
            "update public.announcements set active = false where id = $1 and active returning id",
            announcement_id)
        if found is None:
            raise NotFound("Announcement not found")
        await write_audit(con, actor_id=user.id, action="announcement.delete", target_type="announcement",
                          target_id=announcement_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
