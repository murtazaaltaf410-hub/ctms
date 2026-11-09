"""Trip direction: home -> campus (to_campus) and campus -> home (from_campus) on one route."""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

from datetime import time, timedelta
from zoneinfo import ZoneInfo

import pytest

from app.geo import cumulative_distances
from app.live.state import RouteGeom
from tests.admin_helpers import admin, insert_route  # noqa: F401
from tests.conftest import bearer
from tests.tracking_support import along_fix, route_points

pytest_plugins = ["tests.tracking_support"]


def test_route_geom_reversed_flips_points_and_recomputes_distances():
    points = route_points(5)
    geom = RouteGeom(route_id=None, name="R", points=points, cum=cumulative_distances(points))  # type: ignore[arg-type]
    back = geom.reversed()
    assert back.points == list(reversed(points))
    assert back.cum[0] == 0.0
    assert back.cum[-1] == pytest.approx(geom.cum[-1], rel=1e-6)
    assert back.cum == sorted(back.cum)


async def test_start_defaults_to_to_campus(client, live_app, driver_with_bus, start_trip):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    assert trip["direction"] == "to_campus"
    active = (await client.get("/api/v1/trips/active", headers=driver["headers"])).json()
    assert active["direction"] == "to_campus"


async def test_start_rejects_unknown_direction(client, live_app, driver_with_bus):
    driver = await driver_with_bus()
    resp = await client.post("/api/v1/trips/start", json={"direction": "sideways"}, headers=driver["headers"])
    assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_from_campus_trip_reads_the_route_in_reverse(
    client, live_app, driver_with_bus, start_trip, post_fixes, google_login, fake_clock
):
    driver = await driver_with_bus()
    total = driver["route"]["cum"][-1]
    trip = await start_trip(driver, {"direction": "from_campus"})
    assert trip["direction"] == "from_campus"
    t0 = fake_clock.current
    # Constant 10 m/s heading back towards the stored START: stored 1000 m -> 800 m.
    await post_fixes(
        driver,
        trip["id"],
        [along_fix(1000 - 10 * i, t0 + timedelta(seconds=i), speed=10.0) for i in range(0, 21, 4)],
    )
    student = bearer((await google_login())["access_token"])
    stops = driver["route"]["stops"]  # stored order: 0 m, 555 m, end
    first_stop, middle, last_stop = stops[0], stops[1], stops[2]

    # The stored end is where this trip starts, so it is behind the bus; the stored start is ahead.
    behind = (await client.get(f"/api/v1/stops/{last_stop}/eta", headers=student)).json()["etas"][0]
    assert behind["passed"] is True
    ahead = (await client.get(f"/api/v1/stops/{middle}/eta", headers=student)).json()["etas"][0]
    assert ahead["passed"] is False
    assert ahead["distance_m"] == pytest.approx(800 - 555, abs=3)
    far = (await client.get(f"/api/v1/stops/{first_stop}/eta", headers=student)).json()["etas"][0]
    assert far["passed"] is False and far["distance_m"] == pytest.approx(800, abs=3)
    assert total > 1000

    live = (await client.get("/api/v1/buses/live", headers=student)).json()
    assert [b["direction"] for b in live] == ["from_campus"]


async def test_to_campus_trip_is_unchanged(
    client, live_app, driver_with_bus, start_trip, post_fixes, google_login, fake_clock
):
    driver = await driver_with_bus()
    trip = await start_trip(driver, {"direction": "to_campus"})
    t0 = fake_clock.current
    await post_fixes(
        driver, trip["id"], [along_fix(100 + 10 * i, t0 + timedelta(seconds=i), speed=10.0) for i in range(0, 21, 4)]
    )
    student = bearer((await google_login())["access_token"])
    ahead = (await client.get(f"/api/v1/stops/{driver['route']['stops'][1]}/eta", headers=student)).json()["etas"][0]
    assert ahead["distance_m"] == pytest.approx(555 - 300, abs=3)


async def test_schedule_slot_only_matches_its_own_direction(
    client, con, live_app, driver_with_bus, start_trip, fake_clock
):
    driver = await driver_with_bus()
    now_local = fake_clock.current.astimezone(ZoneInfo("Asia/Kolkata"))
    await con.execute(
        """insert into public.schedules (route_id, departure_time, days_of_week, direction)
           values ($1, $2, '{1,2,3,4,5,6,7}', 'from_campus')""",
        driver["route"]["id"],
        time(now_local.hour, now_local.minute),
    )
    wrong_leg = await start_trip(driver)  # to_campus: the slot is for the return leg
    assert wrong_leg["type"] == "ad_hoc" and wrong_leg["schedule_id"] is None
    await client.post(f"/api/v1/trips/{wrong_leg['id']}/end", headers=driver["headers"])
    right_leg = await start_trip(driver, {"direction": "from_campus"})
    assert right_leg["type"] == "scheduled" and right_leg["schedule_id"] is not None


async def test_admin_schedule_direction_defaults_and_updates(client, admin, con):
    _, headers = await admin()
    rid = await insert_route(con)
    created = (
        await client.post(
            "/api/v1/admin/schedules",
            json={"route_id": str(rid), "departure_time": "16:30", "days_of_week": [1, 2, 3]},
            headers=headers,
        )
    ).json()
    assert created["direction"] == "to_campus"
    patched = await client.patch(
        f"/api/v1/admin/schedules/{created['id']}", json={"direction": "from_campus"}, headers=headers
    )
    assert patched.status_code == 200 and patched.json()["direction"] == "from_campus"
    bad = await client.patch(f"/api/v1/admin/schedules/{created['id']}", json={"direction": "up"}, headers=headers)
    assert bad.status_code == 400
