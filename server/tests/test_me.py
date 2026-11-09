"""/me: profile, push token, consents, and account deletion (TC20 / U2)."""

from __future__ import annotations

from datetime import UTC, datetime

from tests.conftest import bearer


def err(resp) -> str:
    return resp.json()["error"]["code"]


async def test_get_and_patch_me(client, google_login):
    tokens = await google_login(name="Before")
    headers = bearer(tokens["access_token"])
    me = (await client.get("/api/v1/me", headers=headers)).json()
    assert me["id"] == tokens["user"]["id"] and me["role"] == "student" and me["name"] == "Before"
    resp = await client.patch("/api/v1/me", json={"name": "  After  "}, headers=headers)
    assert resp.status_code == 200 and resp.json()["name"] == "After"
    resp = await client.patch("/api/v1/me", json={"name": ""}, headers=headers)
    assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"
    resp = await client.patch("/api/v1/me", json={"name": "x" * 121}, headers=headers)
    assert resp.status_code == 400


async def test_push_token_upsert_moves_between_accounts(client, google_login, con):
    a = await google_login("sub-a", "a@gmail.com")
    b = await google_login("sub-b", "b@gmail.com")
    body = {"token": "fcm-shared", "platform": "android"}
    assert (await client.put("/api/v1/me/push-token", json=body, headers=bearer(a["access_token"]))).status_code == 204
    assert (await client.put("/api/v1/me/push-token", json=body, headers=bearer(b["access_token"]))).status_code == 204
    rows = await con.fetch("select user_id::text as u from public.push_tokens where token = 'fcm-shared'")
    assert [r["u"] for r in rows] == [b["user"]["id"]]
    resp = await client.put(
        "/api/v1/me/push-token", json={"token": "t", "platform": "web"}, headers=bearer(a["access_token"])
    )
    assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"


async def test_consent_recorded_once(client, google_login, con):
    headers = bearer((await google_login())["access_token"])
    body = {"kind": "student_location", "version": "2026-11"}
    for _ in range(2):
        assert (await client.put("/api/v1/me/consents", json=body, headers=headers)).status_code == 204
    assert await con.fetchval("select count(*) from public.consents") == 1


async def test_tc20_delete_student_removes_personal_data(client, google_login, con, create_user, create_bus):
    tokens = await google_login("sub-del", "leaving@gmail.com", "Leaving")
    uid = tokens["user"]["id"]
    headers = bearer(tokens["access_token"])
    await client.put("/api/v1/me/push-token", json={"token": "fcm-del", "platform": "android"}, headers=headers)
    await client.put("/api/v1/me/consents", json={"kind": "student_location", "version": "1"}, headers=headers)
    # Alert-mode data (owned by P4) inserted directly: latest location, alert setting, one alert sent.
    now = datetime.now(UTC)
    await con.execute(
        "insert into public.student_locations (user_id, lat, lng, accuracy_m, recorded_at) "
        "values ($1, 34.13, 74.84, 10, $2)",
        uid,
        now,
    )
    await con.execute("insert into public.alert_settings (user_id, enabled) values ($1, true)", uid)
    driver = await create_user("driver", phone="+919000000009")
    bus = await create_bus(driver)
    route = await con.fetchval("insert into public.routes (name) values ('R') returning id")
    trip = await con.fetchval(
        "insert into public.trips (bus_id, driver_id, route_id, type) values ($1, $2, $3, 'ad_hoc') returning id",
        bus,
        driver,
        route,
    )
    await con.execute("insert into public.alert_log (student_id, trip_id) values ($1, $2)", uid, trip)
    await con.execute(
        "insert into public.audit_log (actor_id, action, meta) values ($1, 'x', '{\"name\": \"L\"}')", uid
    )

    assert await con.fetchval("select count(*) from public.student_profiles where user_id = $1", uid) == 1
    resp = await client.delete("/api/v1/me", headers=headers)
    assert resp.status_code == 204

    for table, col in (
        ("users", "id"),
        ("sessions", "user_id"),
        ("push_tokens", "user_id"),
        ("consents", "user_id"),
        ("student_locations", "user_id"),
        ("alert_settings", "user_id"),
        ("alert_log", "student_id"),
        ("student_profiles", "user_id"),  # ADR-10: the registration goes with the account
    ):
        assert await con.fetchval(f"select count(*) from public.{table} where {col} = $1", uid) == 0, table
    metas = await con.fetch(
        "select meta from public.audit_log where actor_id is null and (action = 'x' or target_id = $1)", uid
    )
    assert metas and all(r["meta"] == {} for r in metas)
    resp = await client.get("/api/v1/me", headers=headers)
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"


async def test_delete_me_is_student_only(client, create_user, driver_login, google_login, con):
    await con.execute("insert into public.admin_allowlist (email) values ('adm@uok.edu.in')")
    admin = await google_login("sub-adm", "adm@uok.edu.in")
    resp = await client.delete("/api/v1/me", headers=bearer(admin["access_token"]))
    assert resp.status_code == 403 and err(resp) == "FORBIDDEN_ROLE"
    await create_user("driver", phone="+919000000002")
    driver = await driver_login("+919000000002")
    resp = await client.delete("/api/v1/me", headers=bearer(driver["access_token"]))
    assert resp.status_code == 403 and err(resp) == "FORBIDDEN_ROLE"
