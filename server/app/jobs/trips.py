"""Trip auto-close (T2): an active trip with no fix for `trip_auto_close_s` (15 min)
is closed with `closed_by='auto'`, ended at its last fix (or start), and
`trip_ended` is broadcast. Checked every `trip_auto_close_check_s`."""

from __future__ import annotations

import logging
from datetime import timedelta
from typing import Any

from app import clock
from app.jobs import register_job
from app.live.conn import live_conn
from app.live.state import get_live
from app.modules.trips.service import end_trip

log = logging.getLogger("ctms.jobs.trips")


async def auto_close_tick(app: Any) -> int:
    limit = timedelta(seconds=float(app.state.settings_store.get_cached("trip_auto_close_s")))
    now = clock.now()
    live = get_live(app)
    closed = 0
    async with live_conn(app) as con:
        rows = await con.fetch("select id, started_at, last_fix_at from public.trips where ended_at is null")
        for row in rows:
            bus = live.by_trip(row["id"])
            seen = [t for t in (row["last_fix_at"], bus.received_at if bus else None) if t is not None]
            last = max(seen) if seen else row["started_at"]
            if now - last < limit:
                continue
            await end_trip(app, con, row["id"], closed_by="auto", ended_at=last, actor_id=None)
            closed += 1
            log.info("auto-closed trip %s (no fix since %s)", row["id"], last.isoformat())
    return closed


register_job("trip_auto_close", auto_close_tick,
             interval_s=lambda app: float(app.state.settings_store.get_cached("trip_auto_close_check_s")))
