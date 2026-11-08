"""asyncpg pool and the per-request connection dependency (ADR-2).

Usage in a router:

    from app.db import Conn

    @router.get("/x")
    async def x(con: Conn): rows = await con.fetch("select ... where id = $1", some_id)

Use `async with con.transaction():` for multi-statement writes; inside tests the
connection already sits in an outer transaction, so this becomes a SAVEPOINT.
Background jobs use `acquire(app)` instead of the dependency.
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Annotated

import asyncpg
from fastapi import Depends, FastAPI, Request

from app.config import Settings
from app.errors import DB_CONNECTION_ERRORS, DbUnavailable


async def init_conn(con: asyncpg.Connection) -> None:
    await con.set_type_codec("jsonb", schema="pg_catalog", encoder=json.dumps, decoder=json.loads,
                             format="text")


async def create_pool(config: Settings) -> asyncpg.Pool:
    kwargs: dict = {
        "min_size": config.db_pool_min_size,
        "max_size": config.db_pool_max_size,
        "command_timeout": config.db_command_timeout_s,
        "init": init_conn,
    }
    if config.db_statement_cache_size is not None:
        kwargs["statement_cache_size"] = config.db_statement_cache_size
    return await asyncpg.create_pool(config.database_url, **kwargs)


@asynccontextmanager
async def acquire(app: FastAPI) -> AsyncIterator[asyncpg.Connection]:
    """A pooled connection outside a request (jobs, WebSocket handlers)."""
    pool: asyncpg.Pool | None = getattr(app.state, "pool", None)
    if pool is None:
        raise DbUnavailable()
    try:
        con = await pool.acquire()
    except DB_CONNECTION_ERRORS as exc:
        raise DbUnavailable() from exc
    try:
        yield con
    finally:
        await pool.release(con)


async def get_conn(request: Request) -> AsyncIterator[asyncpg.Connection]:
    async with acquire(request.app) as con:
        yield con


Conn = Annotated[asyncpg.Connection, Depends(get_conn)]
