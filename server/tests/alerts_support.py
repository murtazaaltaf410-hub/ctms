"""Phase 4 test helpers (fixtures are imported explicitly by test_alerts*/test_push*/test_announcements*).

- `push` swaps in a FakeSender and points background work (push, alert engine) at the
  test connection.
- `world` creates a route + driver + bus + active trip; `student` creates a student with
  a push token, alert mode on and a fresh location.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from itertools import count
from uuid import UUID

import asyncpg
import pytest

from app import clock
from app.live.hooks import FixEvent
from app.modules.alerts.engine import AlertEngine, get_engine
from app.modules.alerts.geo import offset
from app.push import FakeSender, PushDispatcher, use_connection

BASE = (34.1310, 74.8370)  # University of Kashmir, North Campus (approx.)
_seq = count(1)


@dataclass(frozen=True)
class Trip:
    trip_id: UUID
    bus_id: UUID
    route_id: UUID
    bus_label: str
    route_name: str

    def fix(self, north_m: float, east_m: float = 0.0, *, at: datetime | None = None,
            status: str = "on_time", origin: tuple[float, float] = BASE) -> FixEvent:
        """A fix `north_m`/`east_m` metres from `origin` (the students' default spot)."""
        at = at or clock.now()
        lat, lng = offset(*origin, north_m=north_m, east_m=east_m)
        return FixEvent(trip_id=self.trip_id, bus_id=self.bus_id, route_id=self.route_id,
                        bus_label=self.bus_label, route_name=self.route_name, lat=lat, lng=lng,
                        speed_mps=8.0, heading=180.0, recorded_at=at, received_at=at, trip_status=status)


class FakeWs:
    def __init__(self) -> None:
        self.messages: list[dict] = []

    async def send_json(self, message: dict) -> None:
        self.messages.append(message)


@pytest.fixture
def push(app, con: asyncpg.Connection) -> FakeSender:
    sender = FakeSender()
    app.state.push = PushDispatcher(sender, maxsize=100)
    use_connection(app, con)
    return sender


@pytest.fixture
def engine(app, push) -> AlertEngine:
    return get_engine(app)


@pytest.fixture
def world(con: asyncpg.Connection, create_user: Callable, create_bus: Callable) -> Callable:
    async def make(label: str = "Bus 2", route_name: str = "North Campus") -> Trip:
        n = next(_seq)
        route_id = await con.fetchval("insert into public.routes (name) values ($1) returning id", route_name)
        driver_id = await create_user("driver", name=f"Driver {n}", phone=f"+9199000{n:05d}")
        bus_id = await create_bus(driver_id, label=label, plate=f"JK01P4{n:04d}")
        trip_id = await con.fetchval(
            """insert into public.trips (bus_id, driver_id, route_id, type) values ($1, $2, $3, 'ad_hoc')
               returning id""", bus_id, driver_id, route_id)
        return Trip(trip_id, bus_id, route_id, label, route_name)

    return make


@pytest.fixture
def student(con: asyncpg.Connection, create_user: Callable) -> Callable:
    async def make(*, north_m: float = 0.0, east_m: float = 0.0, accuracy: float = 20.0,
                   age_s: float = 10.0, enabled: bool = True, token: str | None = "auto") -> UUID:
        n = next(_seq)
        user_id = await create_user("student", name=f"Student {n}", email=f"p4-student{n}@uok.edu.in")
        if token:
            await con.execute("insert into public.push_tokens (user_id, token, platform) values ($1, $2, 'android')",
                              user_id, f"tok-{n}" if token == "auto" else token)
        await con.execute("insert into public.alert_settings (user_id, enabled) values ($1, $2)", user_id, enabled)
        await set_location(con, user_id, north_m=north_m, east_m=east_m, accuracy=accuracy, age_s=age_s)
        return user_id

    return make


async def set_location(con: asyncpg.Connection, user_id: UUID, *, north_m: float = 0.0, east_m: float = 0.0,
                       accuracy: float = 20.0, age_s: float = 10.0) -> None:
    lat, lng = offset(*BASE, north_m=north_m, east_m=east_m)
    await con.execute(
        """insert into public.student_locations (user_id, lat, lng, accuracy_m, recorded_at)
           values ($1, $2, $3, $4, $5)
           on conflict (user_id) do update set lat = excluded.lat, lng = excluded.lng,
             accuracy_m = excluded.accuracy_m, recorded_at = excluded.recorded_at""",
        user_id, lat, lng, accuracy, clock.now() - timedelta(seconds=age_s))


async def alert_count(con: asyncpg.Connection, student_id: UUID) -> int:
    return await con.fetchval("select count(*) from public.alert_log where student_id = $1", student_id)


async def admin_token(con: asyncpg.Connection, google_login: Callable, email: str = "p4-admin@uok.edu.in") -> str:
    await con.execute("insert into public.admin_allowlist (email) values ($1) on conflict do nothing", email)
    body = await google_login(sub=f"sub-{email}", email=email, name="Admin")
    assert body["user"]["role"] == "admin"
    return body["access_token"]
