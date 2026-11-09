"""Fix/trip listener registry: the interface Phase 4 (alerts) codes against.

    from app.live.hooks import FixEvent, register_fix_listener

    async def on_fix(app, ev: FixEvent) -> None: ...
    register_fix_listener(on_fix)          # at import time, next to your router

`emit_fix` is called by tracking only for fixes that were ACCEPTED and became the
bus's LIVE position (never for out-of-order/old fixes). `emit_trip` fires on trip
start/end (driver or auto-close) and on status changes. One listener's exception
is logged and never breaks ingestion or the other listeners.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import UUID

log = logging.getLogger("ctms.live.hooks")


@dataclass(frozen=True)
class FixEvent:
    trip_id: UUID
    bus_id: UUID
    route_id: UUID
    bus_label: str
    route_name: str
    lat: float
    lng: float
    speed_mps: float | None
    heading: float | None
    recorded_at: datetime
    received_at: datetime
    trip_status: str  # on_time | delayed | breakdown
    direction: str = "to_campus"  # to_campus | from_campus


@dataclass(frozen=True)
class TripEvent:
    trip_id: UUID
    bus_id: UUID
    route_id: UUID
    kind: str  # 'started' | 'ended' | 'status'


FixListener = Callable[[Any, FixEvent], Awaitable[None]]
TripListener = Callable[[Any, TripEvent], Awaitable[None]]

_fix_listeners: list[FixListener] = []
_trip_listeners: list[TripListener] = []


def register_fix_listener(fn: FixListener) -> None:
    if fn not in _fix_listeners:
        _fix_listeners.append(fn)


def register_trip_listener(fn: TripListener) -> None:
    if fn not in _trip_listeners:
        _trip_listeners.append(fn)


async def emit_fix(app: Any, ev: FixEvent) -> None:
    for fn in list(_fix_listeners):
        try:
            await fn(app, ev)
        except Exception:
            log.exception("fix listener %s failed", getattr(fn, "__name__", fn))


async def emit_trip(app: Any, ev: TripEvent) -> None:
    for fn in list(_trip_listeners):
        try:
            await fn(app, ev)
        except Exception:
            log.exception("trip listener %s failed", getattr(fn, "__name__", fn))
