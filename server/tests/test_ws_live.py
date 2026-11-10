"""WS /api/v1/ws/live: auth within the timeout, ping/pong, broadcasts, revocation close."""

from __future__ import annotations

import asyncio
import json
from datetime import timedelta

import pytest
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.live.ws import live_ws
from app.main import create_app
from tests.conftest import make_config
from tests.tracking_support import FakeWS, along_fix, hub_clients, wait_until

pytest_plugins = ["tests.tracking_support"]


async def set_setting(app, con, key: str, value: str) -> None:
    await con.execute("update public.settings set value = $2::jsonb where key = $1", key, value)
    await app.state.settings_store.refresh(con)


async def connect(app, token: str) -> tuple[FakeWS, asyncio.Task]:
    ws = FakeWS(app)
    task = asyncio.create_task(live_ws(ws))
    ws.say(json.dumps({"type": "auth", "token": token}))
    await wait_until(lambda: hub_clients(app) == 1 or ws.closed is not None)
    return ws, task


async def test_auth_timeout_closes_socket(con, live_app):
    await set_setting(live_app, con, "ws_auth_timeout_s", "0.05")
    ws = FakeWS(live_app)
    await asyncio.wait_for(live_ws(ws), timeout=2)
    assert ws.accepted and ws.closed == (4401, "AUTH_TIMEOUT")
    assert hub_clients(live_app) == 0


@pytest.mark.parametrize(
    ("first", "reason"),
    [
        ('{"type": "ping"}', "AUTH_REQUIRED"),
        ("not json", "AUTH_REQUIRED"),
        ('{"type": "auth", "token": "garbage"}', "TOKEN_INVALID"),
    ],
)
async def test_bad_first_message_closes(live_app, first, reason):
    ws = FakeWS(live_app)
    ws.say(first)
    await asyncio.wait_for(live_ws(ws), timeout=2)
    assert ws.closed == (4401, reason)


async def test_ping_pong_and_broadcasts(
    client, live_app, google_login, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()  # first: the route exists before the student is registered on it
    student = await google_login()
    ws, task = await connect(live_app, student["access_token"])
    assert ws.closed is None and hub_clients(live_app) == 1
    ws.say('{"type": "ping"}')
    await wait_until(lambda: {"type": "pong"} in ws.sent)
    trip = await start_trip(driver)
    await post_fixes(driver, trip["id"], [along_fix(0, fake_clock.current, speed=6.0)])
    await client.post(
        f"/api/v1/trips/{trip['id']}/status",
        json={"status": "breakdown", "note": "Flat tyre"},
        headers=driver["headers"],
    )
    await client.post(f"/api/v1/trips/{trip['id']}/end", headers=driver["headers"])
    types = [m["type"] for m in ws.sent]
    assert types == ["pong", "trip_started", "bus_position", "bus_status", "trip_ended"]
    position = ws.sent[2]
    assert set(position) == {"type", "bus_id", "trip_id", "lat", "lng", "heading", "speed", "recorded_at"}
    assert ws.sent[3] == {"type": "bus_status", "bus_id": trip["bus_id"], "trip_id": trip["id"],
                          "status": "breakdown", "note": "Flat tyre"}
    ws.hang_up()
    await asyncio.wait_for(task, timeout=2)
    assert hub_clients(live_app) == 0


async def test_revoked_session_socket_is_closed(live_app, driver_with_bus, driver_login):
    driver = await driver_with_bus()
    ws, task = await connect(live_app, driver["token"])
    assert hub_clients(live_app) == 1
    await driver_login(driver["phone"])  # T11: second device replaces the first session
    await asyncio.wait_for(task, timeout=2)
    assert ws.closed == (4401, "SESSION_REPLACED")
    assert hub_clients(live_app) == 0
    # The old token can no longer open a socket either.
    again = FakeWS(live_app)
    again.say(json.dumps({"type": "auth", "token": driver["token"]}))
    await asyncio.wait_for(live_ws(again), timeout=2)
    assert again.closed == (4401, "SESSION_REPLACED")


async def test_logout_closes_socket(client, live_app, google_login):
    student = await google_login()
    ws, task = await connect(live_app, student["access_token"])
    resp = await client.post(
        "/api/v1/auth/logout",
        json={"refresh_token": student["refresh_token"]},
        headers={"Authorization": f"Bearer {student['access_token']}"},
    )
    assert resp.status_code == 204, resp.text
    await asyncio.wait_for(task, timeout=2)
    assert ws.closed is not None and ws.closed[0] == 4401


async def test_idle_client_dropped(con, live_app, google_login):
    student = await google_login()
    live_app.state.config.ws_idle_timeout_s = 0.05  # config-only key (not in the settings table)
    ws, task = await connect(live_app, student["access_token"])
    await asyncio.wait_for(task, timeout=2)
    assert ws.closed == (1001, "IDLE_TIMEOUT") and hub_clients(live_app) == 0


def test_route_is_mounted_and_rejects_bad_token():
    """Real ASGI WebSocket through Starlette's TestClient (no DB needed for a bad token)."""
    app = create_app(make_config())
    with TestClient(app).websocket_connect("/api/v1/ws/live") as ws:
        ws.send_text(json.dumps({"type": "auth", "token": "garbage"}))
        with pytest.raises(WebSocketDisconnect) as info:
            ws.receive_text()
    assert info.value.code == 4401 and info.value.reason == "TOKEN_INVALID"


async def test_expired_token_rejected(live_app, fake_clock):
    from uuid import uuid4

    from app.security import create_access_token

    token = create_access_token(
        user_id=uuid4(),
        session_id=uuid4(),
        role="student",
        secret=live_app.state.config.jwt_secret,
        ttl_s=1,
        now=fake_clock.current - timedelta(hours=1),
    )
    ws = FakeWS(live_app)
    ws.say(json.dumps({"type": "auth", "token": token}))
    await asyncio.wait_for(live_ws(ws), timeout=2)
    assert ws.closed == (4401, "TOKEN_EXPIRED")
