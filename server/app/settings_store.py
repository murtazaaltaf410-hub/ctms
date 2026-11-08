"""Runtime thresholds: the `settings` table first, config (env) as fallback.

    store = request.app.state.settings_store        # or Depends(get_settings_store)
    radius = await store.get("alert_radius_m", con)  # refreshes the cache if stale
    radius = store.get_cached("alert_radius_m")      # no I/O (hot paths, jobs)

Keys are the `settings` table keys; the fallback is the `Settings` field of the
same name. After writing the table (PUT /admin/settings) call `invalidate()`.
"""

from __future__ import annotations

import logging
import time
from typing import Any

import asyncpg
from fastapi import Request

from app.config import Settings

log = logging.getLogger("ctms.settings")


class SettingsStore:
    def __init__(self, config: Settings, ttl_s: float | None = None) -> None:
        self._config = config
        self._ttl_s = config.settings_cache_ttl_s if ttl_s is None else ttl_s
        self._values: dict[str, Any] = {}
        self._loaded_at: float | None = None

    def _fallback(self, key: str) -> Any:
        if key not in type(self._config).model_fields:
            raise KeyError(f"unknown setting {key!r}")
        return getattr(self._config, key)

    def _coerce(self, key: str, value: Any) -> Any:
        """Cast a DB value to the type of the config field (e.g. jsonb 50 -> float)."""
        fallback = self._fallback(key)
        try:
            if isinstance(fallback, bool) or fallback is None:
                return value
            return type(fallback)(value)
        except (TypeError, ValueError):
            log.warning("setting %s has invalid value %r; using %r", key, value, fallback)
            return fallback

    def is_stale(self) -> bool:
        return self._loaded_at is None or time.monotonic() - self._loaded_at > self._ttl_s

    async def refresh(self, con: asyncpg.Connection) -> None:
        rows = await con.fetch("select key, value from public.settings")
        self._values = {row["key"]: row["value"] for row in rows}
        self._loaded_at = time.monotonic()

    def invalidate(self) -> None:
        self._loaded_at = None

    def get_cached(self, key: str) -> Any:
        if key in self._values:
            return self._coerce(key, self._values[key])
        return self._fallback(key)

    async def get(self, key: str, con: asyncpg.Connection | None = None) -> Any:
        if con is not None and self.is_stale():
            await self.refresh(con)
        return self.get_cached(key)


def get_settings_store(request: Request) -> SettingsStore:
    return request.app.state.settings_store
