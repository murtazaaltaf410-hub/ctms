"""Pickup pin API (ADR-9, X2): validation against the route, one waiting pin, cancel, driver list."""

from __future__ import annotations

from datetime import timedelta

from tests.conftest import bearer
from tests.tracking_support import along_fix, point_at

pytest_plugins = ["tests.tracking_support"]


def pin(route_id, along_m=300.0, **extra):
    lat, lng = point_at(along_m)
    return {"route_id": str(route_id), "lat": lat, "lng": lng, **extra}


async def test_student_places_a_pin_near_the_route(client, live_app, make_route, google_login):
    route = await make_route()
    student = bearer((await google_login())["access_token"])
    resp = await client.post(
        "/api/v1/pickups", json=pin(route["id"], label="Near the mosque", direction="from_campus"), headers=student
    )
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["status"] == "waiting" and body["direction"] == "from_campus"
    assert body["label"] == "Near the mosque" and body["route_name"] == "Test Route"
    assert body["expires_at"].endswith("Z")
    mine = (await client.get("/api/v1/me/pickup", headers=student)).json()
    assert mine["id"] == body["id"]


async def test_pin_far_from_the_route_is_rejected(client, live_app, make_route, google_login):
    route = await make_route()
    student = bearer((await google_login())["access_token"])
    lat, lng = point_at(300)
    far = {"route_id": str(route["id"]), "lat": lat, "lng": lng + 0.02}  # roughly 1.8 km east of the road
    resp = await client.post("/api/v1/pickups", json=far, headers=student)
    assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_unknown_route_and_bad_input_are_rejected(client, live_app, google_login):
    student = bearer((await google_login())["access_token"])
    unknown = pin("00000000-0000-4000-8000-000000000999")
    assert (await client.post("/api/v1/pickups", json=unknown, headers=student)).status_code == 400
    bad = {"route_id": "00000000-0000-4000-8000-000000000999", "lat": 999, "lng": 0}
    assert (await client.post("/api/v1/pickups", json=bad, headers=student)).status_code == 400


async def test_a_new_pin_replaces_the_waiting_one(client, con, live_app, make_route, google_login):
    route = await make_route()
    student = bearer((await google_login())["access_token"])
    first = (await client.post("/api/v1/pickups", json=pin(route["id"], 200), headers=student)).json()
    second = (await client.post("/api/v1/pickups", json=pin(route["id"], 600), headers=student)).json()
    assert first["id"] != second["id"]
    assert (await client.get("/api/v1/me/pickup", headers=student)).json()["id"] == second["id"]
    statuses = {r["id"]: r["status"] for r in await con.fetch("select id::text, status from public.pickup_requests")}
    assert statuses == {first["id"]: "cancelled", second["id"]: "waiting"}


async def test_cancel_own_pin_only(client, live_app, make_route, google_login):
    route = await make_route()
    mine = bearer((await google_login("s1", "s1@gmail.com"))["access_token"])
    other = bearer((await google_login("s2", "s2@gmail.com"))["access_token"])
    created = (await client.post("/api/v1/pickups", json=pin(route["id"]), headers=mine)).json()
    assert (await client.delete(f"/api/v1/pickups/{created['id']}", headers=other)).status_code == 404
    assert (await client.delete(f"/api/v1/pickups/{created['id']}", headers=mine)).status_code == 204
    assert (await client.get("/api/v1/me/pickup", headers=mine)).json() is None
    assert (await client.delete(f"/api/v1/pickups/{created['id']}", headers=mine)).status_code == 404


async def test_expired_pin_is_not_returned(client, live_app, make_route, google_login, fake_clock):
    route = await make_route()
    student = bearer((await google_login())["access_token"])
    await client.post("/api/v1/pickups", json=pin(route["id"]), headers=student)
    fake_clock.advance(2 * 3600)
    assert (await client.get("/api/v1/me/pickup", headers=student)).json() is None


async def test_driver_sees_waiting_students_on_their_leg_without_identities(
    client, live_app, driver_with_bus, start_trip, post_fixes, google_login, fake_clock
):
    driver = await driver_with_bus()
    route = driver["route"]
    student = bearer((await google_login("s1", "s1@gmail.com"))["access_token"])
    other_leg = bearer((await google_login("s2", "s2@gmail.com"))["access_token"])
    await client.post("/api/v1/pickups", json=pin(route["id"], 700, label="Bus stand"), headers=student)
    await client.post("/api/v1/pickups", json=pin(route["id"], 300, direction="from_campus"), headers=other_leg)

    trip = await start_trip(driver, {"direction": "to_campus"})
    t0 = fake_clock.current
    await post_fixes(driver, trip["id"], [along_fix(100 + 10 * i, t0 + timedelta(seconds=i)) for i in range(0, 9, 4)])
    resp = await client.get(f"/api/v1/trips/{trip['id']}/pickups", headers=driver["headers"])
    assert resp.status_code == 200, resp.text
    items = resp.json()["items"]
    assert [i["label"] for i in items] == ["Bus stand"]  # the from_campus pin is another leg
    assert items[0]["distance_m"] is not None and 500 < items[0]["distance_m"] < 700
    # No student identity for a student of this bus (the card is only for needs_decision/accepted pins).
    assert set(items[0]) == {"id", "lat", "lng", "label", "distance_m", "created_at", "decision", "student"}
    assert items[0]["decision"] == "auto" and items[0]["student"] is None


async def test_roles_and_ownership_are_enforced(
    client, live_app, driver_with_bus, start_trip, make_route, google_login
):
    route = await make_route()
    driver = await driver_with_bus()
    other_driver = await driver_with_bus()
    trip = await start_trip(driver)
    student = bearer((await google_login())["access_token"])
    # A student cannot read the driver's list, a driver cannot place a pin, another driver's trip is 403.
    assert (await client.get(f"/api/v1/trips/{trip['id']}/pickups", headers=student)).status_code == 403
    assert (await client.post("/api/v1/pickups", json=pin(route["id"]), headers=driver["headers"])).status_code == 403
    assert (await client.get(f"/api/v1/trips/{trip['id']}/pickups", headers=other_driver["headers"])).status_code == 403


async def test_deleting_the_student_deletes_their_pin(client, con, live_app, make_route, google_login, delete_account):
    route = await make_route()
    student = bearer((await google_login())["access_token"])
    await client.post("/api/v1/pickups", json=pin(route["id"]), headers=student)
    assert await con.fetchval("select count(*) from public.pickup_requests") == 1
    uid = (await client.get("/api/v1/me", headers=student)).json()["id"]
    await delete_account(uid)
    assert await con.fetchval("select count(*) from public.pickup_requests") == 0
