"""Admin management (PRD A7): LAST_ADMIN (U5, TC17), SEED_ADMIN_EMAIL, demotion revokes sessions, audit."""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

from uuid import UUID

import pytest

from tests.admin_helpers import admin, err  # noqa: F401
from tests.conftest import bearer


async def test_u5_last_admin_cannot_remove_self(client, admin, con):
    me, headers = await admin()
    resp = await client.delete(f"/api/v1/admin/admins/{me}", headers=headers)
    assert resp.status_code == 409 and err(resp) == "LAST_ADMIN"
    assert await con.fetchval("select role from public.users where id = $1", me) == "admin"
    # The seed placeholder allow-list row (no account) does not count as an admin.
    listed = (await client.get("/api/v1/admin/admins", headers=headers)).json()["items"]
    assert {i["email"] for i in listed} >= {"admin1@uok.edu.in"}


async def test_add_admin_then_remove_original(client, admin, con, google_login):
    first, headers = await admin()
    resp = await client.post("/api/v1/admin/admins", json={"email": "  New.Admin@UOK.edu.in "}, headers=headers)
    assert resp.status_code == 201, resp.text
    new = resp.json()
    assert new["email"] == "new.admin@uok.edu.in" and new["signed_in"] is False and new["seed"] is False
    assert await con.fetchval("select exists(select 1 from public.admin_allowlist where email = $1)", new["email"])

    # The new admin's first Google sign-in links the pre-created account.
    tokens = await google_login("new-sub", "new.admin@uok.edu.in", "New Admin")
    assert tokens["user"]["id"] == new["id"] and tokens["user"]["role"] == "admin"
    new_headers = bearer(tokens["access_token"])

    # Removing yourself is fine while you are not the last admin.
    assert (await client.delete(f"/api/v1/admin/admins/{first}", headers=headers)).status_code == 204
    assert await con.fetchval("select role from public.users where id = $1", first) == "student"
    assert not await con.fetchval("select exists(select 1 from public.admin_allowlist where email = $1)",
                                  "admin1@uok.edu.in")
    resp = await client.get("/api/v1/admin/admins", headers=headers)
    assert resp.status_code == 401  # sessions revoked on demotion
    assert {r["revoked_reason"] for r in await con.fetch(
        "select revoked_reason from public.sessions where user_id = $1", first)} == {"role_change"}

    # Now the new admin is the last one.
    resp = await client.delete(f"/api/v1/admin/admins/{new['id']}", headers=new_headers)
    assert resp.status_code == 409 and err(resp) == "LAST_ADMIN"

    changes = await con.fetch("select actor_id, target_id, meta from public.audit_log "
                              "where action = 'user.role_change' order by id")
    assert [(c["meta"]["from"], c["meta"]["to"]) for c in changes][-2:] == [(None, "admin"), ("admin", "student")]
    assert changes[-1]["actor_id"] == first and changes[-1]["meta"]["self"] is True


async def test_add_existing_student_promotes_and_rejects_drivers(client, admin, con, google_login, create_user):
    _, headers = await admin()
    student = await google_login("stu-1", "stu@gmail.com", "Stu")
    resp = await client.post("/api/v1/admin/admins", json={"email": "stu@gmail.com"}, headers=headers)
    assert resp.status_code == 201 and resp.json()["id"] == student["user"]["id"] and resp.json()["signed_in"]
    assert await con.fetchval("select role from public.users where id = $1", UUID(student["user"]["id"])) == "admin"
    # Their role is read from the DB on every request, so the existing token now works on admin routes.
    assert (await client.get("/api/v1/admin/admins", headers=bearer(student["access_token"]))).status_code == 200
    resp = await client.post("/api/v1/admin/admins", json={"email": "not-an-email"}, headers=headers)
    assert resp.status_code == 400
    resp = await client.delete("/api/v1/admin/admins/00000000-0000-4000-8000-000000000000", headers=headers)
    assert resp.status_code == 404


@pytest.mark.parametrize("config_overrides", [{"seed_admin_email": "seed@uok.edu.in"}])
async def test_seed_admin_always_counts(client, admin, con, google_login):
    me, headers = await admin()
    listed = (await client.get("/api/v1/admin/admins", headers=headers)).json()["items"]
    assert [i for i in listed if i["seed"]] == [{"id": None, "email": "seed@uok.edu.in", "name": "",
                                                 "signed_in": False, "seed": True, "created_at": None}]
    # The seed admin (configured in the env) still counts, so the only signed-in admin may leave.
    assert (await client.delete(f"/api/v1/admin/admins/{me}", headers=headers)).status_code == 204

    seed = await google_login("seed-sub", "seed@uok.edu.in", "Seed")
    resp = await client.delete(f"/api/v1/admin/admins/{seed['user']['id']}", headers=bearer(seed["access_token"]))
    assert resp.status_code == 400 and "SEED_ADMIN_EMAIL" in resp.json()["error"]["message"]
