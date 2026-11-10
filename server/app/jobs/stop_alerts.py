"""Stop alert (V1.3 decision 8): every `stop_alert_check_s`, look at each live bus and open, notify or close its
stationary episode (see app.modules.trips.stops). Detection uses the in-memory live state only; the DB is
touched for buses with a trip on the move or stopped."""

from __future__ import annotations

import logging
from typing import Any

from app import clock
from app.jobs import register_job
from app.live.conn import live_conn
from app.live.state import get_live
from app.modules.trips.stops import reconcile

log = logging.getLogger("ctms.jobs.stops")


async def stop_alert_tick(app: Any) -> int:
    """One pass; returns how many buses were examined."""
    now = clock.now()
    buses = list(get_live(app).buses.values())
    if not buses:
        return 0
    async with live_conn(app) as con:
        for bus in buses:
            try:
                await reconcile(app, con, bus, now)
            except Exception:
                log.exception("stop alert pass failed for trip %s", bus.trip_id)
    return len(buses)


register_job("stop_alerts", stop_alert_tick,
             interval_s=lambda app: float(app.state.settings_store.get_cached("stop_alert_check_s")))
