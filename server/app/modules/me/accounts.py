"""Account deletion shared by the admin deregistration approval (students cannot delete themselves).

Deletes the user row; the cascade removes sessions, push tokens, consents, the latest location, alert
settings, the alert log, the registration (with its photo), pickup pins and deregistration requests.
Audit rows keep no personal data: those about or by the user are scrubbed first.
"""

from __future__ import annotations

from uuid import UUID

import asyncpg
from fastapi import FastAPI

from app.audit import scrub_user_audit, write_audit
from app.live import USER_DELETED, publish


async def delete_user_rows(con: asyncpg.Connection, user_id: UUID, *, actor_id: UUID | None,
                           action: str = "account.delete") -> None:
    """Inside the caller's transaction: scrub the audit trail, record `action` (by `actor_id`), delete the user."""
    async with con.transaction():
        await scrub_user_audit(con, user_id)
        await write_audit(con, actor_id=actor_id, action=action, target_type="user", target_id=user_id)
        await con.execute("delete from public.users where id = $1", user_id)


async def delete_user_account(app: FastAPI, con: asyncpg.Connection, user_id: UUID, *,
                              actor_id: UUID | None, action: str = "account.delete") -> None:
    """Delete in one transaction, then close the user's live sockets and drop their in-memory alert state
    (USER_DELETED), which must only happen once the delete has committed."""
    await delete_user_rows(con, user_id, actor_id=actor_id, action=action)
    await publish(app, USER_DELETED, user_id=user_id)
