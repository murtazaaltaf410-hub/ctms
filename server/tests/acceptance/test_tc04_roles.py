"""TC4: a student calling admin endpoints gets 403 FORBIDDEN_ROLE; a driver posting to
another driver's trip gets 403 NOT_YOUR_TRIP."""

from __future__ import annotations

from uuid import uuid4

import pytest

from tests.acceptance.sim_support import plan
from tests.conftest import bearer

ADMIN_CALLS = [
    ("GET", "/api/v1/admin/buses", None),
    ("POST", "/api/v1/admin/buses", {"label": "X", "plate": "X1"}),
    ("GET", "/api/v1/admin/drivers", None),
    ("POST", "/api/v1/admin/routes", {"name": "X"}),
    ("GET", "/api/v1/admin/trips", None),
    ("GET", "/api/v1/admin/reports/summary", None),
    ("GET", "/api/v1/admin/reports/trips.csv", None),
    ("GET", "/api/v1/admin/settings", None),
    ("PUT", "/api/v1/admin/settings", {"alert_radius_m": 300}),
    ("POST", "/api/v1/admin/announcements", {"title": "x", "body": "y", "urgent": False, "push": False}),
    ("GET", "/api/v1/admin/admins", None),
    ("POST", "/api/v1/admin/admins", {"email": "me@uok.edu.in"}),
]


@pytest.mark.parametrize(("method", "path", "body"), ADMIN_CALLS)
async def test_tc4_student_and_driver_get_forbidden_role_on_admin_endpoints(client, google_login, create_user,
                                                                            driver_login, method, path, body):
    student = await google_login(sub="tc4-student", email="tc4@uok.edu.in")
    await create_user("driver", name="TC4 Driver", phone="+919822200001")
    driver = await driver_login("+919822200001")
    for tokens in (student, driver):
        resp = await client.request(method, path, json=body, headers=bearer(tokens["access_token"]))
        assert resp.status_code == 403, (path, resp.text)
        assert resp.json()["error"]["code"] == "FORBIDDEN_ROLE"


async def test_tc4_driver_cannot_touch_another_drivers_trip(client, live_app, sim_trip, driver_with_bus):
    route, owner, trip, player = await sim_trip()
    _fixes, events = plan(route.geom, player.start, minutes=1)
    await player.play(events[:2])
    intruder = await driver_with_bus()
    batch = events[2].item.payload
    calls = [
        ("POST", f"/api/v1/trips/{trip['id']}/locations", batch),
        ("POST", f"/api/v1/trips/{trip['id']}/status", {"status": "breakdown", "note": "fake"}),
        ("POST", f"/api/v1/trips/{trip['id']}/end", None),
    ]
    for method, path, body in calls:
        resp = await client.request(method, path, json=body, headers=intruder["headers"])
        assert resp.status_code == 403 and resp.json()["error"]["code"] == "NOT_YOUR_TRIP", (path, resp.text)
    # The owner's trip is untouched: still running, on time, and the intruder's batch was not stored.
    active = (await client.get("/api/v1/trips/active", headers=owner["headers"])).json()
    assert active["id"] == trip["id"] and active["status"] == "on_time" and active["ended_at"] is None
    again = await client.post(f"/api/v1/trips/{trip['id']}/locations", json=batch, headers=owner["headers"])
    assert again.status_code == 200 and not again.json()["rejected"]


async def test_tc4_students_cannot_post_fixes_or_start_trips(client, live_app, sim_trip, google_login):
    route, _owner, trip, player = await sim_trip()
    student = await google_login(sub="tc4-s2", email="tc4b@uok.edu.in")
    _, events = plan(route.geom, player.start, minutes=1)
    for path, body in ((f"/api/v1/trips/{trip['id']}/locations", events[0].item.payload),
                       ("/api/v1/trips/start", {}), (f"/api/v1/trips/{uuid4()}/end", None)):
        resp = await client.post(path, json=body, headers=bearer(student["access_token"]))
        assert resp.status_code == 403 and resp.json()["error"]["code"] == "FORBIDDEN_ROLE", (path, resp.text)
