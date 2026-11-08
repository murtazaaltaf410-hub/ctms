"""Acceptance helpers: play simulator fix streams through the real API on a fake clock.

`scripts.simulate` generates the fixes and upload batches (pure, no I/O). `SimPlayer`
posts each batch at its simulated send time: before every request the injected clock
(`app.clock`, P3) is moved to `trip start + send_t`, so server receive times, the
stale/offline thresholds and auto-close all follow simulated time without sleeping.
"""

from __future__ import annotations

import json
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any
from uuid import UUID

import asyncpg
import httpx

from app import clock
from app.geo import cumulative_distances
from app.geo.polyline import decode, encode
from app.live.ws import live_ws
from app.modules.alerts.engine import get_engine
from app.push import get_push
from scripts.simulate import Batch, DriveConfig, Dropout, Event, Route, SimFix, StatusChange, batches, drive, timeline
from tests.tracking_support import FakeWS, hub_clients, wait_until

# An L-shaped campus route: ~1.5 km north, then ~1.5 km east (one corner, so the
# simulator's odometer and the server's fix-to-fix distance differ a little, as on a road).
L_ROUTE = [(34.1200, 74.8300), (34.1268, 74.8300), (34.1335, 74.8300), (34.1335, 74.8382), (34.1335, 74.8463)]
L_STOPS_ALONG = [0.0, 750.0, 1500.0, 2250.0, None]   # None = the end of the route


@dataclass
class SimRoute:
    id: UUID
    name: str
    geom: Route               # built from the stored (rounded) polyline, i.e. what the server uses
    stops: list[UUID]
    stop_along: list[float]

    def stop_point(self, index: int) -> tuple[float, float]:
        lat, lng, _ = self.geom.at(self.stop_along[index])
        return lat, lng


async def insert_sim_route(con: asyncpg.Connection, points: Sequence[tuple[float, float]] = L_ROUTE,
                           stops_along: Sequence[float | None] = L_STOPS_ALONG, *, name: str = "Sim Route") -> SimRoute:
    poly = encode(list(points))
    decoded = decode(poly)
    cum = cumulative_distances(decoded)
    route_id = await con.fetchval(
        """insert into public.routes (name, polyline, cum_dist_m, length_m, status)
           values ($1, $2, $3, $4, 'active') returning id""",
        name, poly, cum, cum[-1],
    )
    geom = Route(decoded)
    stop_ids, alongs = [], []
    for seq, along in enumerate(stops_along, start=1):
        along = geom.length_m if along is None else along
        lat, lng, _ = geom.at(along)
        stop_ids.append(await con.fetchval(
            """insert into public.stops (route_id, name, lat, lng, sequence, dist_along_m)
               values ($1, $2, $3, $4, $5, $6) returning id""",
            route_id, f"Stop {seq}", lat, lng, seq, along,
        ))
        alongs.append(along)
    return SimRoute(route_id, name, geom, stop_ids, alongs)


def plan(route: Route, start: datetime, *, interval_s: float = 5.0, dropouts: Sequence[Dropout] = (),
         statuses: Sequence[StatusChange] = (), batch_max: int = 20,
         **drive_kw: Any) -> tuple[list[SimFix], list[Event]]:
    """Fixes for one drive and its upload timeline (batches + status changes)."""
    fixes = list(drive(route, DriveConfig(**drive_kw), start))
    events = timeline(batches(fixes, interval_s=interval_s, dropouts=dropouts, batch_max=batch_max), statuses)
    return fixes, events


@dataclass
class Upload:
    t: float
    batch: Batch
    status_code: int
    body: dict

    @property
    def accepted(self) -> set[str]:
        return set(self.body.get("accepted", []))

    @property
    def rejected(self) -> dict[str, str]:
        return {r["fix_id"]: r["reason"] for r in self.body.get("rejected", [])}


AfterUpload = Callable[[Upload], Awaitable[None]]


@dataclass
class SimPlayer:
    """Plays a timeline for one driver/trip. `start` is simulated t=0 (normally the trip start)."""

    client: httpx.AsyncClient
    fake_clock: clock.FakeClock
    headers: dict[str, str]
    trip_id: str
    start: datetime
    uploads: list[Upload] = field(default_factory=list)

    def at(self, t: float) -> datetime:
        return self.start + timedelta(seconds=t)

    def move_clock(self, t: float) -> None:
        target = self.at(t)
        if target > self.fake_clock.current:
            self.fake_clock.current = target

    async def play(self, events: Sequence[Event], after: AfterUpload | None = None, *,
                   until: float | None = None) -> list[Upload]:
        """Send every event (up to simulated time `until`); returns the uploads made."""
        made = []
        for ev in events:
            if until is not None and ev.t > until:
                break
            self.move_clock(ev.t)
            if isinstance(ev.item, StatusChange):
                resp = await self.client.post(f"/api/v1/trips/{self.trip_id}/status", headers=self.headers,
                                              json={"status": ev.item.status, "note": ev.item.note})
                assert resp.status_code == 204, resp.text
                continue
            resp = await self.client.post(f"/api/v1/trips/{self.trip_id}/locations", json=ev.item.payload,
                                          headers=self.headers)
            upload = Upload(ev.t, ev.item, resp.status_code, resp.json())
            made.append(upload)
            self.uploads.append(upload)
            if after is not None:
                await after(upload)
        return made

    async def end(self, t: float | None = None) -> dict:
        if t is not None:
            self.move_clock(t)
        resp = await self.client.post(f"/api/v1/trips/{self.trip_id}/end", headers=self.headers)
        assert resp.status_code == 200, resp.text
        return resp.json()


def assert_server_verdicts(uploads: Sequence[Upload]) -> None:
    """Every fix got exactly the verdict the simulator predicts (accepted, or its reason)."""
    for up in uploads:
        assert up.status_code == 200, up.body
        assert len(up.body["accepted"]) + len(up.body["rejected"]) == len(up.batch.fixes)
        for f in up.batch.fixes:
            fid = str(f.fix_id)
            if f.expected is None:
                assert fid in up.accepted, (f, up.body)
            else:   # a duplicate shares its original's fix_id; only the copy is rejected
                assert up.rejected.get(fid) == f.expected, (f, up.body)


async def live_buses(client: httpx.AsyncClient, headers: dict[str, str]) -> list[dict]:
    resp = await client.get("/api/v1/buses/live", headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


async def live_bus(client: httpx.AsyncClient, headers: dict[str, str], bus_id: str) -> dict | None:
    return next((b for b in await live_buses(client, headers) if b["bus_id"] == bus_id), None)


async def stop_eta(client: httpx.AsyncClient, headers: dict[str, str], stop_id: UUID) -> dict:
    resp = await client.get(f"/api/v1/stops/{stop_id}/eta", headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


@dataclass
class Student:
    id: UUID
    headers: dict[str, str]
    push_token: str


async def alert_student(client: httpx.AsyncClient, google_login: Callable, n: int, lat: float, lng: float, *,
                        accuracy: float = 15.0, enabled: bool = True) -> Student:
    """A student signed in with Google, push token registered, alert mode on, standing at (lat, lng)."""
    tokens = await google_login(sub=f"acc-student-{n}", email=f"acc.student{n}@uok.edu.in", name=f"Student {n}")
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    push_token = f"fcm-acc-{n}"
    resp = await client.put("/api/v1/me/push-token", json={"token": push_token, "platform": "android"},
                            headers=headers)
    assert resp.status_code == 204, resp.text
    if enabled:
        resp = await client.put("/api/v1/me/alert-settings", json={"enabled": True}, headers=headers)
        assert resp.status_code == 200 and resp.json()["enabled"] is True, resp.text
        await report_location(client, headers, lat, lng, accuracy=accuracy)
    return Student(UUID(tokens["user"]["id"]), headers, push_token)


async def report_location(client: httpx.AsyncClient, headers: dict[str, str], lat: float, lng: float, *,
                          accuracy: float = 15.0) -> None:
    """POST /me/location. Student fixes are judged against the real wall clock (the alert engine
    and this endpoint use `utcnow`, not the injectable clock), so they are stamped with real time."""
    from app.schemas import iso_utc, utcnow

    resp = await client.post("/api/v1/me/location", headers=headers,
                             json={"lat": lat, "lng": lng, "accuracy": accuracy, "recorded_at": iso_utc(utcnow())})
    assert resp.status_code == 204, resp.text


async def drain_alerts(app: Any) -> None:
    """Run the queued alert evaluations and push deliveries (no background tasks in tests)."""
    await get_engine(app).drain(app)
    await get_push(app).drain(app)


async def ws_connect(app: Any, token: str) -> tuple[FakeWS, Any]:
    """An authenticated live socket (in-process double of the real WebSocket)."""
    import asyncio

    before = hub_clients(app)
    ws = FakeWS(app)
    task = asyncio.create_task(live_ws(ws))
    ws.say(json.dumps({"type": "auth", "token": token}))
    await wait_until(lambda: hub_clients(app) > before or ws.closed is not None)
    assert ws.closed is None, ws.closed
    return ws, task


def within(actual: float, expected: float, pct: float) -> bool:
    return abs(actual - expected) <= abs(expected) * pct / 100.0
