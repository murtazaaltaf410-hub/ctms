"""P5 test helpers: an admin login, a fake Routes API provider and direct inserts for trips/locations.

Import the fixtures into a test module (`from tests.admin_helpers import admin, fake_routes  # noqa: F401`).
Trips and locations are inserted directly so these tests do not depend on the tracking endpoints.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from datetime import datetime, timedelta
from uuid import UUID, uuid4

import asyncpg
import pytest

from app.integrations.routes_api import FakeRouteProvider
from app.modules.routes.geo import cumulative_distances, encode_polyline
from tests.conftest import adopt_unrouted_students, bearer

# Points along a road on North Campus (illustrative).
CAMPUS = [(34.12600, 74.83500), (34.12780, 74.83680), (34.12950, 74.83820), (34.13150, 74.83990)]


def err(resp) -> str:
    return resp.json()["error"]["code"]


@pytest.fixture
def fake_routes(app) -> FakeRouteProvider:
    provider = FakeRouteProvider()
    app.state.route_provider = provider
    return provider


@pytest.fixture
def admin(con: asyncpg.Connection, google_login) -> Callable:
    """`await admin(n)` -> (user_id, headers) for an allow-listed admin signed in with Google."""

    async def login(n: int = 1) -> tuple[UUID, dict[str, str]]:
        email = f"admin{n}@uok.edu.in"
        await con.execute("insert into public.admin_allowlist (email) values ($1) on conflict do nothing", email)
        tokens = await google_login(f"admin-sub-{n}", email, f"Admin {n}")
        assert tokens["user"]["role"] == "admin"
        return UUID(tokens["user"]["id"]), bearer(tokens["access_token"])

    return login


async def insert_route(
    con: asyncpg.Connection, points: Sequence[tuple[float, float]] = CAMPUS, *, name: str = "Route T"
) -> UUID:
    """An active route whose stops are `points` (polyline = straight lines between them)."""
    cum = cumulative_distances(points)
    route_id = await con.fetchval(
        """insert into public.routes (name, polyline, cum_dist_m, length_m, status)
           values ($1, $2, $3, $4, 'active') returning id""",
        name,
        encode_polyline(points),
        cum,
        cum[-1],
    )
    await adopt_unrouted_students(con, route_id)
    for seq, ((lat, lng), dist) in enumerate(zip(points, cum, strict=True), start=1):
        await con.execute(
            """insert into public.stops (route_id, name, lat, lng, sequence, dist_along_m)
               values ($1, $2, $3, $4, $5, $6)""",
            route_id,
            f"Stop {seq}",
            lat,
            lng,
            seq,
            dist,
        )
    return route_id


async def insert_trip(
    con: asyncpg.Connection,
    *,
    bus_id: UUID,
    driver_id: UUID,
    route_id: UUID,
    started_at: datetime,
    ended_at: datetime | None = None,
    closed_by: str | None = None,
    distance_m: float = 0,
    last_fix_at: datetime | None = None,
) -> UUID:
    if ended_at is not None and closed_by is None:
        closed_by = "driver"
    return await con.fetchval(
        """insert into public.trips (bus_id, driver_id, route_id, type, started_at, ended_at, closed_by,
                                     distance_m, last_fix_at)
           values ($1, $2, $3, 'ad_hoc', $4, $5, $6, $7, $8) returning id""",
        bus_id,
        driver_id,
        route_id,
        started_at,
        ended_at,
        closed_by,
        distance_m,
        last_fix_at,
    )


async def insert_path(
    con: asyncpg.Connection, trip_id: UUID, points: Sequence[tuple[float, float]], start: datetime, step_s: float = 5
) -> list[datetime]:
    times = []
    for i, (lat, lng) in enumerate(points):
        at = start + timedelta(seconds=i * step_s)
        times.append(at)
        await con.execute(
            """insert into public.locations (trip_id, fix_id, lat, lng, accuracy_m, speed_mps, heading, recorded_at)
               values ($1, $2, $3, $4, 8, 6, 45, $5)""",
            trip_id,
            uuid4(),
            lat,
            lng,
            at,
        )
    return times
