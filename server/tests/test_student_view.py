"""V1.3 decisions 7 and 10: students see first/last stop only; ETA and mid-route start do not rely on stop 1."""

from __future__ import annotations

from uuid import UUID

from tests.conftest import bearer
from tests.tracking_support import along_fix, point_at

pytest_plugins = ["tests.tracking_support"]

API = "/api/v1"
STOPS = [0.0, 300.0, 555.0, 800.0, 1110.0]


async def test_student_route_detail_has_first_and_last_stop_but_full_polyline(
        client, live_app, make_route, google_login, driver_with_bus):
    route = await make_route(stops=STOPS)
    student = bearer((await google_login())["access_token"])
    body = (await client.get(f"{API}/routes/{route['id']}", headers=student)).json()
    assert [s["name"] for s in body["stops"]] == ["Stop 1", "Stop 5"] and body["polyline"]
    driver = await driver_with_bus(route=route)
    full = (await client.get(f"{API}/routes/{route['id']}", headers=driver["headers"])).json()
    assert len(full["stops"]) == 5 and full["polyline"] == body["polyline"]


async def test_my_eta_goes_to_the_pin_else_the_first_stop(
        client, live_app, google_login, driver_with_bus, make_route, start_trip, post_fixes, fake_clock):
    route = await make_route(stops=STOPS)
    driver = await driver_with_bus(route=route)
    student = bearer((await google_login())["access_token"])
    trip = await start_trip(driver)
    await post_fixes(driver, trip["id"], [along_fix(100, fake_clock.current, speed=10.0)])
    eta = (await client.get(f"{API}/me/eta", headers=student)).json()
    assert eta["target"]["type"] == "first_stop" and eta["target"]["label"] == "Stop 1"
    assert eta["etas"][0]["passed"] is True        # the bus is already past the first stop
    lat, lng = point_at(700)
    r = await client.post(f"{API}/pickups", json={"route_id": str(route["id"]), "lat": lat, "lng": lng},
                          headers=student)
    assert r.status_code == 201, r.text
    eta = (await client.get(f"{API}/me/eta", headers=student)).json()
    assert eta["target"]["type"] == "pickup"
    [e] = eta["etas"]
    assert e["passed"] is False and 550 < e["distance_m"] < 650 and e["eta_seconds"] > 0
    nearest = await client.get(f"{API}/routes/nearest", params={"lat": lat, "lng": lng}, headers=student)
    assert nearest.status_code == 200


async def test_trip_can_start_mid_route(
        client, live_app, driver_with_bus, make_route, start_trip, post_fixes, fake_clock, google_login):
    route = await make_route(stops=STOPS)
    driver = await driver_with_bus(route=route)
    student = bearer((await google_login())["access_token"])
    trip = await start_trip(driver)
    await post_fixes(driver, trip["id"], [along_fix(600, fake_clock.current, speed=9.0)])
    live = (await client.get(f"{API}/buses/live", headers=student)).json()
    assert len(live) == 1 and abs(live[0]["lat"] - point_at(600)[0]) < 1e-6
    stop4 = (await client.get(f"{API}/routes/{route['id']}", headers=driver["headers"])).json()["stops"][3]
    eta = (await client.get(f"{API}/stops/{stop4['id']}/eta", headers=driver["headers"])).json()["etas"][0]
    assert eta["passed"] is False and 150 < eta["distance_m"] < 250
    stop2 = (await client.get(f"{API}/routes/{route['id']}", headers=driver["headers"])).json()["stops"][1]
    eta2 = (await client.get(f"{API}/stops/{stop2['id']}/eta", headers=driver["headers"])).json()["etas"][0]
    assert eta2["passed"] is True
    assert (await client.get(f"{API}/trips/active", headers=driver["headers"])).json()["id"] == trip["id"]
    assert UUID(trip["id"])
