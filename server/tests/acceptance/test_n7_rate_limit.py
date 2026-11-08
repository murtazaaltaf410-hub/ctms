"""N7: a driver phone uploading faster than the location limit gets 429 RATE_LIMITED with
Retry-After; it keeps the fixes buffered and resends them later without losing any."""

from __future__ import annotations

import pytest

from tests.acceptance.sim_support import plan


@pytest.fixture
def config_overrides() -> dict:
    return {"rate_locations_per_user": 5, "rate_general_per_user": 100_000, "rate_general_per_ip": 100_000}


async def test_n7_429_with_retry_after_then_buffered_fixes_resent(client, live_app, sim_trip):
    route, driver, trip, player = await sim_trip()
    fixes, events = plan(route.geom, player.start, speed_kmh=30, fix_every_s=3, interval_s=3, minutes=1)
    url = f"/api/v1/trips/{trip['id']}/locations"
    buffer, accepted = [], set()
    limited = 0
    for ev in events:
        player.move_clock(ev.t)
        buffer.extend(ev.item.fixes)
        resp = await client.post(url, json={"fixes": [f.payload() for f in buffer[:20]]}, headers=driver["headers"])
        if resp.status_code == 429:
            limited += 1
            assert resp.json()["error"]["code"] == "RATE_LIMITED" and int(resp.headers["Retry-After"]) > 0
            continue  # keep buffering
        assert resp.status_code == 200, resp.text
        accepted |= set(resp.json()["accepted"])
        buffer = buffer[20:]
    assert limited > 0
    live_app.state.rate_limiter.reset()  # the window passes
    while buffer:
        resp = await client.post(url, json={"fixes": [f.payload() for f in buffer[:20]]}, headers=driver["headers"])
        assert resp.status_code == 200, resp.text
        accepted |= set(resp.json()["accepted"])
        buffer = buffer[20:]
    assert accepted == {str(f.fix_id) for f in fixes}
