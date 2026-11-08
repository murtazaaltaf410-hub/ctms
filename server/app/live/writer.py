"""Bounded, batched DB writer for accepted fixes, rejections and trip progress.

Ingestion never waits for the DB: it calls `queue_location` / `queue_rejection` /
`queue_trip_progress` and returns. The `live_db_writer` job flushes every
`db_batch_interval_s` (TRD: 10 s) in one transaction; shutdown flushes once more.
If the DB is unreachable the batch is put back and live state keeps updating
(N5); any other DB error drops that batch (logged) so it cannot block the queue.
The queue is capped at `live_writer_queue_max`; beyond that the OLDEST rows are
dropped and counted in `dropped`.
"""

from __future__ import annotations

import logging
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import UUID

from app.errors import DB_CONNECTION_ERRORS, DbUnavailable
from app.jobs import register_job
from app.live import on_shutdown
from app.live.conn import live_conn

log = logging.getLogger("ctms.live.writer")


@dataclass(frozen=True)
class LocationRow:
    trip_id: UUID
    fix_id: UUID
    lat: float
    lng: float
    accuracy_m: float | None
    speed_mps: float | None
    heading: float | None
    recorded_at: datetime
    received_at: datetime


@dataclass(frozen=True)
class RejectedRow:
    trip_id: UUID
    fix_id: UUID | None
    reason: str
    received_at: datetime


class Writer:
    def __init__(self, max_rows: int) -> None:
        self.max_rows = max_rows
        self.rows: deque[LocationRow | RejectedRow] = deque()
        self.progress: dict[UUID, tuple[datetime, float]] = {}   # trip_id -> (last_fix_at, distance_m)
        self.dropped = 0
        self.last_error: str | None = None

    def _push(self, row: LocationRow | RejectedRow) -> None:
        self.rows.append(row)
        while len(self.rows) > self.max_rows:
            self.rows.popleft()
            self.dropped += 1

    def queue_location(self, row: LocationRow) -> None:
        self._push(row)

    def queue_rejection(self, row: RejectedRow) -> None:
        self._push(row)

    def queue_trip_progress(self, trip_id: UUID, last_fix_at: datetime, distance_m: float) -> None:
        prev = self.progress.get(trip_id)
        if prev is not None:
            last_fix_at = max(prev[0], last_fix_at)
            distance_m = max(prev[1], distance_m)
        self.progress[trip_id] = (last_fix_at, distance_m)

    def pending_fix_ids(self) -> set[UUID]:
        return {r.fix_id for r in self.rows if isinstance(r, LocationRow)}

    @property
    def pending(self) -> int:
        return len(self.rows) + len(self.progress)

    async def flush(self, app: Any) -> int:
        """Write everything queued; returns rows written (0 and re-queued on failure)."""
        if not self.rows and not self.progress:
            return 0
        rows, progress = list(self.rows), dict(self.progress)
        self.rows.clear()
        self.progress.clear()
        locs = [r for r in rows if isinstance(r, LocationRow)]
        rejs = [r for r in rows if isinstance(r, RejectedRow)]
        try:
            async with live_conn(app) as con, con.transaction():
                if locs:
                    await con.executemany(
                        """insert into public.locations
                             (trip_id, fix_id, lat, lng, accuracy_m, speed_mps, heading, recorded_at, received_at)
                           values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                           on conflict (fix_id) do nothing""",
                        [(r.trip_id, r.fix_id, r.lat, r.lng, r.accuracy_m, r.speed_mps, r.heading,
                          r.recorded_at, r.received_at) for r in locs],
                    )
                if rejs:
                    await con.executemany(
                        "insert into public.rejected_fixes (trip_id, fix_id, reason, received_at) "
                        "values ($1, $2, $3, $4)",
                        [(r.trip_id, r.fix_id, r.reason, r.received_at) for r in rejs],
                    )
                if progress:
                    await con.executemany(
                        """update public.trips
                              set last_fix_at = greatest(coalesce(last_fix_at, $2), $2),
                                  distance_m = greatest(distance_m, $3)
                            where id = $1 and ended_at is null""",
                        [(tid, at, dist) for tid, (at, dist) in progress.items()],
                    )
        except (DbUnavailable, *DB_CONNECTION_ERRORS) as exc:
            # Put the batch back in front of anything queued meanwhile (order kept).
            self.rows.extendleft(reversed(rows))
            while len(self.rows) > self.max_rows:
                self.rows.popleft()
                self.dropped += 1
            for tid, (at, dist) in progress.items():
                self.queue_trip_progress(tid, at, dist)
            self.last_error = f"{type(exc).__name__}: {exc}"
            log.warning("live writer flush failed, %d rows queued: %s", len(self.rows), self.last_error)
            return 0
        except Exception as exc:
            # Not an outage: a bad batch would fail forever, so drop it (logged, counted).
            self.dropped += len(rows)
            self.last_error = f"{type(exc).__name__}: {exc}"
            log.exception("live writer dropped a batch of %d rows", len(rows))
            return 0
        self.last_error = None
        return len(rows) + len(progress)


def get_writer(app: Any) -> Writer:
    writer = getattr(app.state, "live_writer", None)
    if writer is None:
        writer = app.state.live_writer = Writer(int(app.state.settings_store.get_cached("live_writer_queue_max")))
    return writer


async def writer_tick(app: Any) -> None:
    await get_writer(app).flush(app)


async def flush_on_shutdown(app: Any) -> None:
    writer = get_writer(app)
    written = await writer.flush(app)
    if writer.pending:
        log.error("shutdown: %d queued rows could not be written (%s)", writer.pending, writer.last_error)
    elif written:
        log.info("shutdown: flushed %d queued rows", written)


register_job("live_db_writer", writer_tick,
             interval_s=lambda app: float(app.state.settings_store.get_cached("db_batch_interval_s")))
on_shutdown(flush_on_shutdown)
