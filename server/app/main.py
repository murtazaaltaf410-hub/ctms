"""App factory and lifespan.

    uv run uvicorn app.main:app --port 8000      # /docs, /health, /api/v1/...

`create_app(config)` builds all non-I/O state immediately (so tests can use the
app without running the lifespan); the lifespan opens the DB pool, runs the
startup hooks from `app.live` and starts the jobs from `app.jobs`.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Response
from fastapi.middleware.cors import CORSMiddleware

from app.api.router import API_PREFIX, api_router
from app.config import Settings, get_config
from app.db import Conn, create_pool
from app.errors import ERROR_CLASSES, install_error_handlers
from app.jobs import start_jobs, stop_jobs
from app.live import run_shutdown_hooks, run_startup_hooks
from app.live.ws import register as register_live_ws
from app.logging_mw import install_request_logging
from app.modules.auth.google import GoogleVerifier
from app.ratelimit import RateLimiter
from app.schemas import iso_utc, utcnow
from app.security_headers import SecurityHeadersMiddleware
from app.settings_store import SettingsStore

log = logging.getLogger("ctms")

_ERROR_TABLE = "\n".join(f"| {cls.status_code} | `{cls.code}` | {cls.message} |" for cls in ERROR_CLASSES)
DESCRIPTION = f"""CTMS V1 API (University of Kashmir, North Campus). All endpoints are under `{API_PREFIX}`
and use `Authorization: Bearer <access_token>` except sign-in. Times are UTC ISO-8601 (`Z`), distances
metres, speeds m/s, IDs UUIDs.

Errors: `{{"error": {{"code": "...", "message": "..."}}}}`; 429 responses carry `Retry-After`.

| HTTP | Code | Meaning |
|---|---|---|
{_ERROR_TABLE}
"""


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    config: Settings = app.state.config
    app.state.pool = await create_pool(config)
    try:
        async with app.state.pool.acquire() as con:
            await app.state.settings_store.refresh(con)
        await run_startup_hooks(app)
        await start_jobs(app)
        log.info("CTMS server started (APP_ENV=%s)", config.app_env)
        yield
    finally:
        await stop_jobs(app)
        await run_shutdown_hooks(app)
        await app.state.pool.close()
        app.state.pool = None


def init_state(app: FastAPI, config: Settings) -> None:
    app.state.config = config
    app.state.pool = None
    app.state.settings_store = SettingsStore(config)
    app.state.rate_limiter = RateLimiter()
    app.state.google_verifier = GoogleVerifier(config.google_oauth_client_ids)


def create_app(config: Settings | None = None) -> FastAPI:
    config = config or get_config()
    logging.basicConfig(level=config.log_level)
    app = FastAPI(title="CTMS V1 API", version="1.0.0", description=DESCRIPTION, lifespan=lifespan,
                  docs_url="/docs", openapi_url="/openapi.json")
    init_state(app, config)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=config.allowed_origins,
        allow_credentials=False,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
        expose_headers=["Retry-After", "X-Request-ID"],
        max_age=config.cors_max_age_s,
    )
    app.add_middleware(SecurityHeadersMiddleware, config=config)
    install_request_logging(app, config)  # Phase 9: JSON logs + redaction + request lines
    install_error_handlers(app)
    app.include_router(api_router)
    register_live_ws(app)  # Phase 3: /api/v1/ws/live (outside api_router, whose rate limit needs a Request)

    @app.get("/health", tags=["ops"])
    @app.get(f"{API_PREFIX}/health", tags=["ops"], include_in_schema=False)
    async def health(con: Conn, response: Response) -> dict:
        """Liveness + database check (503 DB_UNAVAILABLE when the DB is unreachable)."""
        await con.fetchval("select 1")
        response.headers["Cache-Control"] = "no-store"
        return {"status": "ok", "db": "ok", "env": config.app_env, "time": iso_utc(utcnow())}

    return app


app = create_app()
