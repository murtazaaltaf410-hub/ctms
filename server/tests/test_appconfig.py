"""GET /api/v1/config: public, min app version, thresholds from the settings table, works without a DB."""

from __future__ import annotations

import json

import httpx
import pytest

from app.main import create_app
from tests.conftest import make_config


async def test_config_is_public_with_defaults(client):
    resp = await client.get("/api/v1/config")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["min_app_version"] == "1.0.0"
    assert body["app_update_url"] is None
    assert body["alert_radius_m"] == 500
    assert body["stale_after_s"] == 30 and body["offline_after_s"] == 120
    assert body["location_batch_max"] == 20
    assert body["timezone"] == "Asia/Kolkata"
    assert body["env"] == "test"
    assert body["student_fix_max_age_s"] == 300
    assert body["server_time"].endswith("Z")
    assert resp.headers["cache-control"] == "public, max-age=60"


@pytest.mark.parametrize(
    "config_overrides", [{"min_app_version": "1.4.2", "app_update_url": "https://example.org/ctms.apk"}]
)
async def test_config_env_overrides(client):
    body = (await client.get("/api/v1/config")).json()
    assert body["min_app_version"] == "1.4.2"
    assert body["app_update_url"] == "https://example.org/ctms.apk"


async def test_config_settings_table_wins(client, app, con):
    await con.execute(
        """insert into public.settings (key, value) values ('alert_radius_m', $1), ('min_app_version', $2)
           on conflict (key) do update set value = excluded.value""",
        750,
        "2.0.0",
    )
    await app.state.settings_store.refresh(con)  # tests have no pool; prime the cache from the test tx
    body = (await client.get("/api/v1/config")).json()
    assert body["alert_radius_m"] == 750
    assert body["min_app_version"] == "2.0.0"
    assert json.dumps(body)  # serialisable


async def test_config_works_without_database():
    app = create_app(make_config())  # no lifespan -> no pool: the refresh fails quietly
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as ac:
        resp = await ac.get("/api/v1/config")
    assert resp.status_code == 200
    assert resp.json()["alert_radius_m"] == 500
    assert resp.json()["student_fix_max_age_s"] == 300


@pytest.mark.parametrize("config_overrides", [{"student_fix_max_age_s": 120}])
async def test_config_student_fix_max_age_is_config_driven(client):
    body = (await client.get("/api/v1/config")).json()
    assert body["student_fix_max_age_s"] == 120


async def test_config_in_openapi(client):
    paths = (await client.get("/openapi.json")).json()["paths"]
    assert "/api/v1/config" in paths
