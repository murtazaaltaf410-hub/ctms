"""Admin drivers (PRD A1): one driver per bus, relink audit (U8), deactivation revokes sessions (U3)."""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from uuid import UUID

from tests.admin_helpers import admin, err, insert_route, insert_trip  # noqa: F401
from tests.conftest import bearer


async def test_create_driver_linked_to_bus(client, admin, con, create_bus):
    _, headers = await admin()
    bus = await create_bus()
    resp = await client.post(
        "/api/v1/admin/drivers", json={"name": "Rafiq", "phone": "+91 90000 00301", "bus_id": str(bus)}, headers=headers
    )
    assert resp.status_code == 201, resp.text
    driver = resp.json()
    assert driver["phone"] == "+919000000301" and driver["bus_id"] == str(bus) and driver["active"] is True
    assert await con.fetchval("select driver_id from public.buses where id = $1", bus) == UUID(driver["id"])
    listed = (await client.get("/api/v1/admin/drivers", headers=headers)).json()["items"]
    assert [d["id"] for d in listed] == [driver["id"]]


async def test_driver_validation(client, admin, create_bus):
    _, headers = await admin()
    resp = await client.post("/api/v1/admin/drivers", json={"name": "X", "phone": "12345"}, headers=headers)
    assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"
    ok = {"name": "A", "phone": "+919000000302"}
    assert (await client.post("/api/v1/admin/drivers", json=ok, headers=headers)).status_code == 201
    resp = await client.post("/api/v1/admin/drivers", json={**ok, "name": "B"}, headers=headers)
    assert resp.status_code == 400 and "phone" in resp.json()["error"]["message"]
    resp = await client.post(
        "/api/v1/admin/drivers",
        json={"name": "C", "phone": "+919000000303", "bus_id": "00000000-0000-4000-8000-000000000000"},
        headers=headers,
    )
    assert resp.status_code == 400 and "bus_id" in resp.json()["error"]["message"]


async def test_u8_substitute_relink_is_audited_and_trips_keep_actual_driver(client, admin, con, create_bus):
    actor, headers = await admin()
    bus = await create_bus()
    first = (
        await client.post(
            "/api/v1/admin/drivers",
            json={"name": "Regular", "phone": "+919000000311", "bus_id": str(bus)},
            headers=headers,
        )
    ).json()
    rid = await insert_route(con)
    started = datetime.now(UTC) - timedelta(hours=2)
    await insert_trip(
        con,
        bus_id=bus,
        driver_id=UUID(first["id"]),
        route_id=rid,
        started_at=started,
        ended_at=started + timedelta(minutes=30),
        distance_m=5000,
    )

    sub = (
        await client.post(
            "/api/v1/admin/drivers", json={"name": "Substitute", "phone": "+919000000312"}, headers=headers
        )
    ).json()
    resp = await client.patch(f"/api/v1/admin/drivers/{sub['id']}", json={"bus_id": str(bus)}, headers=headers)
    assert resp.status_code == 200 and resp.json()["bus_id"] == str(bus)
    assert await con.fetchval("select driver_id from public.buses where id = $1", bus) == UUID(sub["id"])
    first_now = next(
        d
        for d in (await client.get("/api/v1/admin/drivers", headers=headers)).json()["items"]
        if d["id"] == first["id"]
    )
    assert first_now["bus_id"] is None

    relinks = await con.fetch(
        "select actor_id, meta from public.audit_log where action = 'bus.driver_relink' order by id"
    )
    assert len(relinks) == 2 and relinks[-1]["actor_id"] == actor
    assert relinks[-1]["meta"] == {
        "driver_id": sub["id"],
        "from_bus_id": None,
        "to_bus_id": str(bus),
        "replaced_driver_id": first["id"],
    }

    await insert_trip(
        con,
        bus_id=bus,
        driver_id=UUID(sub["id"]),
        route_id=rid,
        started_at=started + timedelta(hours=1),
        ended_at=started + timedelta(hours=1, minutes=20),
    )
    trips = (await client.get("/api/v1/admin/trips", headers=headers)).json()["items"]
    assert [t["driver_name"] for t in trips] == ["Substitute", "Regular"]

    # Audit meta never carries phones, emails or names.
    for row in await con.fetch("select meta from public.audit_log"):
        text = json.dumps(row["meta"])
        assert "+91" not in text and "@" not in text and "Regular" not in text


async def test_u3_deactivate_driver_revokes_sessions_and_frees_phone(client, admin, con, create_bus, driver_login):
    _, headers = await admin()
    bus = await create_bus()
    driver = (
        await client.post(
            "/api/v1/admin/drivers", json={"name": "Old", "phone": "+919000000321", "bus_id": str(bus)}, headers=headers
        )
    ).json()
    tokens = await driver_login("+919000000321")
    driver_headers = bearer(tokens["access_token"])
    assert (await client.get("/api/v1/me", headers=driver_headers)).status_code == 200

    resp = await client.patch(f"/api/v1/admin/drivers/{driver['id']}", json={"active": False}, headers=headers)
    assert resp.status_code == 200 and resp.json()["active"] is False and resp.json()["bus_id"] is None
    resp = await client.get("/api/v1/me", headers=driver_headers)
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"
    reasons = await con.fetch("select revoked_reason from public.sessions where user_id = $1", UUID(driver["id"]))
    assert [r["revoked_reason"] for r in reasons] == ["deactivated"]
    resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert resp.status_code == 401

    # The replacement driver can reuse the number and take the bus (U3).
    resp = await client.post(
        "/api/v1/admin/drivers", json={"name": "New", "phone": "+919000000321", "bus_id": str(bus)}, headers=headers
    )
    assert resp.status_code == 201 and resp.json()["bus_id"] == str(bus)
    # Reactivating the old driver now clashes with the active number.
    resp = await client.patch(f"/api/v1/admin/drivers/{driver['id']}", json={"active": True}, headers=headers)
    assert resp.status_code == 400 and "phone" in resp.json()["error"]["message"]


async def test_phone_change_revokes_sessions(client, admin, con, driver_login):
    _, headers = await admin()
    driver = (
        await client.post("/api/v1/admin/drivers", json={"name": "D", "phone": "+919000000331"}, headers=headers)
    ).json()
    tokens = await driver_login("+919000000331")
    resp = await client.patch(f"/api/v1/admin/drivers/{driver['id']}", json={"phone": "+919000000332"}, headers=headers)
    assert resp.status_code == 200 and resp.json()["phone"] == "+919000000332"
    assert (await client.get("/api/v1/me", headers=bearer(tokens["access_token"]))).status_code == 401
    resp = await client.patch(f"/api/v1/admin/drivers/{driver['id']}", json={"name": "Renamed"}, headers=headers)
    assert resp.status_code == 200
