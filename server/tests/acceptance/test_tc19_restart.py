"""TC19 (N4): the server restarts mid-trip. The trip is not closed, the driver keeps uploading,
and the map recovers within one fix; the trip's distance still matches the simulator."""

from __future__ import annotations

from uuid import UUID

from app.live.writer import get_writer
from app.modules.trips.service import rebuild_live
from tests.acceptance.sim_support import live_bus, plan, within


async def restart(app, *, rebuild: bool) -> None:
    await get_writer(app).flush(app)  # shutdown flush
    app.state.live = None  # all in-memory state is lost
    app.state.live_writer = None
    if rebuild:
        await rebuild_live(app)  # startup hook


async def test_tc19_restart_mid_trip_recovers_within_one_fix(client, con, live_app, sim_trip, google_login):
    route, _driver, trip, player = await sim_trip()
    student = {"Authorization": f"Bearer {(await google_login())['access_token']}"}
    fixes, events = plan(route.geom, player.start, speed_kmh=30, fix_every_s=3, interval_s=5)
    half = len(events) // 2
    await player.play(events[:half])
    before = await live_bus(client, student, trip["bus_id"])

    await restart(live_app, rebuild=True)
    # Right after the restart the bus is back at its last stored position.
    after = await live_bus(client, student, trip["bus_id"])
    assert (after["lat"], after["lng"]) == (before["lat"], before["lng"])

    [first] = await player.play(events[half : half + 1])
    assert first.status_code == 200 and not first.rejected
    bus = await live_bus(client, student, trip["bus_id"])
    newest = events[half].item.fixes[-1]
    assert (bus["lat"], bus["lng"]) == (round(newest.lat, 7), round(newest.lng, 7)) and bus["state"] == "live"

    await player.play(events[half + 1 :])
    assert await con.fetchval("select ended_at from public.trips where id = $1", UUID(trip["id"])) is None
    summary = await player.end(events[-1].t)
    assert within(summary["distance_m"], fixes[-1].along_m, 2)


async def test_tc19_restart_without_rebuild_resumes_on_next_fix(client, live_app, sim_trip):
    """Even if the startup rebuild did not run, the next upload re-creates the bus from the DB."""
    route, driver, trip, player = await sim_trip()
    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=5, minutes=2)
    half = len(events) // 2
    await player.play(events[:half])
    await restart(live_app, rebuild=False)
    assert await live_bus(client, driver["headers"], trip["bus_id"]) is None
    rest = await player.play(events[half:])
    assert all(u.status_code == 200 and not u.rejected for u in rest)
    assert (await live_bus(client, driver["headers"], trip["bus_id"]))["trip_id"] == trip["id"]
