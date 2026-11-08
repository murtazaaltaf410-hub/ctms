"""TC8 (stale 30 s / offline 2 min, time-mocked) and TC19 / N4 (restart mid-trip)."""

from __future__ import annotations

from datetime import timedelta
from uuid import UUID

from app.live.state import get_live
from app.live.writer import get_writer
from app.modules.trips.service import rebuild_live
from tests.tracking_support import along_fix

pytest_plugins = ["tests.tracking_support"]


async def state_of(client, driver) -> str:
    [bus] = (await client.get("/api/v1/buses/live", headers=driver["headers"])).json()
    return bus["state"]


async def test_tc8_stale_at_30s_offline_at_2min(client, live_app, driver_with_bus, start_trip, post_fixes, fake_clock):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    await post_fixes(driver, trip["id"], [along_fix(0, fake_clock.current, speed=8)])
    assert await state_of(client, driver) == "live"
    fake_clock.advance(29)
    assert await state_of(client, driver) == "live"
    fake_clock.advance(1)
    assert await state_of(client, driver) == "stale"
    fake_clock.advance(89)
    assert await state_of(client, driver) == "stale"
    fake_clock.advance(1)
    assert await state_of(client, driver) == "offline"
    # A new fix brings it straight back.
    await post_fixes(driver, trip["id"], [along_fix(100, fake_clock.current, speed=8)])
    assert await state_of(client, driver) == "live"


async def test_trip_without_fix_not_listed_yet(client, live_app, driver_with_bus, start_trip):
    driver = await driver_with_bus()
    await start_trip(driver)
    assert (await client.get("/api/v1/buses/live", headers=driver["headers"])).json() == []


async def test_tc19_restart_mid_trip_rebuilds_from_db(
    client, con, live_app, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    t0 = fake_clock.current
    await post_fixes(driver, trip["id"], [along_fix(10 * i, t0 + timedelta(seconds=2 * i), speed=5) for i in range(4)])
    await post_fixes(
        driver,
        trip["id"],
        [
            along_fix(40, t0 + timedelta(seconds=8)),
        ],
    )
    await get_writer(live_app).flush(live_app)  # shutdown flush
    # "Restart": all in-memory state is lost.
    live_app.state.live = None
    live_app.state.live_writer = None
    assert await rebuild_live(live_app) == 1
    bus = get_live(live_app).by_trip(UUID(trip["id"]))
    assert bus is not None and bus.along_m is not None and bus.distance_m > 0
    [listed] = (await client.get("/api/v1/buses/live", headers=driver["headers"])).json()
    assert listed["trip_id"] == trip["id"] and listed["status"] == "on_time"
    # The trip is not closed, and the next fix moves the bus (map recovers within one fix).
    fake_clock.advance(3)
    nxt = along_fix(70, t0 + timedelta(seconds=11))
    assert (await post_fixes(driver, trip["id"], [nxt]))["accepted"] == [nxt["fix_id"]]
    [listed] = (await client.get("/api/v1/buses/live", headers=driver["headers"])).json()
    assert listed["lat"] == nxt["lat"] and listed["state"] in ("live", "stopped")
    assert await con.fetchval("select ended_at from public.trips where id = $1", UUID(trip["id"])) is None


async def test_n4_active_trip_missing_from_memory_resumes_on_next_fix(
    client, live_app, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    live_app.state.live = None  # lost without a rebuild
    f = along_fix(0, fake_clock.current)
    assert (await post_fixes(driver, trip["id"], [f]))["accepted"] == [f["fix_id"]]
    assert len((await client.get("/api/v1/buses/live", headers=driver["headers"])).json()) == 1
