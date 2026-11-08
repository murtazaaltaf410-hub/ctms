"""GET/PUT /admin/settings: alert_radius_m, validated, audited, settings cache invalidated."""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

from tests.admin_helpers import admin, err  # noqa: F401


async def test_get_and_put_alert_radius(app, client, admin, con):
    actor, headers = await admin()
    resp = await client.get("/api/v1/admin/settings", headers=headers)
    assert resp.status_code == 200 and resp.json() == {"alert_radius_m": 500}
    store = app.state.settings_store
    assert store.get_cached("alert_radius_m") == 500

    resp = await client.put("/api/v1/admin/settings", json={"alert_radius_m": 350}, headers=headers)
    assert resp.status_code == 200 and resp.json() == {"alert_radius_m": 350}
    assert store.get_cached("alert_radius_m") == 350  # cache refreshed after invalidate()
    row = await con.fetchrow("select value, updated_by from public.settings where key = 'alert_radius_m'")
    assert row["value"] == 350 and row["updated_by"] == actor
    audit = await con.fetchrow("select actor_id, meta from public.audit_log where action = 'settings.update'")
    assert audit["actor_id"] == actor and audit["meta"] == {"from": 500, "to": 350}
    assert (await client.get("/api/v1/admin/settings", headers=headers)).json() == {"alert_radius_m": 350}


async def test_alert_radius_validation(client, admin):
    _, headers = await admin()
    for bad in (0, 10, 100000, "far"):
        resp = await client.put("/api/v1/admin/settings", json={"alert_radius_m": bad}, headers=headers)
        assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR", bad
    resp = await client.put("/api/v1/admin/settings", json={}, headers=headers)
    assert resp.status_code == 400
