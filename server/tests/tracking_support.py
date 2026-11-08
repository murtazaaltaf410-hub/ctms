"""Phase 3 test helpers (fixtures are imported explicitly by the test modules).

- `live_app`: the conftest `app`, with the live writer/jobs/WS pointed at the
  per-test connection (`app.state.live_conn_provider`).
- `fake_clock`: freezes `app.clock.now()`; `.advance(s)` moves it.
- `make_route`, `driver_with_bus`, `start_trip`, `fixes`, `post_fixes`: data builders.
- `FakeWS`: an in-process WebSocket double for driving `app.live.ws.live_ws`.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import asyncpg
import pytest
from fastapi import WebSocketDisconnect

from app import clock
from app.geo import cumulative_distances
from app.geo.polyline import decode, encode
from app.live import hooks
from app.live.hub import get_hub
from tests.conftest import bearer

# A straight route due north from campus: 11 points ~111 m apart (~1.11 km).
ORIGIN = (34.1200, 74.8300)
STEP_DEG = 0.001


def route_points(n: int = 11) -> list[tuple[float, float]]:
    return [(round(ORIGIN[0] + i * STEP_DEG, 5), ORIGIN[1]) for i in range(n)]


def point_at(along_m: float) -> tuple[float, float]:
    """Position on the test route `along_m` metres from its start (straight line)."""
    return ORIGIN[0] + along_m / 111_195.0, ORIGIN[1]


@pytest.fixture
def live_app(app, con: asyncpg.Connection):
    @asynccontextmanager
    async def provider():
        yield con

    app.state.live_conn_provider = provider
    return app


@pytest.fixture
def fake_clock(monkeypatch) -> clock.FakeClock:
    fake = clock.FakeClock(datetime.now(UTC).replace(microsecond=0))
    monkeypatch.setattr(clock, "_source", fake)
    return fake


@pytest.fixture
def hook_log(monkeypatch) -> dict[str, list]:
    """Captures FixEvent/TripEvent emissions (isolated from other phases' listeners)."""
    seen: dict[str, list] = {"fix": [], "trip": []}
    monkeypatch.setattr(hooks, "_fix_listeners", [])
    monkeypatch.setattr(hooks, "_trip_listeners", [])

    async def on_fix(app, ev):
        seen["fix"].append(ev)

    async def on_trip(app, ev):
        seen["trip"].append(ev)

    hooks.register_fix_listener(on_fix)
    hooks.register_trip_listener(on_trip)
    return seen


@pytest.fixture
def make_route(con: asyncpg.Connection) -> Callable:
    async def make(name: str = "Test Route", n_points: int = 11, stops: list[float] | None = None) -> dict:
        points = route_points(n_points)
        poly = encode(points)
        cum = cumulative_distances(decode(poly))
        route_id = await con.fetchval(
            """insert into public.routes (name, polyline, cum_dist_m, length_m, status)
               values ($1, $2, $3, $4, 'active') returning id""",
            name,
            poly,
            cum,
            cum[-1],
        )
        stop_ids = []
        for seq, along in enumerate(stops or [0.0, 555.0, cum[-1]], start=1):
            lat, lng = point_at(along)
            stop_ids.append(
                await con.fetchval(
                    """insert into public.stops (route_id, name, lat, lng, sequence, dist_along_m)
                   values ($1, $2, $3, $4, $5, $6) returning id""",
                    route_id,
                    f"Stop {seq}",
                    lat,
                    lng,
                    seq,
                    along,
                )
            )
        return {"id": route_id, "stops": stop_ids, "cum": cum, "name": name}

    return make


@pytest.fixture
def driver_with_bus(con, create_user, driver_login, make_route) -> Callable:
    """Driver + linked bus with a default route; returns ids and the driver's access token."""
    counter = {"n": 0}

    async def make(*, route: dict | None = None, label: str | None = None) -> dict:
        counter["n"] += 1
        n = counter["n"]
        route = route or await make_route()
        phone = f"+9199{n:08d}"
        driver_id = await create_user("driver", name=f"Driver {n}", phone=phone)
        bus_id = await con.fetchval(
            "insert into public.buses (label, plate, driver_id, default_route_id) values ($1, $2, $3, $4) returning id",
            label or f"Bus {n}",
            f"JK01P3{n:04d}",
            driver_id,
            route["id"],
        )
        tokens = await driver_login(phone)
        return {
            "driver_id": driver_id,
            "bus_id": bus_id,
            "route": route,
            "phone": phone,
            "token": tokens["access_token"],
            "headers": bearer(tokens["access_token"]),
        }

    return make


@pytest.fixture
def start_trip(client) -> Callable:
    async def start(driver: dict, body: dict | None = None) -> dict:
        resp = await client.post("/api/v1/trips/start", json=body or {}, headers=driver["headers"])
        assert resp.status_code == 201, resp.text
        return resp.json()

    return start


def fix(
    lat: float,
    lng: float,
    at: datetime,
    *,
    accuracy: float = 8.0,
    speed: float | None = None,
    heading: float | None = 0.0,
    fix_id: UUID | None = None,
) -> dict:
    out = {
        "fix_id": str(fix_id or uuid4()),
        "lat": lat,
        "lng": lng,
        "accuracy": accuracy,
        "heading": heading,
        "recorded_at": at.astimezone(UTC).isoformat().replace("+00:00", "Z"),
    }
    if speed is not None:
        out["speed"] = speed
    return out


def along_fix(along_m: float, at: datetime, **kw) -> dict:
    lat, lng = point_at(along_m)
    return fix(lat, lng, at, **kw)


@pytest.fixture
def post_fixes(client) -> Callable:
    async def post(driver: dict, trip_id: str, fixes: list[dict], expect: int = 200) -> dict:
        resp = await client.post(f"/api/v1/trips/{trip_id}/locations", json={"fixes": fixes}, headers=driver["headers"])
        assert resp.status_code == expect, resp.text
        return resp.json()

    return post


def seconds(n: float) -> timedelta:
    return timedelta(seconds=n)


_DISCONNECT = object()


class FakeWS:
    """Minimal stand-in for starlette's WebSocket as used by `live_ws`."""

    def __init__(self, app) -> None:
        self.app = app
        self.inbox: asyncio.Queue = asyncio.Queue()
        self.sent: list[dict] = []
        self.closed: tuple[int, str | None] | None = None
        self.accepted = False

    async def accept(self) -> None:
        self.accepted = True

    async def receive_text(self) -> str:
        item = await self.inbox.get()
        if item is _DISCONNECT:
            raise WebSocketDisconnect(1000)
        return item

    async def send_json(self, message: dict) -> None:
        if self.closed:
            raise RuntimeError("closed")
        self.sent.append(message)

    async def close(self, code: int = 1000, reason: str | None = None) -> None:
        self.closed = (code, reason)
        self.inbox.put_nowait(_DISCONNECT)

    def say(self, text: str) -> None:
        self.inbox.put_nowait(text)

    def hang_up(self) -> None:
        self.inbox.put_nowait(_DISCONNECT)


async def wait_until(predicate: Callable[[], bool], timeout: float = 2.0) -> None:
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        if asyncio.get_running_loop().time() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.01)


def hub_clients(app) -> int:
    return len(get_hub(app).clients)
