"""In-memory sliding-window rate limiter (ADR-3; single server instance).

    from app.ratelimit import rate_limit
    @router.post("/trips/{id}/locations",
                 dependencies=[rate_limit("locations", per="user", limit_key="rate_locations_per_user")])

`limit_key` / `<limit_key>_window_s` are read through the settings store, so they
come from the `settings` table or the config field of the same name. Excess
requests raise RATE_LIMITED (429 + Retry-After).
"""

from __future__ import annotations

import asyncio
import ipaddress
import math
import time
from collections import deque
from collections.abc import Callable
from typing import Literal

from fastapi import Depends, Request

from app.errors import RateLimited


class RateLimiter:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._hits: dict[tuple[str, str], deque[float]] = {}
        self._lock = asyncio.Lock()
        self._calls = 0

    async def hit(self, bucket: str, key: str, limit: int, window_s: float) -> None:
        """Record one request; raise RateLimited if `limit` is already used in `window_s`."""
        async with self._lock:
            now = self._clock()
            hits = self._hits.setdefault((bucket, key), deque())
            while hits and hits[0] <= now - window_s:
                hits.popleft()
            if len(hits) >= limit:
                raise RateLimited(math.ceil(hits[0] + window_s - now))
            hits.append(now)
            self._calls += 1
            if self._calls % 1000 == 0:
                self._prune(now)

    def _prune(self, now: float) -> None:
        # Drop keys whose newest hit is older than any plausible window (1 day).
        for k in [k for k, v in self._hits.items() if not v or v[-1] < now - 86400]:
            del self._hits[k]

    def reset(self) -> None:
        self._hits.clear()


def client_ip(request: Request) -> str | None:
    """Left-most X-Forwarded-For when TRUST_PROXY=true (Render/Railway), else the peer."""
    raw: str | None = None
    if request.app.state.config.trust_proxy:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            raw = forwarded.split(",")[0].strip()
    if raw is None and request.client is not None:
        raw = request.client.host
    try:
        return str(ipaddress.ip_address(raw)) if raw else None
    except ValueError:
        return None


async def check_rate(request: Request, bucket: str, key: str, limit_key: str) -> None:
    store = request.app.state.settings_store
    limit = int(store.get_cached(limit_key))
    window = float(store.get_cached(f"{limit_key}_window_s"))
    await request.app.state.rate_limiter.hit(bucket, key, limit, window)


def rate_limit(bucket: str, *, per: Literal["ip", "user"], limit_key: str):
    """Dependency (for `dependencies=[...]`) limiting per client IP or per signed-in user."""
    if per == "ip":
        async def by_ip(request: Request) -> None:
            await check_rate(request, bucket, client_ip(request) or "unknown", limit_key)

        return Depends(by_ip)

    from app.deps import CurrentUser, get_current_user

    async def by_user(request: Request, user: CurrentUser = Depends(get_current_user)) -> None:
        await check_rate(request, bucket, str(user.id), limit_key)

    return Depends(by_user)
