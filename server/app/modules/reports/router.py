"""Trip history and reports (PRD A6, TC18, launch gate LG4). Admin only (runbook: history is admin-only).

GET /admin/trips?from&to&bus_id&cursor     trips, newest first: driver, times, distance_m, avg_speed, closed_by
GET /admin/trips/{id}/path                 ordered positions for replay
GET /admin/reports/summary?from&to         per-bus totals: trips, distance_m, running_time_s
GET /admin/reports/trips.csv?from&to&bus_id   extension: CSV export of the trip list (LG4)

`from`/`to` filter on `started_at` (from inclusive, to exclusive), UTC. `distance_m` is the trip's
stored distance (maintained by tracking); running time is ended_at (or the last fix of an active
trip) minus started_at; `avg_speed` is distance / running time in m/s.
"""

from __future__ import annotations

import csv
import io
from datetime import UTC, datetime
from typing import Annotated, Literal
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Query, Request
from fastapi.responses import Response
from pydantic import Field

from app.db import Conn
from app.errors import NotFound, ValidationFailed
from app.modules.admin.common import AdminUser, Cursor, Limit, decode_cursor, page_limit, paginate
from app.schemas import ApiModel, UtcDateTime, iso_utc

router = APIRouter(tags=["admin: reports"])

From = Annotated[datetime | None, Query(alias="from", description="UTC ISO-8601, inclusive")]
To = Annotated[datetime | None, Query(description="UTC ISO-8601, exclusive")]
BusFilter = Annotated[UUID | None, Query()]


class TripReportOut(ApiModel):
    id: UUID
    bus_id: UUID
    bus_label: str
    driver_id: UUID
    driver_name: str
    route_id: UUID
    route_name: str
    type: Literal["scheduled", "ad_hoc"]
    status: Literal["on_time", "delayed", "breakdown"]
    started_at: UtcDateTime
    ended_at: UtcDateTime | None
    closed_by: Literal["driver", "auto"] | None
    distance_m: float
    duration_s: float
    avg_speed: float | None


class TripReportPage(ApiModel):
    items: list[TripReportOut]
    next_cursor: str | None


class PositionOut(ApiModel):
    lat: float
    lng: float
    recorded_at: UtcDateTime
    speed: float | None
    heading: float | None
    accuracy: float | None


class TripPathOut(ApiModel):
    trip_id: UUID
    positions: list[PositionOut]


class BusTotalsOut(ApiModel):
    bus_id: UUID
    label: str
    trips: int
    distance_m: float
    running_time_s: float


class TotalsOut(ApiModel):
    trips: int
    distance_m: float
    running_time_s: float


class SummaryOut(ApiModel):
    from_: UtcDateTime | None = Field(serialization_alias="from")
    to: UtcDateTime | None
    buses: list[BusTotalsOut]
    totals: TotalsOut


def _utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _range(start: datetime | None, end: datetime | None) -> tuple[datetime | None, datetime | None]:
    start, end = _utc(start), _utc(end)
    if start and end and start >= end:
        raise ValidationFailed("from: must be before to")
    return start, end


_DURATION = "extract(epoch from (coalesce(t.ended_at, t.last_fix_at, t.started_at) - t.started_at))::float8"

_TRIPS_SQL = f"""
    select t.id, t.bus_id, b.label as bus_label, t.driver_id, d.name as driver_name, t.route_id,
           r.name as route_name, t.type, t.status, t.started_at, t.ended_at, t.closed_by, t.distance_m,
           {_DURATION} as duration_s
    from public.trips t
    join public.buses b on b.id = t.bus_id
    join public.users d on d.id = t.driver_id
    join public.routes r on r.id = t.route_id
    where ($1::timestamptz is null or t.started_at >= $1)
      and ($2::timestamptz is null or t.started_at < $2)
      and ($3::uuid is null or t.bus_id = $3)
      and ($4::timestamptz is null or (t.started_at, t.id) < ($4, $5))
    order by t.started_at desc, t.id desc
    limit $6"""  # noqa: S608 (constant SQL)


def _trip_out(row: asyncpg.Record) -> TripReportOut:
    duration = max(0.0, row["duration_s"] or 0.0)
    avg = round(row["distance_m"] / duration, 2) if duration > 0 else None
    return TripReportOut(**{**dict(row), "duration_s": round(duration, 1)}, avg_speed=avg)


async def fetch_trips(con: asyncpg.Connection, start: datetime | None, end: datetime | None, bus_id: UUID | None,
                      after: tuple[datetime, UUID] | None, limit: int) -> list[asyncpg.Record]:
    return await con.fetch(_TRIPS_SQL, start, end, bus_id, after[0] if after else None,
                           after[1] if after else None, limit)


@router.get("/admin/trips", response_model=TripReportPage)
async def list_trips(request: Request, user: AdminUser, con: Conn, from_: From = None, to: To = None,
                     bus_id: BusFilter = None, cursor: Cursor = None, limit: Limit = None) -> TripReportPage:
    start, end = _range(from_, to)
    n = page_limit(request, limit)
    rows = await fetch_trips(con, start, end, bus_id, decode_cursor(cursor), n + 1)
    page, next_cursor = paginate(rows, n, "started_at")
    return TripReportPage(items=[_trip_out(r) for r in page], next_cursor=next_cursor)


@router.get("/admin/trips/{trip_id}/path", response_model=TripPathOut)
async def trip_path(trip_id: UUID, user: AdminUser, con: Conn) -> TripPathOut:
    if not await con.fetchval("select exists(select 1 from public.trips where id = $1)", trip_id):
        raise NotFound("Trip not found")
    rows = await con.fetch(
        """select lat, lng, recorded_at, speed_mps as speed, heading, accuracy_m as accuracy
           from public.locations where trip_id = $1 order by recorded_at, id""",
        trip_id,
    )
    return TripPathOut(trip_id=trip_id, positions=[PositionOut(**dict(r)) for r in rows])


@router.get("/admin/reports/summary", response_model=SummaryOut)
async def summary(user: AdminUser, con: Conn, from_: From = None, to: To = None) -> SummaryOut:
    start, end = _range(from_, to)
    rows = await con.fetch(
        f"""select b.id as bus_id, b.label, count(*)::int as trips,
                   coalesce(sum(t.distance_m), 0)::float8 as distance_m,
                   coalesce(sum({_DURATION}), 0)::float8 as running_time_s
            from public.trips t join public.buses b on b.id = t.bus_id
            where ($1::timestamptz is null or t.started_at >= $1) and ($2::timestamptz is null or t.started_at < $2)
            group by b.id, b.label order by b.label, b.id""",  # noqa: S608 (constant SQL)
        start, end,
    )
    buses = [BusTotalsOut(**{**dict(r), "distance_m": round(r["distance_m"], 1),
                             "running_time_s": round(r["running_time_s"], 1)}) for r in rows]
    totals = TotalsOut(trips=sum(b.trips for b in buses), distance_m=round(sum(b.distance_m for b in buses), 1),
                       running_time_s=round(sum(b.running_time_s for b in buses), 1))
    return SummaryOut(from_=start, to=end, buses=buses, totals=totals)


CSV_COLUMNS = ["trip_id", "started_at", "ended_at", "bus_label", "driver_name", "route_name", "type", "status",
               "closed_by", "distance_m", "duration_s", "avg_speed_mps", "avg_speed_kmh"]


def _cell(value: object) -> object:
    """Neutralise spreadsheet formulas in admin-entered text (CSV injection)."""
    if isinstance(value, str) and value[:1] in ("=", "+", "-", "@", "\t", "\r"):
        return "'" + value
    return value


@router.get("/admin/reports/trips.csv", response_class=Response,
            summary="Trip report as CSV (extension, not in the API spec; launch gate LG4)",
            responses={200: {"content": {"text/csv": {}}}})
async def trips_csv(request: Request, user: AdminUser, con: Conn, from_: From = None, to: To = None,
                    bus_id: BusFilter = None) -> Response:
    start, end = _range(from_, to)
    max_rows = request.app.state.config.report_csv_max_rows
    rows = await fetch_trips(con, start, end, bus_id, None, max_rows)
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\r\n")
    writer.writerow(CSV_COLUMNS)
    for row in rows:
        trip = _trip_out(row)
        writer.writerow([_cell(v) for v in (
            trip.id, iso_utc(trip.started_at), iso_utc(trip.ended_at) if trip.ended_at else "", trip.bus_label,
            trip.driver_name, trip.route_name, trip.type, trip.status, trip.closed_by or "",
            round(trip.distance_m, 1), trip.duration_s, "" if trip.avg_speed is None else trip.avg_speed,
            "" if trip.avg_speed is None else round(trip.avg_speed * 3.6, 1),
        )])
    return Response(buf.getvalue(), media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": 'attachment; filename="ctms-trips.csv"',
                             "Cache-Control": "no-store"})
