"""Admin buses (PRD A1): CRUD, pagination, IN_USE while a trip is active."""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from tests.admin_helpers import admin, err, insert_route, insert_trip  # noqa: F401


async def test_create_list_patch_bus(client, admin, con):
    actor, headers = await admin()
    rid = await insert_route(con)
    resp = await client.post(
        "/api/v1/admin/buses",
        json={"label": "Bus 7", "plate": "JK01AB1234", "default_route_id": str(rid)},
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    bus = resp.json()
    assert bus["active"] is True and bus["driver_id"] is None and bus["default_route_id"] == str(rid)
    assert bus["has_active_trip"] is False

    resp = await client.patch(
        f"/api/v1/admin/buses/{bus['id']}", json={"label": "Bus 8", "default_route_id": None}, headers=headers
    )
    assert resp.status_code == 200 and resp.json()["label"] == "Bus 8" and resp.json()["default_route_id"] is None

    audit = await con.fetch(
        "select action, actor_id, meta from public.audit_log where target_id = $1 order by id", bus["id"]
    )
    assert [(a["action"], a["actor_id"]) for a in audit] == [("bus.create", actor), ("bus.update", actor)]
    assert audit[1]["meta"] == {"fields": ["default_route_id", "label"]}


async def test_bus_validation(client, admin, con):
    _, headers = await admin()
    await client.post("/api/v1/admin/buses", json={"label": "A", "plate": "P1"}, headers=headers)
    resp = await client.post("/api/v1/admin/buses", json={"label": "B", "plate": "P1"}, headers=headers)
    assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR" and "plate" in resp.json()["error"]["message"]
    resp = await client.post("/api/v1/admin/buses", json={"label": "", "plate": "P2"}, headers=headers)
    assert resp.status_code == 400
    resp = await client.post(
        "/api/v1/admin/buses",
        json={"label": "C", "plate": "P3", "default_route_id": "00000000-0000-4000-8000-000000000000"},
        headers=headers,
    )
    assert resp.status_code == 400 and "default_route_id" in resp.json()["error"]["message"]
    resp = await client.patch(
        "/api/v1/admin/buses/00000000-0000-4000-8000-000000000000", json={"label": "x"}, headers=headers
    )
    assert resp.status_code == 404 and err(resp) == "NOT_FOUND"
    bus_id = (await client.get("/api/v1/admin/buses", headers=headers)).json()["items"][0]["id"]
    resp = await client.patch(f"/api/v1/admin/buses/{bus_id}", json={"active": None}, headers=headers)
    assert resp.status_code == 400


async def test_bus_list_pagination(client, admin):
    _, headers = await admin()
    for i in range(3):
        await client.post("/api/v1/admin/buses", json={"label": f"Bus {i}", "plate": f"PL{i}"}, headers=headers)
    seen, cursor = [], None
    while True:
        params = {"limit": 2} | ({"cursor": cursor} if cursor else {})
        page = (await client.get("/api/v1/admin/buses", params=params, headers=headers)).json()
        seen += [b["label"] for b in page["items"]]
        cursor = page["next_cursor"]
        if cursor is None:
            break
    # One transaction -> equal created_at, so the id breaks ties; every bus appears exactly once.
    assert sorted(seen) == ["Bus 0", "Bus 1", "Bus 2"]
    resp = await client.get("/api/v1/admin/buses", params={"cursor": "garbage!"}, headers=headers)
    assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"


async def test_deactivate_bus_with_active_trip_is_in_use(client, admin, con, create_user, create_bus):
    _, headers = await admin()
    rid = await insert_route(con)
    driver = await create_user("driver", phone="+919000000201")
    bus = await create_bus(driver)
    trip = await insert_trip(
        con, bus_id=bus, driver_id=driver, route_id=rid, started_at=datetime.now(UTC) - timedelta(minutes=10)
    )
    listed = (await client.get("/api/v1/admin/buses", headers=headers)).json()["items"][0]
    assert listed["has_active_trip"] is True and listed["driver_id"] == str(driver)
    resp = await client.patch(f"/api/v1/admin/buses/{bus}", json={"active": False}, headers=headers)
    assert resp.status_code == 409 and err(resp) == "IN_USE"
    assert await con.fetchval("select active from public.buses where id = $1", bus) is True
    resp = await client.patch(f"/api/v1/admin/buses/{bus}", json={"label": "Renamed"}, headers=headers)
    assert resp.status_code == 200

    await con.execute(
        "update public.trips set ended_at = started_at + interval '5 minutes', closed_by = 'driver' where id = $1", trip
    )
    resp = await client.patch(f"/api/v1/admin/buses/{bus}", json={"active": False}, headers=headers)
    assert resp.status_code == 200 and resp.json()["active"] is False
