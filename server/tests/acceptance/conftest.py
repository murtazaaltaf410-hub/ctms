"""Acceptance suite (Phase 6): TC1–TC20 at the server level, driven by the GPS simulator.

Reuses the P2–P5 fixtures: conftest (client, con, app, google_login, driver_login, ...),
tracking_support (live_app, fake_clock, driver_with_bus, start_trip, ...), alerts_support
(push, engine, student) and admin_helpers (admin, fake_routes). They are imported here so
every module in this package gets them.
"""

from __future__ import annotations

from collections.abc import Callable

import asyncpg
import pytest

from tests.acceptance.sim_support import SimPlayer, SimRoute, insert_sim_route
from tests.admin_helpers import admin, fake_routes  # noqa: F401
from tests.alerts_support import engine, push, student  # noqa: F401
from tests.tracking_support import (  # noqa: F401
    driver_with_bus,
    fake_clock,
    hook_log,
    live_app,
    make_route,
    post_fixes,
    start_trip,
)


@pytest.fixture
def config_overrides() -> dict:
    """Simulated drives post far faster than real time; lift the per-minute limits
    (N7's own module puts them back)."""
    return {"rate_locations_per_user": 100_000, "rate_general_per_user": 100_000, "rate_general_per_ip": 100_000}


@pytest.fixture
def sim_route(con: asyncpg.Connection) -> Callable:
    async def make(*args, **kwargs) -> SimRoute:
        return await insert_sim_route(con, *args, **kwargs)

    return make


@pytest.fixture
def sim_trip(client, live_app, fake_clock, sim_route, driver_with_bus, start_trip) -> Callable:  # noqa: F811
    """`await sim_trip()` -> (route, driver, trip, player): a driver on an L-shaped route with a started trip."""

    async def make(*, route: SimRoute | None = None, label: str | None = None):
        route = route or await sim_route()
        driver = await driver_with_bus(route={"id": route.id}, label=label)
        trip = await start_trip(driver)
        player = SimPlayer(client, fake_clock, driver["headers"], trip["id"], fake_clock.current)
        return route, driver, trip, player

    return make
