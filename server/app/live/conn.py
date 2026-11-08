"""DB connection for code outside a request: the batched writer, jobs, the WS
handshake and the DB-tolerant location ingestion path.

    async with live_conn(app) as con: ...

Defaults to `app.db.acquire(app)`. Tests point `app.state.live_conn_provider` at
a callable returning an async context manager (e.g. one yielding the per-test
rolled-back connection, or one raising DbUnavailable to simulate N5).
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import asyncpg

from app.db import acquire


@asynccontextmanager
async def live_conn(app: Any) -> AsyncIterator[asyncpg.Connection]:
    provider = getattr(app.state, "live_conn_provider", None)
    cm = provider() if provider is not None else acquire(app)
    async with cm as con:
        yield con
