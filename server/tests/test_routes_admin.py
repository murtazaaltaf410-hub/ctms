"""Routes and stops: polyline generation (ADR-8), TC16/U7 (POLYLINE_FAILED draft), TC17/U6 (IN_USE)."""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from app.integrations.routes_api import RoutesApiError
from tests.admin_helpers import CAMPUS, admin, err, fake_routes, insert_route, insert_trip  # noqa: F401
from tests.conftest import bearer

STOPS = [{"name": f"S{i}", "lat": lat, "lng": lng} for i, (lat, lng) in enumerate(CAMPUS, start=1)]


async def test_create_route_generates_polyline_once(client, admin, fake_routes, con):
    _, headers = await admin()
    resp = await client.post("/api/v1/admin/routes", json={"name": "North", "stops": STOPS}, headers=headers)
    assert resp.status_code == 201, resp.text
    route = resp.json()
    assert len(fake_routes.calls) == 1 and fake_routes.calls[0] == CAMPUS
    assert route["status"] == "active" and route["polyline"] and route["polyline_error"] is None
    assert route["warning"] is None and route["active"] is True
    along = [s["dist_along_m"] for s in route["stops"]]
    assert [s["sequence"] for s in route["stops"]] == [1, 2, 3, 4]
    assert along[0] == 0 and along == sorted(along) and along[-1] == route["length_m"] > 700
    db = await con.fetchrow("select cum_dist_m, length_m from public.routes where id = $1", route["id"])
    assert len(db["cum_dist_m"]) == len(CAMPUS) and db["cum_dist_m"][-1] == db["length_m"]
    assert await con.fetchval("select count(*) from public.audit_log where action = 'route.polyline_generated' "
                              "and target_id = $1", route["id"]) == 1

    # Public view (any signed-in user).
    listed = (await client.get("/api/v1/routes", headers=headers)).json()
    assert [(r["name"], r["stop_count"]) for r in listed["items"]] == [("North", 4)]
    detail = (await client.get(f"/api/v1/routes/{route['id']}", headers=headers)).json()
    assert detail["polyline"] == route["polyline"] and len(detail["stops"]) == 4
    assert "polyline_error" not in detail


async def test_tc16_routes_api_failure_saves_draft(client, admin, fake_routes, con):
    _, headers = await admin()
    fake_routes.fail = RoutesApiError("http_403", "Routes API error (HTTP 403): API key not valid")
    resp = await client.post("/api/v1/admin/routes", json={"name": "Broken", "stops": STOPS}, headers=headers)
    assert resp.status_code == 422
    body = resp.json()
    assert body["error"] == {"code": "POLYLINE_FAILED", "message": "Routes API error (HTTP 403): API key not valid"}
    route = body["route"]
    assert route["status"] == "draft" and route["polyline"] is None and "API key" in route["polyline_error"]
    assert len(route["stops"]) == 4 and all(s["dist_along_m"] is None for s in route["stops"])
    row = await con.fetchrow("select status, polyline_error from public.routes where id = $1", route["id"])
    assert row["status"] == "draft" and row["polyline_error"]
    audit = await con.fetchrow("select meta from public.audit_log where action = 'route.polyline_failed'")
    assert audit["meta"] == {"reason": "http_403", "stops": 4}

    # Drafts are hidden from students and cannot be activated without a polyline (U7).
    assert (await client.get("/api/v1/routes", headers=headers)).json()["items"] == []
    resp = await client.patch(f"/api/v1/admin/routes/{route['id']}", json={"status": "active"}, headers=headers)
    assert resp.status_code == 422 and err(resp) == "POLYLINE_FAILED"

    # Once the API works again, a retry activates it.
    fake_routes.fail = None
    resp = await client.patch(f"/api/v1/admin/routes/{route['id']}", json={"regenerate": True}, headers=headers)
    assert resp.status_code == 200 and resp.json()["status"] == "active" and resp.json()["polyline_error"] is None


async def test_route_with_too_few_stops_stays_draft_without_error(client, admin, fake_routes):
    _, headers = await admin()
    resp = await client.post("/api/v1/admin/routes", json={"name": "Empty"}, headers=headers)
    assert resp.status_code == 201 and resp.json()["status"] == "draft" and resp.json()["polyline_error"] is None
    rid = resp.json()["id"]
    resp = await client.post(f"/api/v1/admin/routes/{rid}/stops", json=STOPS[0], headers=headers)
    assert resp.status_code == 201 and resp.json()["status"] == "draft" and fake_routes.calls == []
    resp = await client.post(f"/api/v1/admin/routes/{rid}/stops", json=STOPS[1], headers=headers)
    assert resp.status_code == 201 and resp.json()["status"] == "active" and len(fake_routes.calls) == 1


async def test_stop_insert_reorder_and_remove(client, admin, fake_routes):
    _, headers = await admin()
    route = (await client.post("/api/v1/admin/routes", json={"name": "R", "stops": STOPS[1:]},
                               headers=headers)).json()
    rid = route["id"]
    resp = await client.post(f"/api/v1/admin/routes/{rid}/stops", json={**STOPS[0], "sequence": 1}, headers=headers)
    assert resp.status_code == 201
    stops = resp.json()["stops"]
    assert [s["name"] for s in stops] == ["S1", "S2", "S3", "S4"] and [s["sequence"] for s in stops] == [1, 2, 3, 4]
    assert len(fake_routes.calls) == 2 and fake_routes.calls[-1] == CAMPUS

    # Renaming does not call the Routes API; moving does.
    s4 = stops[3]["id"]
    resp = await client.patch(f"/api/v1/admin/stops/{s4}", json={"name": "Hostel"}, headers=headers)
    assert resp.status_code == 200 and resp.json()["stops"][3]["name"] == "Hostel" and len(fake_routes.calls) == 2
    resp = await client.patch(f"/api/v1/admin/stops/{s4}", json={"sequence": 2}, headers=headers)
    assert [s["name"] for s in resp.json()["stops"]] == ["S1", "Hostel", "S2", "S3"] and len(fake_routes.calls) == 3

    # Remove (soft delete) and restore at the end.
    resp = await client.patch(f"/api/v1/admin/stops/{s4}", json={"active": False}, headers=headers)
    assert [s["sequence"] for s in resp.json()["stops"]] == [1, 2, 3] and len(fake_routes.calls) == 4
    resp = await client.patch(f"/api/v1/admin/stops/{s4}", json={"name": "Gone"}, headers=headers)
    assert resp.status_code == 404
    resp = await client.patch(f"/api/v1/admin/stops/{s4}", json={"active": True}, headers=headers)
    assert [s["name"] for s in resp.json()["stops"]] == ["S1", "S2", "S3", "Hostel"]


async def test_stop_limits_and_validation(client, admin, fake_routes, config_overrides):
    _, headers = await admin()
    rid = (await client.post("/api/v1/admin/routes", json={"name": "R", "stops": STOPS}, headers=headers)).json()["id"]
    resp = await client.post(f"/api/v1/admin/routes/{rid}/stops", json={"name": "x", "lat": 95, "lng": 0},
                             headers=headers)
    assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"
    many = [{"name": f"S{i}", "lat": 34 + i / 1000, "lng": 74.8} for i in range(28)]
    resp = await client.post("/api/v1/admin/routes", json={"name": "Long", "stops": many}, headers=headers)
    assert resp.status_code == 400 and "27" in resp.json()["error"]["message"]


async def test_tc17_u6_route_and_stop_in_use(client, admin, fake_routes, con, create_user, create_bus):
    _, headers = await admin()
    rid = await insert_route(con)
    driver = await create_user("driver", phone="+919000000101")
    bus = await create_bus(driver)
    await con.execute("update public.buses set default_route_id = $2 where id = $1", bus, rid)
    trip = await insert_trip(con, bus_id=bus, driver_id=driver, route_id=rid,
                             started_at=datetime.now(UTC) - timedelta(hours=1))
    stop_ids = [r["id"] for r in await con.fetch("select id from public.stops where route_id = $1 order by sequence",
                                                 rid)]

    resp = await client.patch(f"/api/v1/admin/routes/{rid}", json={"active": False}, headers=headers)
    assert resp.status_code == 409 and err(resp) == "IN_USE"
    resp = await client.patch(f"/api/v1/admin/stops/{stop_ids[1]}", json={"active": False}, headers=headers)
    assert resp.status_code == 409 and err(resp) == "IN_USE"
    assert await con.fetchval("select active from public.routes where id = $1", rid) is True

    # Edits are allowed, apply from the next trip, and warn the admin.
    resp = await client.patch(f"/api/v1/admin/stops/{stop_ids[1]}", json={"lat": 34.1279}, headers=headers)
    assert resp.status_code == 200 and resp.json()["warning"]
    resp = await client.patch(f"/api/v1/admin/routes/{rid}", json={"name": "Renamed"}, headers=headers)
    assert resp.status_code == 200 and resp.json()["warning"] and resp.json()["name"] == "Renamed"
    assert await con.fetchval("select route_id from public.trips where id = $1", trip) == rid

    # After the trip ends the route can be removed; buses lose it as their default.
    await con.execute("update public.trips set ended_at = now(), closed_by = 'driver' where id = $1", trip)
    resp = await client.patch(f"/api/v1/admin/routes/{rid}", json={"active": False}, headers=headers)
    assert resp.status_code == 200 and resp.json()["active"] is False and resp.json()["warning"] is None
    assert await con.fetchval("select default_route_id from public.buses where id = $1", bus) is None
    assert (await client.get(f"/api/v1/routes/{rid}", headers=headers)).status_code == 404
    admin_list = (await client.get("/api/v1/admin/routes", headers=headers)).json()["items"]
    assert [(r["id"], r["active"]) for r in admin_list] == [(str(rid), False)]


async def test_non_admin_is_forbidden(client, google_login, fake_routes):
    student = bearer((await google_login("stu", "s@gmail.com"))["access_token"])
    for method, path in (("get", "/api/v1/admin/routes"), ("post", "/api/v1/admin/routes"),
                         ("get", "/api/v1/admin/buses"), ("get", "/api/v1/admin/trips"),
                         ("get", "/api/v1/admin/settings"), ("get", "/api/v1/admin/admins")):
        resp = await client.request(method, path, json={"name": "x"}, headers=student)
        assert resp.status_code == 403 and err(resp) == "FORBIDDEN_ROLE", path
    assert (await client.get("/api/v1/routes")).status_code == 401
    assert (await client.get("/api/v1/routes", headers=student)).status_code == 200
