"""Retention (TRD p.5, runbook): bus locations and rejected fixes older than
`location_retention_days` (90), student locations older than
`student_location_ttl_s` (5 min), expired sessions. Runs every `retention_interval_s`."""

from __future__ import annotations

import logging
from datetime import timedelta
from typing import Any

from app import clock
from app.jobs import register_job
from app.live.conn import live_conn

log = logging.getLogger("ctms.jobs.retention")

PURGES = (
    ("locations", "delete from public.locations where recorded_at < $1", "history"),
    ("rejected_fixes", "delete from public.rejected_fixes where received_at < $1", "history"),
    ("student_locations", "delete from public.student_locations where recorded_at < $1", "student"),
    ("sessions", "delete from public.sessions where expires_at < $1", "now"),
    # ADR-9: finished pickup requests (picked up / cancelled / expired) are not kept.
    ("pickup_requests", "delete from public.pickup_requests where status <> 'waiting' and updated_at < $1", "pickup"),
)


async def retention_tick(app: Any) -> dict[str, int]:
    store = app.state.settings_store
    now = clock.now()
    cutoffs = {
        "history": now - timedelta(days=int(store.get_cached("location_retention_days"))),
        "student": now - timedelta(seconds=int(store.get_cached("student_location_ttl_s"))),
        "pickup": now - timedelta(seconds=int(store.get_cached("pickup_retention_s"))),
        "now": now,
    }
    counts: dict[str, int] = {}
    async with live_conn(app) as con:
        # A waiting pin past its expiry is no longer shown to drivers; record that.
        await con.execute(
            "update public.pickup_requests set status = 'expired' where status = 'waiting' and expires_at < $1", now)
        for name, sql, cutoff in PURGES:
            status = await con.execute(sql, cutoffs[cutoff])   # "DELETE <n>"
            counts[name] = int(status.rsplit(" ", 1)[-1])
    if any(counts.values()):
        log.info("retention purge: %s", counts)
    return counts


register_job("retention", retention_tick,
             interval_s=lambda app: float(app.state.settings_store.get_cached("retention_interval_s")))
