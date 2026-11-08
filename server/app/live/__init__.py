"""Live state package (Phase 3 owns the contents) + the lifecycle/event hook registry.

Phase 2 provides only this registry so later phases plug in without editing
main.py:

Lifecycle (run inside the FastAPI lifespan, after the DB pool exists):

    from app.live import on_startup, on_shutdown

    @on_startup
    async def start_live_state(app: FastAPI) -> None: app.state.live = LiveState(...)

Domain events (published by the auth/me code, consumed by P3/P4):

    from app.live import subscribe, USER_DELETED, SESSIONS_REVOKED

    @subscribe(SESSIONS_REVOKED)        # payload: user_id: UUID, reason: str, session_ids: list[UUID]
    async def drop_sockets(app, *, user_id, reason, session_ids): ...   # P3: close revoked WS clients

    @subscribe(USER_DELETED)            # payload: user_id: UUID
    async def forget_student(app, *, user_id): ...                      # P4: drop in-memory alert state

Hooks must be registered at import time of a module that `app/api/router.py`
imports (i.e. next to your router). Handler errors are logged, never raised.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from typing import Any

from fastapi import FastAPI

log = logging.getLogger("ctms.hooks")

LifecycleHook = Callable[[FastAPI], Awaitable[None]]
EventHandler = Callable[..., Awaitable[None]]

USER_DELETED = "user_deleted"
SESSIONS_REVOKED = "sessions_revoked"

_startup: list[LifecycleHook] = []
_shutdown: list[LifecycleHook] = []
_handlers: dict[str, list[EventHandler]] = {}


def on_startup(fn: LifecycleHook) -> LifecycleHook:
    if fn not in _startup:
        _startup.append(fn)
    return fn


def on_shutdown(fn: LifecycleHook) -> LifecycleHook:
    if fn not in _shutdown:
        _shutdown.append(fn)
    return fn


def subscribe(event: str) -> Callable[[EventHandler], EventHandler]:
    def register(fn: EventHandler) -> EventHandler:
        handlers = _handlers.setdefault(event, [])
        if fn not in handlers:
            handlers.append(fn)
        return fn

    return register


async def publish(app: FastAPI, event: str, **payload: Any) -> None:
    for fn in list(_handlers.get(event, ())):
        try:
            await fn(app, **payload)
        except Exception:
            log.exception("event handler %s for %s failed", getattr(fn, "__name__", fn), event)


async def run_startup_hooks(app: FastAPI) -> None:
    for fn in list(_startup):
        await fn(app)


async def run_shutdown_hooks(app: FastAPI) -> None:
    for fn in reversed(_shutdown):
        try:
            await fn(app)
        except Exception:
            log.exception("shutdown hook %s failed", getattr(fn, "__name__", fn))
