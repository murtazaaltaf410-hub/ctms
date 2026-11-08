"""TC17 (U5, U6): during an active simulated trip, deleting its route (or a stop, or the bus)
is blocked with IN_USE; removing the last admin is blocked with LAST_ADMIN. Edits made during
the trip apply from the next trip."""

from __future__ import annotations

from tests.acceptance.sim_support import plan, stop_eta, within


async def test_tc17_route_stop_and_bus_cannot_be_removed_during_a_trip(client, live_app, admin, fake_routes,
                                                                     sim_trip):
    _, headers = await admin()
    route, _driver, trip, player = await sim_trip()
    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=10, minutes=3)
    await player.play(events[: len(events) // 2])

    calls = [
        ("PATCH", f"/api/v1/admin/routes/{route.id}", {"active": False}),
        ("PATCH", f"/api/v1/admin/stops/{route.stops[2]}", {"active": False}),
        ("PATCH", f"/api/v1/admin/buses/{trip['bus_id']}", {"active": False}),
    ]
    for method, path, body in calls:
        resp = await client.request(method, path, json=body, headers=headers)
        assert resp.status_code == 409 and resp.json()["error"]["code"] == "IN_USE", (path, resp.text)
    detail = (await client.get(f"/api/v1/admin/routes/{route.id}", headers=headers)).json()
    assert detail["active"] and len(detail["stops"]) == len(route.stops) and detail["warning"]

    # The trip is unaffected and, once it ends, the route can be removed (soft delete).
    rest = await player.play(events[len(events) // 2:])
    assert all(u.status_code == 200 for u in rest)
    await player.end()
    resp = await client.patch(f"/api/v1/admin/routes/{route.id}", json={"active": False}, headers=headers)
    assert resp.status_code == 200 and resp.json()["active"] is False
    trips = (await client.get("/api/v1/admin/trips", headers=headers)).json()["items"]
    assert [t["route_name"] for t in trips if t["id"] == trip["id"]] == [route.name]   # history keeps names


async def test_tc17_last_admin_cannot_be_removed(client, admin):
    admin_id, headers = await admin()
    resp = await client.delete(f"/api/v1/admin/admins/{admin_id}", headers=headers)
    assert resp.status_code == 409 and resp.json()["error"]["code"] == "LAST_ADMIN"
    # With a second admin the first one can go.
    second_id, second = await admin(2)
    assert (await client.delete(f"/api/v1/admin/admins/{admin_id}", headers=second)).status_code == 204
    resp = await client.delete(f"/api/v1/admin/admins/{second_id}", headers=second)
    assert resp.status_code == 409 and resp.json()["error"]["code"] == "LAST_ADMIN"


async def test_tc17_u6_stop_added_mid_trip_does_not_change_running_trip_etas(client, live_app, admin, fake_routes,
                                                                            sim_trip, google_login):
    _, headers = await admin()
    route, _driver, _trip, player = await sim_trip()
    student = {"Authorization": f"Bearer {(await google_login())['access_token']}"}
    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=10, minutes=2)
    await player.play(events)                 # bus ~1000 m along, heading for the stop at 2250 m
    target = route.stops[3]
    before = (await stop_eta(client, student, target))["etas"][0]["eta_seconds"]
    # Admin adds a new first stop ~600 m before the start: the new polyline is ~600 m longer at the front.
    resp = await client.post(f"/api/v1/admin/routes/{route.id}/stops", headers=headers,
                             json={"name": "New first stop", "lat": 34.1146, "lng": 74.8300, "sequence": 1})
    assert resp.status_code == 201, resp.text
    assert resp.json()["warning"]             # the admin is told the edit applies from the next trip
    after = (await stop_eta(client, student, target))["etas"][0]["eta_seconds"]
    assert within(after, before, 5), (before, after)
