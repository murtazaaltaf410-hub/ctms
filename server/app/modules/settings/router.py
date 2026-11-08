"""GET/PUT /admin/settings: {alert_radius_m} (starting value 500; the DB value overrides ALERT_RADIUS_M)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from app.audit import write_audit
from app.db import Conn
from app.errors import ValidationFailed
from app.modules.admin.common import AdminUser
from app.schemas import ApiModel
from app.settings_store import SettingsStore, get_settings_store

router = APIRouter(prefix="/admin/settings", tags=["admin: settings"])


class AdminSettings(ApiModel):
    alert_radius_m: float


@router.get("", response_model=AdminSettings)
async def get_settings(user: AdminUser, con: Conn, store: SettingsStore = Depends(get_settings_store)) -> AdminSettings:
    return AdminSettings(alert_radius_m=await store.get("alert_radius_m", con))


@router.put("", response_model=AdminSettings)
async def put_settings(body: AdminSettings, request: Request, user: AdminUser, con: Conn,
                       store: SettingsStore = Depends(get_settings_store)) -> AdminSettings:
    config = request.app.state.config
    if not config.alert_radius_min_m <= body.alert_radius_m <= config.alert_radius_max_m:
        raise ValidationFailed(f"alert_radius_m: must be between {config.alert_radius_min_m:g} and "
                               f"{config.alert_radius_max_m:g} metres")
    async with con.transaction():
        previous = await con.fetchval("select value from public.settings where key = 'alert_radius_m'")
        await con.execute(
            """insert into public.settings (key, value, updated_by) values ('alert_radius_m', $1, $2)
               on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by""",
            body.alert_radius_m, user.id,
        )
        await write_audit(con, actor_id=user.id, action="settings.update", target_type="setting",
                          target_id="alert_radius_m", meta={"from": previous, "to": body.alert_radius_m})
    store.invalidate()
    return AdminSettings(alert_radius_m=await store.get("alert_radius_m", con))
