"""POST /me/location, PUT/GET /me/alert-settings, GET /me/alerts."""
# ruff: noqa: F811  (pytest fixtures imported from tests.alerts_support)

from __future__ import annotations

from datetime import timedelta

import pytest

from app import clock
from tests.alerts_support import engine, push, world  # noqa: F401
from tests.conftest import bearer
from tests.tracking_support import fake_clock  # noqa: F401


@pytest.fixture(autouse=True)
def _frozen(fake_clock):
    """Location age and clamping are judged on the frozen `app.clock`."""
    return fake_clock


@pytest.fixture
async def student_auth(google_login) -> tuple[str, dict]:
    body = await google_login(sub="p4-api", email="p4-api@uok.edu.in")
    return body["user"]["id"], bearer(body["access_token"])


def loc(lat=34.131, lng=74.837, accuracy=15.0, age_s=5.0, **extra) -> dict:
    return {
        "lat": lat,
        "lng": lng,
        "accuracy": accuracy,
        "recorded_at": (clock.now() - timedelta(seconds=age_s)).isoformat(),
        **extra,
    }


async def stored(con, user_id):
    return await con.fetchrow(
        "select lat, lng, accuracy_m, recorded_at from public.student_locations where user_id = $1::uuid", user_id
    )


async def test_location_stores_only_the_latest(client, con, student_auth):
    sid, auth = student_auth
    assert (await client.post("/api/v1/me/location", json=loc(lat=34.1), headers=auth)).status_code == 204
    resp = await client.post("/api/v1/me/location", json=loc(lat=34.2, age_s=1), headers=auth)
    assert resp.status_code == 204 and resp.content == b""
    # An older fix arriving late never overwrites a newer one.
    assert (await client.post("/api/v1/me/location", json=loc(lat=34.3, age_s=60), headers=auth)).status_code == 204
    assert await con.fetchval("select count(*) from public.student_locations where user_id = $1::uuid", sid) == 1
    assert (await stored(con, sid))["lat"] == pytest.approx(34.2)


@pytest.mark.parametrize(
    "kwargs, field",
    [
        ({"accuracy": 100}, "accuracy"),
        ({"age_s": 301}, "recorded_at"),
        ({"lat": 91}, "lat"),
        ({"lng": -181}, "lng"),
        ({"accuracy": -1}, "accuracy"),
        ({"recorded_at": "2026-11-08T10:00:00"}, "recorded_at"),  # no timezone
    ],
)
async def test_location_validation(client, con, student_auth, kwargs, field):
    sid, auth = student_auth
    body = loc(**kwargs)
    resp = await client.post("/api/v1/me/location", json=body, headers=auth)
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"
    assert field in resp.json()["error"]["message"]
    assert await stored(con, sid) is None


async def test_location_future_timestamp_is_clamped(client, con, student_auth, fake_clock):
    sid, auth = student_auth
    assert (await client.post("/api/v1/me/location", json=loc(age_s=-3600), headers=auth)).status_code == 204
    assert (await stored(con, sid))["recorded_at"] == fake_clock.current


async def test_location_age_limit_follows_the_app_clock(client, con, student_auth, fake_clock):
    _sid, auth = student_auth
    body = loc(age_s=0)
    fake_clock.advance(299)
    assert (await client.post("/api/v1/me/location", json=body, headers=auth)).status_code == 204
    fake_clock.advance(2)
    assert (await client.post("/api/v1/me/location", json=body, headers=auth)).status_code == 400


async def test_location_is_student_only(client, create_user, driver_login, con, google_login):
    await create_user("driver", name="D", phone="+919811100001")
    driver = await driver_login("+919811100001")
    resp = await client.post("/api/v1/me/location", json=loc(), headers=bearer(driver["access_token"]))
    assert resp.status_code == 403 and resp.json()["error"]["code"] == "FORBIDDEN_ROLE"
    assert (await client.post("/api/v1/me/location", json=loc())).status_code == 401


async def test_enabling_alerts_requires_a_push_token(client, con, student_auth):
    _sid, auth = student_auth
    resp = await client.put("/api/v1/me/alert-settings", json={"enabled": True}, headers=auth)
    assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR"
    assert "push token" in resp.json()["error"]["message"]
    assert (await client.get("/api/v1/me/alert-settings", headers=auth)).json() == {"enabled": False}

    await client.put("/api/v1/me/push-token", json={"token": "tok-api", "platform": "android"}, headers=auth)
    resp = await client.put("/api/v1/me/alert-settings", json={"enabled": True}, headers=auth)
    assert resp.status_code == 200 and resp.json() == {"enabled": True}
    assert (await client.get("/api/v1/me/alert-settings", headers=auth)).json() == {"enabled": True}


async def test_disabling_alerts_deletes_the_stored_location(client, con, student_auth):
    sid, auth = student_auth
    await client.post("/api/v1/me/location", json=loc(), headers=auth)
    resp = await client.put("/api/v1/me/alert-settings", json={"enabled": False}, headers=auth)
    assert resp.status_code == 200 and resp.json() == {"enabled": False}
    assert await stored(con, sid) is None


async def test_alert_settings_is_student_only(client, con, google_login):
    await con.execute("insert into public.admin_allowlist (email) values ('p4-adm2@uok.edu.in')")
    admin = await google_login(sub="p4-adm2", email="p4-adm2@uok.edu.in")
    resp = await client.put("/api/v1/me/alert-settings", json={"enabled": False}, headers=bearer(admin["access_token"]))
    assert resp.status_code == 403


async def test_sent_alerts_listed_for_in_app_display(app, client, con, student_auth, engine, push, world):
    _sid, auth = student_auth
    trip = await world()
    await client.put("/api/v1/me/push-token", json={"token": "tok-api2", "platform": "android"}, headers=auth)
    await client.put("/api/v1/me/alert-settings", json={"enabled": True}, headers=auth)
    await client.post("/api/v1/me/location", json=loc(lat=34.1310, lng=74.8370), headers=auth)
    for d in (600, 400):
        await engine.process(app, trip.fix(d))
    resp = await client.get("/api/v1/me/alerts", headers=auth)
    assert resp.status_code == 200
    items = resp.json()["items"]
    assert len(items) == 1
    assert items[0]["trip_id"] == str(trip.trip_id)
    assert items[0]["bus_label"] == "Bus 2" and items[0]["route_name"] == "North Campus"
    assert items[0]["sent_at"].endswith("Z")
