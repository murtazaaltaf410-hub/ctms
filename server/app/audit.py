"""Audit log writes (runbook: role changes, sign-ins, admin actions).

`meta` must never hold raw coordinates, tokens, OTP codes, emails or phones.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

import asyncpg


async def write_audit(con: asyncpg.Connection, *, actor_id: UUID | None, action: str,
                      target_type: str | None = None, target_id: UUID | str | None = None,
                      meta: dict[str, Any] | None = None) -> None:
    await con.execute(
        """insert into public.audit_log (actor_id, action, target_type, target_id, meta)
           values ($1, $2, $3, $4, $5)""",
        actor_id, action, target_type, None if target_id is None else str(target_id), meta or {},
    )


async def scrub_user_audit(con: asyncpg.Connection, user_id: UUID) -> None:
    """Remove personal data from audit rows about or by a user being deleted."""
    await con.execute(
        """update public.audit_log set meta = '{}'::jsonb
           where actor_id = $1 or (target_type = 'user' and target_id = $2)""",
        user_id, str(user_id),
    )
