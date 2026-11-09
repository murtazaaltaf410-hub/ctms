"""Admin drivers (PRD A1, ADR-10): managed accounts with a one-time temporary password, profile fields,
one driver per bus, relink audit (U8), deactivation / identifier change / reset revoke sessions (U3)."""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

import json
import re
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
    tokens = await driver_login("+919000000321", driver["temporary_password"])
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
    tokens = await driver_login("+919000000331", driver["temporary_password"])
    resp = await client.patch(f"/api/v1/admin/drivers/{driver['id']}", json={"phone": "+919000000332"}, headers=headers)
    assert resp.status_code == 200 and resp.json()["phone"] == "+919000000332"
    assert (await client.get("/api/v1/me", headers=bearer(tokens["access_token"]))).status_code == 401
    assert (await driver_login("+919000000332", driver["temporary_password"]))["user"]["id"] == driver["id"]
    resp = await client.patch(f"/api/v1/admin/drivers/{driver['id']}", json={"name": "Renamed"}, headers=headers)
    assert resp.status_code == 200


# --- ADR-10: identifiers, profile, temporary passwords ----------------------------------------


async def test_create_with_userid_email_profile_and_one_time_password(client, admin, con, driver_login):
    _, headers = await admin()
    resp = await client.post(
        "/api/v1/admin/drivers",
        json={
            "name": "Full",
            "userid": "Full.Driver",
            "email": "Full@UoK.edu.in",
            "employee_id": "E-17",
            "licence_no": "JK-123",
            "licence_expiry": "2030-05-01",
            "address": "Nowgam",
            "emergency_name": "Sister",
            "emergency_phone": "+919000000999",
            "notes": "Prefers the morning shift",
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    created = resp.json()
    assert created["userid"] == "full.driver" and created["email"] == "full@uok.edu.in" and created["phone"] is None
    assert created["employee_id"] == "E-17" and created["licence_expiry"] == "2030-05-01"
    assert created["must_change_password"] is True and created["locked"] is False
    temp = created["temporary_password"]
    assert len(temp) >= 12 and re.search(r"\d", temp) and re.search(r"[A-Za-z]", temp)

    # Only the hash is stored; it is not the plain password and never comes back.
    stored = await con.fetchval("select password_hash from public.users where id = $1", UUID(created["id"]))
    assert stored.startswith("scrypt$") and temp not in stored
    listed = await client.get("/api/v1/admin/drivers", headers=headers)
    item = listed.json()["items"][0]
    assert "temporary_password" not in item and "password_hash" not in item
    for text in (listed.text, (await client.patch(f"/api/v1/admin/drivers/{created['id']}",
                                                  json={"notes": "x"}, headers=headers)).text):
        assert temp not in text and "scrypt" not in text

    # The temporary password signs in by userid or email, and forces a change.
    tokens = await driver_login("full.driver", temp)
    assert tokens["must_change_password"] is True
    assert (await driver_login("full@uok.edu.in", temp))["user"]["id"] == created["id"]
    meta = await con.fetchval("select meta from public.audit_log where action = 'driver.create'")
    assert temp not in json.dumps(meta) and "Full" not in json.dumps(meta)


async def test_create_requires_an_identifier_and_valid_formats(client, admin):
    _, headers = await admin()
    bad = [
        {"name": "NoId"},
        {"name": "X", "userid": "ab"},
        {"name": "X", "userid": "has space"},
        {"name": "X", "email": "not-an-email"},
        {"name": "X", "phone": "12345"},
    ]
    for body in bad:
        resp = await client.post("/api/v1/admin/drivers", json=body, headers=headers)
        assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR", body


async def test_duplicate_userid_email_phone_are_validation_errors(client, admin):
    _, headers = await admin()
    first = {"name": "A", "userid": "dup.one", "email": "dup@uok.edu.in", "phone": "+919000000401"}
    assert (await client.post("/api/v1/admin/drivers", json=first, headers=headers)).status_code == 201
    for field, value in (("userid", "dup.one"), ("email", "dup@uok.edu.in"), ("phone", "+919000000401")):
        other = {"name": "B", "userid": "dup.two", "email": "two@uok.edu.in", "phone": "+919000000402"}
        other[field] = value
        resp = await client.post("/api/v1/admin/drivers", json=other, headers=headers)
        assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR", field
        assert field in resp.json()["error"]["message"]


async def test_patch_profile_identifiers_and_keep_one_identifier(client, admin, con, driver_login):
    _, headers = await admin()
    d = (
        await client.post(
            "/api/v1/admin/drivers", json={"name": "P", "userid": "patch.me", "phone": "+919000000411"}, headers=headers
        )
    ).json()
    tokens = await driver_login("patch.me", d["temporary_password"])
    url = f"/api/v1/admin/drivers/{d['id']}"

    resp = await client.patch(url, json={"licence_no": "L-9", "address": "Srinagar"}, headers=headers)
    assert resp.status_code == 200 and resp.json()["licence_no"] == "L-9"
    assert (await client.get("/api/v1/me", headers=bearer(tokens["access_token"]))).status_code == 200  # no sign-out

    resp = await client.patch(url, json={"licence_no": None}, headers=headers)
    assert resp.json()["licence_no"] is None and resp.json()["address"] == "Srinagar"

    resp = await client.patch(url, json={"email": "patch@uok.edu.in"}, headers=headers)
    assert resp.status_code == 200 and resp.json()["email"] == "patch@uok.edu.in"
    assert (await client.get("/api/v1/me", headers=bearer(tokens["access_token"]))).status_code == 401  # id changed
    reasons = [r["revoked_reason"] for r in
               await con.fetch("select revoked_reason from public.sessions where user_id = $1", UUID(d["id"]))]
    assert reasons == ["identifier_changed"]

    # Removing identifiers is fine until none is left.
    assert (await client.patch(url, json={"userid": None, "phone": None}, headers=headers)).status_code == 200
    resp = await client.patch(url, json={"email": None}, headers=headers)
    assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"


async def test_reset_password_returns_new_one_once_unlocks_and_signs_out(client, admin, con, driver_login):
    actor, headers = await admin()
    d = (
        await client.post(
            "/api/v1/admin/drivers", json={"name": "R", "userid": "reset.me", "phone": "+919000000421"}, headers=headers
        )
    ).json()
    old = d["temporary_password"]
    tokens = await driver_login("reset.me", old)
    change = {"current_password": old, "new_password": "My-own-pass-1"}
    r = await client.post("/api/v1/auth/change-password", json=change, headers=bearer(tokens["access_token"]))
    assert r.status_code == 204
    for _ in range(5):  # lock the account
        await client.post("/api/v1/auth/login", json={"identifier": "reset.me", "password": "bad-password"})
    row = next(i for i in (await client.get("/api/v1/admin/drivers", headers=headers)).json()["items"])
    assert row["locked"] is True and row["must_change_password"] is False

    resp = await client.post(f"/api/v1/admin/drivers/{d['id']}/reset-password", headers=headers)
    assert resp.status_code == 200, resp.text
    new = resp.json()["temporary_password"]
    assert set(resp.json()) == {"temporary_password"} and new != old and len(new) >= 12

    row = next(i for i in (await client.get("/api/v1/admin/drivers", headers=headers)).json()["items"])
    assert row["locked"] is False and row["must_change_password"] is True
    assert "temporary_password" not in row
    assert (await client.get("/api/v1/me", headers=bearer(tokens["access_token"]))).status_code == 401
    assert await con.fetchval(
        "select revoked_reason from public.sessions where user_id = $1", UUID(d["id"])) == "password_reset"
    # Old password is dead, the new one works, and the account is no longer locked.
    bad = await client.post("/api/v1/auth/login", json={"identifier": "reset.me", "password": "My-own-pass-1"})
    assert bad.status_code == 401 and err(bad) == "INVALID_CREDENTIALS"
    fresh = await driver_login("reset.me", new)
    assert fresh["must_change_password"] is True
    audit = await con.fetchrow("select actor_id, meta from public.audit_log where action = 'driver.reset_password'")
    assert audit["actor_id"] == actor and new not in json.dumps(audit["meta"])


async def test_reset_password_unknown_driver_and_non_admin(client, admin, google_login, create_user):
    _, headers = await admin()
    resp = await client.post(
        "/api/v1/admin/drivers/00000000-0000-4000-8000-000000000000/reset-password", headers=headers
    )
    assert resp.status_code == 404 and err(resp) == "NOT_FOUND"
    student = await google_login("sub-s", "s@gmail.com")
    driver_id = await create_user("driver", phone="+919000000431")
    resp = await client.post(
        f"/api/v1/admin/drivers/{driver_id}/reset-password", headers=bearer(student["access_token"])
    )
    assert resp.status_code == 403 and err(resp) == "FORBIDDEN_ROLE"
