"""TC16 (U7): an admin creates a route with stops while the Routes API fails. The route is
saved as a draft with POLYLINE_FAILED, cannot be activated or driven, and becomes usable
once the polyline is generated."""

from __future__ import annotations

from app.integrations.routes_api import RoutesApiError
from tests.acceptance.sim_support import L_ROUTE

STOPS = [{"name": f"Stop {i}", "lat": lat, "lng": lng} for i, (lat, lng) in enumerate(L_ROUTE, start=1)]


async def test_tc16_routes_api_failure_leaves_a_draft(client, con, live_app, admin, fake_routes, driver_with_bus):
    _, headers = await admin()
    fake_routes.fail = RoutesApiError("ZERO_RESULTS", "No route found between the stops")
    resp = await client.post("/api/v1/admin/routes", json={"name": "Hostel Loop", "stops": STOPS}, headers=headers)
    assert resp.status_code == 422
    body = resp.json()
    assert body["error"]["code"] == "POLYLINE_FAILED" and "No route found" in body["error"]["message"]
    route = body["route"]
    assert route["status"] == "draft" and route["polyline"] is None and len(route["stops"]) == len(STOPS)
    assert route["polyline_error"] and len(fake_routes.calls) == 1        # Directions called once
    route_id = route["id"]

    # Not activatable, not listed for students, and a driver cannot start a trip on it.
    act = await client.patch(f"/api/v1/admin/routes/{route_id}", json={"status": "active"}, headers=headers)
    assert act.status_code == 422 and act.json()["error"]["code"] == "POLYLINE_FAILED"
    public = (await client.get("/api/v1/routes", headers=headers)).json()["items"]
    assert route_id not in [r["id"] for r in public]
    driver = await driver_with_bus()
    start = await client.post("/api/v1/trips/start", json={"route_id": route_id}, headers=driver["headers"])
    assert start.status_code == 400 and start.json()["error"]["code"] == "VALIDATION_ERROR"

    # Once the Routes API works, regenerating fixes it.
    fake_routes.fail = None
    ok = await client.patch(f"/api/v1/admin/routes/{route_id}", json={"regenerate": True}, headers=headers)
    assert ok.status_code == 200, ok.text
    assert ok.json()["status"] == "active" and ok.json()["polyline"] and ok.json()["polyline_error"] is None
    start = await client.post("/api/v1/trips/start", json={"route_id": route_id}, headers=driver["headers"])
    assert start.status_code == 201


async def test_tc16_adding_a_stop_that_fails_turns_route_into_draft(client, admin, fake_routes):
    _, headers = await admin()
    created = await client.post("/api/v1/admin/routes", json={"name": "R", "stops": STOPS[:2]}, headers=headers)
    assert created.status_code == 201 and created.json()["status"] == "active"
    fake_routes.fail = RoutesApiError("http_500", "Routes API error (HTTP 500)")
    resp = await client.post(f"/api/v1/admin/routes/{created.json()['id']}/stops", json=STOPS[2], headers=headers)
    assert resp.status_code == 422 and resp.json()["error"]["code"] == "POLYLINE_FAILED"
    assert resp.json()["route"]["status"] == "draft"
