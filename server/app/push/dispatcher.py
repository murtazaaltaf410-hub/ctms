"""Background push delivery: a bounded queue and one worker task.

    from app.push import PushJob, get_push
    get_push(app).submit(PushJob(title=..., body=..., user_ids=(student_id,)))   # never blocks

Tokens are looked up when the job is delivered, not when it is queued, so a
student who deletes their account (U2) or signs out before delivery gets nothing.
Delivery (N9): tokens FCM reports invalid are deleted; other failures are retried
once; anything still failing is logged and dropped (the student sees the alert in
`GET /me/alerts` next time the app opens).

The worker starts with the app (lifespan hook). Tests have no lifespan and call
`await get_push(app).drain(app)` to deliver what was queued.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator, Callable
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass, field
from uuid import UUID

import asyncpg
from fastapi import FastAPI

from app.db import acquire
from app.live import on_shutdown, on_startup
from app.push.base import PushMessage, PushSender, is_invalid_token
from app.push.senders import build_sender

log = logging.getLogger("ctms.push")


def background_conn(app: FastAPI) -> AbstractAsyncContextManager[asyncpg.Connection]:
    """A DB connection outside a request. Tests set `app.state.background_conn` to a
    callable returning an async context manager around their rolled-back connection."""
    provider: Callable[[], AbstractAsyncContextManager[asyncpg.Connection]] | None = getattr(
        app.state, "background_conn", None)
    return provider() if provider is not None else acquire(app)


@dataclass(frozen=True)
class PushJob:
    title: str
    body: str
    data: dict[str, str] = field(default_factory=dict)
    tag: str | None = None
    user_ids: tuple[UUID, ...] | None = None  # None = every active student


class PushDispatcher:
    def __init__(self, sender: PushSender, maxsize: int) -> None:
        self.sender = sender
        self.queue: asyncio.Queue[PushJob] = asyncio.Queue(maxsize=maxsize)
        self._task: asyncio.Task | None = None
        self.dropped = 0

    def submit(self, job: PushJob) -> bool:
        try:
            self.queue.put_nowait(job)
            return True
        except asyncio.QueueFull:
            self.dropped += 1
            log.warning("push queue full; dropped job %r (%d dropped so far)", job.title, self.dropped)
            return False

    async def _tokens(self, app: FastAPI, job: PushJob) -> list[str]:
        async with background_conn(app) as con:
            if job.user_ids is None:
                rows = await con.fetch(
                    """select t.token from public.push_tokens t join public.users u on u.id = t.user_id
                       where u.role = 'student' and u.active""")
            else:
                rows = await con.fetch(
                    """select t.token from public.push_tokens t join public.users u on u.id = t.user_id
                       where t.user_id = any($1::uuid[]) and u.active""", list(job.user_ids))
        return [r["token"] for r in rows]

    async def deliver(self, app: FastAPI, job: PushJob) -> None:
        tokens = await self._tokens(app, job)
        if not tokens:
            return
        pending = [PushMessage(token=t, title=job.title, body=job.body, data=job.data, tag=job.tag) for t in tokens]
        invalid: list[str] = []
        failed: list[PushMessage] = []
        for attempt in (1, 2):  # N9: one retry for failures that are not invalid tokens
            results = await self.sender.send(pending)
            failed = []
            for msg, res in zip(pending, results, strict=True):
                if res.ok:
                    continue
                if is_invalid_token(res.exception):
                    invalid.append(msg.token)
                else:
                    failed.append(msg)
            if not failed:
                break
            if attempt == 1:
                pending = failed
        if invalid:
            async with background_conn(app) as con:
                await con.execute("delete from public.push_tokens where token = any($1::text[])", invalid)
            log.info("deleted %d invalid push token(s)", len(invalid))
        if failed:
            log.warning("push %r failed for %d token(s) after one retry", job.title, len(failed))

    async def drain(self, app: FastAPI) -> None:
        """Deliver every queued job now (tests; also used on shutdown)."""
        while not self.queue.empty():
            job = self.queue.get_nowait()
            try:
                await self.deliver(app, job)
            finally:
                self.queue.task_done()

    async def _run(self, app: FastAPI) -> None:
        while True:
            job = await self.queue.get()
            try:
                await self.deliver(app, job)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("push job %r failed", job.title)
            finally:
                self.queue.task_done()

    def start(self, app: FastAPI) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._run(app), name="push-dispatcher")

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
            self._task = None


def get_push(app: FastAPI) -> PushDispatcher:
    push: PushDispatcher | None = getattr(app.state, "push", None)
    if push is None:
        config = app.state.config
        push = app.state.push = PushDispatcher(build_sender(config), config.push_queue_max)
    return push


@on_startup
async def _start_push(app: FastAPI) -> None:
    push = get_push(app)
    push.start(app)
    log.info("push provider: %s", push.sender.name)


@on_shutdown
async def _stop_push(app: FastAPI) -> None:
    await get_push(app).stop()


@contextlib.asynccontextmanager
async def _shared(con: asyncpg.Connection) -> AsyncIterator[asyncpg.Connection]:
    yield con


def use_connection(app: FastAPI, con: asyncpg.Connection) -> None:
    """Tests: make background work (push, alert engine) use `con`."""
    app.state.background_conn = lambda: _shared(con)

