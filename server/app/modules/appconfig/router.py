"""GET /api/v1/config: public values the app reads at launch, before sign-in (runbook p.2).

Not in the API spec (extension, requirements-matrix "ext"). The app compares its
build version with `min_app_version` and blocks with an "update required" screen
when it is older. The thresholds let the app style stale/offline buses and size
its batches without hard-coding them.

Works with the DB down: values come from the settings cache, refreshed when stale
if the DB answers, otherwise the last cached value or the env/config fallback.
"""

from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Request, Response

from app.db import acquire
from app.errors import DB_CONNECTION_ERRORS, DbUnavailable
from app.schemas import ApiModel, UtcDateTime, utcnow

router = APIRouter(tags=["config"])

# Settings-store keys returned as-is (settings table first, config fallback).
PUBLIC_KEYS = (
    "min_app_version",
    "alert_radius_m",
    "stale_after_s",
    "offline_after_s",
    "ws_heartbeat_s",
    "location_batch_max",
    "gps_accuracy_max_m",
    "student_move_report_m",
    "student_fix_max_accuracy_m",
    "eta_display_cap_s",
    "timezone",
    "campus_lat",
    "campus_lng",
    "campus_radius_m",
)


class AppConfigOut(ApiModel):
    min_app_version: str
    app_update_url: str | None
    alert_radius_m: float
    stale_after_s: float
    offline_after_s: float
    ws_heartbeat_s: float
    location_batch_max: int
    gps_accuracy_max_m: float
    student_move_report_m: float
    student_fix_max_accuracy_m: float
    eta_display_cap_s: float
    timezone: str
    campus_lat: float | None = None   # null until an admin pins the campus (arrival geofence off)
    campus_lng: float | None = None
    campus_radius_m: float = 150
    env: str
    server_time: UtcDateTime


async def _refresh_if_stale(request: Request) -> None:
    store = request.app.state.settings_store
    if not store.is_stale():
        return
    try:
        async with acquire(request.app) as con:
            await store.refresh(con)
    except (DbUnavailable, asyncpg.PostgresError, *DB_CONNECTION_ERRORS):
        pass  # serve cached / fallback values; the app must start even if the DB is down


@router.get("/config", response_model=AppConfigOut)
async def get_app_config(request: Request, response: Response) -> AppConfigOut:
    """Public (no token). Minimum supported app version and client-side thresholds."""
    await _refresh_if_stale(request)
    store = request.app.state.settings_store
    config = request.app.state.config
    values = {key: store.get_cached(key) for key in PUBLIC_KEYS}
    values["min_app_version"] = str(values["min_app_version"])
    response.headers["Cache-Control"] = "public, max-age=60"
    return AppConfigOut(**values, app_update_url=config.app_update_url, env=config.app_env,
                        server_time=utcnow())
