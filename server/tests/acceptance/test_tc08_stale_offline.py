"""TC8 (T5): with no fixes for 2 minutes the bus goes stale at 30 s and offline at 2 min
(time-mocked through the injected clock; freshness follows server receive time)."""

from __future__ import annotations

from tests.acceptance.sim_support import live_bus, plan, stop_eta


async def test_tc8_stale_at_30s_offline_at_2min_then_live_again(client, live_app, fake_clock, sim_trip, google_login):
    route, _driver, trip, player = await sim_trip()
    student = {"Authorization": f"Bearer {(await google_login())['access_token']}"}
    _fixes, events = plan(route.geom, player.start, speed_kmh=20, minutes=8, interval_s=5)
    # Drive for one minute, then the phone goes silent (GPS lost in a building).
    await player.play(events, until=60)
    last = max(u.t for u in player.uploads)
    bus = await live_bus(client, student, trip["bus_id"])
    assert bus["state"] == "live"
    seen_at = bus["last_fix_at"]

    expected = [(29, "live"), (30, "stale"), (60, "stale"), (119, "stale"), (120, "offline"), (300, "offline")]
    for silent_s, state in expected:
        player.move_clock(last + silent_s)
        bus = await live_bus(client, student, trip["bus_id"])
        assert bus["state"] == state, (silent_s, bus)
        assert bus["last_fix_at"] == seen_at  # "last seen" stays the time of the last fix
        eta = await stop_eta(client, student, route.stops[-1])
        assert [e["state"] for e in eta["etas"]] == [state]
    # The bus stays listed while its trip is active (shown as offline, not hidden) ...
    assert (await live_bus(client, student, trip["bus_id"]))["trip_id"] == trip["id"]
    # ... and the next fix makes it live again.
    resumed = [ev for ev in events if ev.t > last + 300][:1]
    assert resumed and (await player.play(resumed))[0].accepted
    assert (await live_bus(client, student, trip["bus_id"]))["state"] == "live"


async def test_tc8_freshness_uses_server_time_not_phone_time(client, live_app, sim_trip):
    """A buffered upload of old fixes counts as fresh from when it arrives (T13)."""
    route, driver, trip, player = await sim_trip()
    _, events = plan(route.geom, player.start, speed_kmh=30, minutes=1, interval_s=60)
    player.move_clock(100)  # the first minute of fixes arrives 40 s after the newest was recorded
    resp = await client.post(
        f"/api/v1/trips/{trip['id']}/locations", json=events[1].item.payload, headers=driver["headers"]
    )
    assert resp.status_code == 200 and not resp.json()["rejected"]
    bus = await live_bus(client, driver["headers"], trip["bus_id"])
    assert bus["state"] == "live"
    assert bus["recorded_at"] == events[1].item.fixes[-1].payload()["recorded_at"]
    assert bus["last_fix_at"] == player.at(100).isoformat().replace("+00:00", "Z")
