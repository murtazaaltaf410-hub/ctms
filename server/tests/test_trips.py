"""Trip lifecycle: start (TC5/T10), schedule classification, status, end summary."""

from __future__ import annotations

from datetime import time, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

import pytest

from app.live.hub import get_hub
from app.live.state import get_live
from app.modules.trips import service as trip_service
from tests.conftest import bearer
from tests.tracking_support import FakeWS, along_fix

pytest_plugins = ["tests.tracking_support"]


def watch(app) -> FakeWS:
    ws = FakeWS(app)
    get_hub(app).add(ws, uuid4(), uuid4())
    return ws


async def test_start_uses_default_route_and_is_ad_hoc(client, live_app, driver_with_bus, hook_log):
    driver = await driver_with_bus()
    ws = watch(live_app)
    resp = await client.post("/api/v1/trips/start", json={}, headers=driver["headers"])
    assert resp.status_code == 201, resp.text
    trip = resp.json()
    assert trip["route_id"] == str(driver["route"]["id"]) and trip["bus_id"] == str(driver["bus_id"])
    assert trip["type"] == "ad_hoc" and trip["schedule_id"] is None and trip["status"] == "on_time"
    assert trip["started_at"].endswith("Z") and trip["ended_at"] is None
    assert ws.sent == [{"type": "trip_started", "bus_id": trip["bus_id"], "trip_id": trip["id"]}]
    assert [e.kind for e in hook_log["trip"]] == ["started"]
    active = await client.get("/api/v1/trips/active", headers=driver["headers"])
    assert active.json()["id"] == trip["id"]


async def test_start_with_explicit_route(client, con, live_app, driver_with_bus, make_route):
    other = await make_route(name="Other")
    driver = await driver_with_bus()
    resp = await client.post("/api/v1/trips/start", json={"route_id": str(other["id"])}, headers=driver["headers"])
    assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR"
    await con.execute(
        "insert into public.driver_route_assignments (driver_id, route_id) values ($1, $2)",
        driver["driver_id"], other["id"],
    )
    resp = await client.post("/api/v1/trips/start", json={"route_id": str(other["id"])}, headers=driver["headers"])
    assert resp.status_code == 201 and resp.json()["route_id"] == str(other["id"])


async def test_driver_lists_only_assigned_routes(client, con, live_app, driver_with_bus, make_route, google_login):
    first = await make_route(name="First")
    second = await make_route(name="Second")
    driver = await driver_with_bus(route=first)
    await con.execute(
        "insert into public.driver_route_assignments (driver_id, route_id) values ($1, $2)",
        driver["driver_id"], second["id"],
    )

    resp = await client.get("/api/v1/routes/assigned", headers=driver["headers"])
    assert resp.status_code == 200, resp.text
    assert {route["id"] for route in resp.json()["items"]} == {str(first["id"]), str(second["id"])}

    student = await google_login("assigned-student", "assigned@student.test")
    forbidden = await client.get("/api/v1/routes/assigned", headers=bearer(student["access_token"]))
    assert forbidden.status_code == 403 and forbidden.json()["error"]["code"] == "FORBIDDEN_ROLE"


@pytest.mark.parametrize(
    "change",
    [
        "update public.routes set status = 'draft' where id = $1",
        "update public.routes set active = false where id = $1",
    ],
)
async def test_start_refuses_draft_or_inactive_route(client, con, live_app, driver_with_bus, make_route, change):
    driver = await driver_with_bus()
    other = await make_route(name="Other")
    await con.execute(change, other["id"])
    resp = await client.post("/api/v1/trips/start", json={"route_id": str(other["id"])}, headers=driver["headers"])
    assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR"
    # The same route as the bus default is ignored: no usable route -> 400, no trip.
    await con.execute(change, driver["route"]["id"])
    resp = await client.post("/api/v1/trips/start", json={}, headers=driver["headers"])
    assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR"
    assert await con.fetchval("select count(*) from public.trips where bus_id = $1", driver["bus_id"]) == 0


async def test_active_is_null_without_trip(client, live_app, driver_with_bus):
    driver = await driver_with_bus()
    resp = await client.get("/api/v1/trips/active", headers=driver["headers"])
    assert resp.status_code == 200 and resp.json() is None


async def test_scheduled_when_near_a_timetable_slot(client, con, live_app, driver_with_bus, fake_clock):
    driver = await driver_with_bus()
    local = (fake_clock.current + timedelta(minutes=5)).astimezone(ZoneInfo("Asia/Kolkata"))
    schedule_id = await con.fetchval(
        "insert into public.schedules (route_id, departure_time, days_of_week) values ($1, $2, $3) returning id",
        driver["route"]["id"],
        time(local.hour, local.minute),
        [local.isoweekday()],
    )
    trip = (await client.post("/api/v1/trips/start", json={}, headers=driver["headers"])).json()
    assert trip["type"] == "scheduled" and trip["schedule_id"] == str(schedule_id)
    assert trip["scheduled_departure"].endswith("Z")


async def test_far_from_slot_is_ad_hoc(client, con, live_app, driver_with_bus, fake_clock):
    driver = await driver_with_bus()
    local = (fake_clock.current + timedelta(hours=3)).astimezone(ZoneInfo("Asia/Kolkata"))
    await con.execute(
        "insert into public.schedules (route_id, departure_time, days_of_week) values ($1, $2, $3)",
        driver["route"]["id"],
        time(local.hour, local.minute),
        [1, 2, 3, 4, 5, 6, 7],
    )
    resp = await client.post("/api/v1/trips/start", json={}, headers=driver["headers"])
    assert resp.json()["type"] == "ad_hoc"


async def test_tc5_second_start_is_409(client, live_app, driver_with_bus, start_trip):
    driver = await driver_with_bus()
    await start_trip(driver)
    resp = await client.post("/api/v1/trips/start", json={}, headers=driver["headers"])
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "TRIP_ALREADY_ACTIVE"


async def test_tc5_concurrent_start_hits_unique_index(client, con, live_app, driver_with_bus, monkeypatch):
    """A competing start that lands between the pre-check and the insert still gives 409."""
    driver = await driver_with_bus()
    real_classify = trip_service._classify

    async def racing_classify(app, c, route_id, started_at, direction):
        await con.execute(
            "insert into public.trips (bus_id, driver_id, route_id, type) values ($1, $2, $3, 'ad_hoc')",
            driver["bus_id"],
            driver["driver_id"],
            route_id,
        )
        return await real_classify(app, c, route_id, started_at, direction)

    monkeypatch.setattr(trip_service, "_classify", racing_classify)
    resp = await client.post("/api/v1/trips/start", json={}, headers=driver["headers"])
    assert resp.status_code == 409 and resp.json()["error"]["code"] == "TRIP_ALREADY_ACTIVE"


async def test_start_requires_driver_role_and_linked_bus(client, live_app, google_login, create_user, driver_login):
    student = await google_login()
    resp = await client.post("/api/v1/trips/start", json={}, headers=bearer(student["access_token"]))
    assert resp.status_code == 403 and resp.json()["error"]["code"] == "FORBIDDEN_ROLE"
    await create_user("driver", phone="+919811111111")
    tokens = await driver_login("+919811111111")
    resp = await client.post("/api/v1/trips/start", json={}, headers=bearer(tokens["access_token"]))
    assert resp.status_code == 404


async def test_status_update_broadcasts_and_validates(client, con, live_app, driver_with_bus, start_trip, hook_log):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    ws = watch(live_app)
    resp = await client.post(
        f"/api/v1/trips/{trip['id']}/status", json={"status": "delayed", "note": "Traffic"}, headers=driver["headers"]
    )
    assert resp.status_code == 204
    assert ws.sent == [{"type": "bus_status", "bus_id": trip["bus_id"], "status": "delayed", "note": "Traffic"}]
    assert hook_log["trip"][-1].kind == "status"
    row = await con.fetchrow("select status, note from public.trips where id = $1", trip["id"])
    assert (row["status"], row["note"]) == ("delayed", "Traffic")
    bad = await client.post(f"/api/v1/trips/{trip['id']}/status", json={"status": "late"}, headers=driver["headers"])
    assert bad.status_code == 400
    long_note = await client.post(
        f"/api/v1/trips/{trip['id']}/status", json={"status": "delayed", "note": "x" * 141}, headers=driver["headers"]
    )
    assert long_note.status_code == 400 and long_note.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_not_your_trip_is_403(client, live_app, driver_with_bus, start_trip, post_fixes, fake_clock):
    owner = await driver_with_bus()
    other = await driver_with_bus()
    trip = await start_trip(owner)
    for path, body in (("status", {"status": "delayed"}), ("end", None)):
        resp = await client.post(f"/api/v1/trips/{trip['id']}/{path}", json=body, headers=other["headers"])
        assert resp.status_code == 403 and resp.json()["error"]["code"] == "NOT_YOUR_TRIP"
    body = await post_fixes(other, trip["id"], [along_fix(10, fake_clock.current)], expect=403)
    assert body["error"]["code"] == "NOT_YOUR_TRIP"


async def test_end_returns_summary_and_rejects_later_writes(
    client, con, live_app, driver_with_bus, start_trip, post_fixes, fake_clock, hook_log
):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    t0 = fake_clock.current
    await post_fixes(
        driver, trip["id"], [along_fix(100 * i, t0 + timedelta(seconds=10 * i), speed=10) for i in range(5)]
    )
    fake_clock.advance(60)
    ws = watch(live_app)
    resp = await client.post(f"/api/v1/trips/{trip['id']}/end", headers=driver["headers"])
    assert resp.status_code == 200, resp.text
    summary = resp.json()
    assert summary["distance_m"] == pytest.approx(400, abs=2)
    assert summary["closed_by"] == "driver" and summary["ended_at"].endswith("Z")
    assert summary["started_at"] == trip["started_at"] and summary["duration_s"] == pytest.approx(60, abs=1)
    assert ws.sent == [{"type": "trip_ended", "bus_id": trip["bus_id"], "trip_id": trip["id"]}]
    assert hook_log["trip"][-1].kind == "ended"
    assert get_live(live_app).by_trip(trip["id"]) is None
    assert await con.fetchval("select count(*) from public.locations where trip_id = $1", trip["id"]) == 5
    again = await client.post(f"/api/v1/trips/{trip['id']}/end", headers=driver["headers"])
    assert again.status_code == 200 and again.json()["ended_at"] == summary["ended_at"]
    late = await post_fixes(driver, trip["id"], [along_fix(500, fake_clock.current)], expect=404)
    assert late["error"]["code"] == "NOT_FOUND"
    status = await client.post(
        f"/api/v1/trips/{trip['id']}/status", json={"status": "delayed"}, headers=driver["headers"]
    )
    assert status.status_code == 404
    # A new trip may start once the old one is closed.
    assert (await client.post("/api/v1/trips/start", json={}, headers=driver["headers"])).status_code == 201
