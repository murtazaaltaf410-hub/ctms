"""Background jobs (ADR-4): plain asyncio tasks started in the lifespan.

Phases 3-5 add job modules (e.g. app/jobs/trips.py) and register at import time:

    from app.jobs import register_job

    async def auto_close_tick(app: FastAPI) -> None:      # one pass; tests call it directly
        async with acquire(app) as con: ...

    register_job("trip_auto_close", auto_close_tick, interval_s=lambda app: 60)
    # interval_s: a number, or a callable(app) -> float read each loop (e.g. from
    # app.state.settings_store.get_cached("db_batch_interval_s")).

Import the job module from your router module so it registers before startup.
`start_jobs(app)` / `stop_jobs(app)` are called by main.py's lifespan; a failing
tick is logged and the loop continues.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from fastapi import FastAPI

log = logging.getLogger("ctms.jobs")

Tick = Callable[[FastAPI], Awaitable[None]]
Interval = float | Callable[[FastAPI], float]


@dataclass(frozen=True)
class Job:
    name: str
    tick: Tick
    interval_s: Interval


_jobs: dict[str, Job] = {}


def register_job(name: str, tick: Tick, *, interval_s: Interval) -> None:
    _jobs[name] = Job(name, tick, interval_s)


def registered_jobs() -> list[Job]:
    return list(_jobs.values())


async def run_forever(app: FastAPI, job: Job, stop: asyncio.Event) -> None:
    while not stop.is_set():
        interval = job.interval_s(app) if callable(job.interval_s) else job.interval_s
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop.wait(), timeout=float(interval))
        if stop.is_set():
            break
        try:
            await job.tick(app)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("job %s tick failed", job.name)


async def start_jobs(app: FastAPI) -> None:
    stop = asyncio.Event()
    app.state.jobs_stop = stop
    app.state.job_tasks = [
        asyncio.create_task(run_forever(app, job, stop), name=f"job:{job.name}") for job in registered_jobs()
    ]
    if app.state.job_tasks:
        log.info("started jobs: %s", ", ".join(job.name for job in registered_jobs()))


async def stop_jobs(app: FastAPI) -> None:
    stop: asyncio.Event | None = getattr(app.state, "jobs_stop", None)
    tasks: list[asyncio.Task] = getattr(app.state, "job_tasks", [])
    if stop is not None:
        stop.set()
    for task in tasks:
        task.cancel()
    for task in tasks:
        with contextlib.suppress(asyncio.CancelledError):
            await task
    app.state.job_tasks = []
