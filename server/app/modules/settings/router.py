"""GET/PUT /admin/settings: alert radius plus the campus arrival geofence (ADR-10).

Keys: alert_radius_m (starting value 500; the DB value overrides ALERT_RADIUS_M),
campus_lat / campus_lng (null = geofence off, to_campus trips then end by the driver's
button or the auto-close only), campus_radius_m and last_stop_radius_m (metres).

PUT is partial: send only the keys to change. `campus_lat` and `campus_lng` are set
together (both numbers) or cleared together (both null).
"""

from __future__ import annotations

from typing import Any

import asyncpg
from fastapi import APIRouter, Depends, Request

from app.audit import write_audit
from app.db import Conn
from app.errors import ValidationFailed
from app.modules.admin.common import AdminUser
from app.schemas import ApiModel
from app.settings_store import SettingsStore, get_settings_store

router = APIRouter(prefix="/admin/settings", tags=["admin: settings"])

GEOFENCE_RADIUS_MIN_M = 20.0
GEOFENCE_RADIUS_MAX_M = 5000.0
KEYS = ("alert_radius_m", "campus_lat", "campus_lng", "campus_radius_m", "last_stop_radius_m")


class AdminSettings(ApiModel):
    alert_radius_m: float
    campus_lat: float | None = None
    campus_lng: float | None = None
    campus_radius_m: float
    last_stop_radius_m: float


class AdminSettingsIn(ApiModel):
    alert_radius_m: float | None = None
    campus_lat: float | None = None
    campus_lng: float | None = None
    campus_radius_m: float | None = None
    last_stop_radius_m: float | None = None


async def _read(store: SettingsStore, con: asyncpg.Connection) -> AdminSettings:
    return AdminSettings(**{key: await store.get(key, con) for key in KEYS})


def _check_range(name: str, value: float | None, low: float, high: float) -> None:
    if value is not None and not low <= value <= high:
        raise ValidationFailed(f"{name}: must be between {low:g} and {high:g}")


@router.get("", response_model=AdminSettings)
async def get_settings(user: AdminUser, con: Conn, store: SettingsStore = Depends(get_settings_store)) -> AdminSettings:
    return await _read(store, con)


@router.put("", response_model=AdminSettings)
async def put_settings(body: AdminSettingsIn, request: Request, user: AdminUser, con: Conn,
                       store: SettingsStore = Depends(get_settings_store)) -> AdminSettings:
    config = request.app.state.config
    sent = body.model_fields_set
    if not sent:
        raise ValidationFailed("body: send at least one setting")
    for key in ("alert_radius_m", "campus_radius_m", "last_stop_radius_m"):
        if key in sent and getattr(body, key) is None:
            raise ValidationFailed(f"{key}: must be a number")
    _check_range("alert_radius_m", body.alert_radius_m, config.alert_radius_min_m, config.alert_radius_max_m)
    _check_range("campus_radius_m", body.campus_radius_m, GEOFENCE_RADIUS_MIN_M, GEOFENCE_RADIUS_MAX_M)
    _check_range("last_stop_radius_m", body.last_stop_radius_m, GEOFENCE_RADIUS_MIN_M, GEOFENCE_RADIUS_MAX_M)
    _check_range("campus_lat", body.campus_lat, -90, 90)
    _check_range("campus_lng", body.campus_lng, -180, 180)
    if ("campus_lat" in sent) != ("campus_lng" in sent) or (body.campus_lat is None) != (body.campus_lng is None):
        raise ValidationFailed("campus_lat, campus_lng: set both to numbers or both to null")
    changes: dict[str, Any] = {key: getattr(body, key) for key in KEYS if key in sent}
    async with con.transaction():
        for key, value in changes.items():
            previous = await con.fetchval("select value from public.settings where key = $1", key)
            if value is None:  # clearing the campus point: drop the row so the unset default applies
                await con.execute("delete from public.settings where key = $1", key)
            else:
                await con.execute(
                    """insert into public.settings (key, value, updated_by) values ($1, $2, $3)
                       on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by""",
                    key, value, user.id,
                )
            await write_audit(con, actor_id=user.id, action="settings.update", target_type="setting",
                              target_id=key, meta={"from": previous, "to": value})
    store.invalidate()
    return await _read(store, con)
