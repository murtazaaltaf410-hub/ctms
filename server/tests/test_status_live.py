"""V1.3 bug 13: the driver's status/delay and note must reach students live (REST and WebSocket)."""

from __future__ import annotations

import asyncio
import json

from app.live.hub import get_hub
from app.live.state import get_live
from tests.tracking_support import FakeWS, along_fix, hub_clients, wait_until

pytest_plugins = ["tests.tracking_support"]

API = "/api/v1"


async def _connect(app, token: str) -> FakeWS:
    from app.live.ws import live_ws

    ws = FakeWS(app)
    ws.task = asyncio.create_task(live_ws(ws))
    ws.say(json.dumps({"type": "auth", "token": token}))
    await wait_until(lambda: ws in get_hub(app).clients or ws.closed is not None)
    assert ws.closed is None
    return ws


async def _live(client, student) -> dict:
    resp = await client.get(f"{API}/buses/live", headers={"Authorization": f"Bearer {student['access_token']}"})
    assert resp.status_code == 200, resp.text
    return resp.json()[0]


async def test_driver_status_and_note_reach_students_rest_and_ws(
    client, live_app, google_login, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    student = await google_login()
    ws = await _connect(live_app, student["access_token"])
    trip = await start_trip(driver)
    await post_fixes(driver, trip["id"], [along_fix(100, fake_clock.current, speed=6.0)])

    resp = await client.post(f"{API}/trips/{trip['id']}/status", json={"status": "delayed", "note": "Traffic"},
                             headers=driver["headers"])
    assert resp.status_code == 204, resp.text

    assert {"type": "bus_status", "bus_id": trip["bus_id"], "trip_id": trip["id"], "status": "delayed",
            "note": "Traffic"} in ws.sent
    live = await _live(client, student)
    assert (live["status"], live["note"]) == ("delayed", "Traffic")

    # A student reconnecting later (new socket + REST) still sees the current status.
    ws.hang_up()
    await asyncio.wait_for(ws.task, timeout=2)
    ws2 = await _connect(live_app, student["access_token"])
    # The snapshot sent on connect carries the current status even though the update predates this socket.
    assert ws2.sent[0] == {"type": "bus_status", "bus_id": trip["bus_id"], "trip_id": trip["id"],
                           "status": "delayed", "note": "Traffic"}
    live = await _live(client, student)
    assert (live["status"], live["note"]) == ("delayed", "Traffic")
    assert hub_clients(live_app) == 1 and ws2.closed is None

    # Back to on time: note cleared.
    await client.post(f"{API}/trips/{trip['id']}/status", json={"status": "on_time"}, headers=driver["headers"])
    assert {"type": "bus_status", "bus_id": trip["bus_id"], "trip_id": trip["id"], "status": "on_time",
            "note": None} in ws2.sent
    live = await _live(client, student)
    assert (live["status"], live["note"]) == ("on_time", None)
    ws2.hang_up()
    await asyncio.wait_for(ws2.task, timeout=2)


async def test_status_before_first_fix_survives_a_restart_rebuild(
    client, live_app, google_login, driver_with_bus, start_trip, post_fixes, fake_clock
):
    from app.modules.trips.service import rebuild_live

    driver = await driver_with_bus()
    student = await google_login()
    trip = await start_trip(driver)
    await client.post(f"{API}/trips/{trip['id']}/status", json={"status": "breakdown", "note": "Flat"},
                      headers=driver["headers"])
    get_live(live_app).buses.clear()   # server restart
    await rebuild_live(live_app)
    await post_fixes(driver, trip["id"], [along_fix(100, fake_clock.current, speed=6.0)])
    live = await _live(client, student)
    assert (live["status"], live["note"]) == ("breakdown", "Flat")
