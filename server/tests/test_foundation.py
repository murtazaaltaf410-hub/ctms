"""Foundation: health, error envelope, validation 400, DB 503, rate limiting, config, settings, hooks."""

from __future__ import annotations

import asyncio
from typing import Annotated

import httpx
import pytest
from fastapi import APIRouter, Depends

from app import jobs, live
from app.config import Settings
from app.db import get_conn
from app.deps import CurrentUser, require_role
from app.errors import ERROR_CLASSES, AppError, RateLimited
from app.main import create_app
from app.ratelimit import RateLimiter
from app.settings_store import SettingsStore
from tests.conftest import make_config

SPEC_CODES = {
    "VALIDATION_ERROR": 400,
    "OTP_INVALID": 400,
    "OTP_EXPIRED": 400,
    "TOKEN_EXPIRED": 401,
    "TOKEN_INVALID": 401,
    "SESSION_REPLACED": 401,
    "FORBIDDEN_ROLE": 403,
    "NOT_YOUR_TRIP": 403,
    "NOT_FOUND": 404,
    "TRIP_ALREADY_ACTIVE": 409,
    "LAST_ADMIN": 409,
    "IN_USE": 409,
    "POLYLINE_FAILED": 422,
    "RATE_LIMITED": 429,
    "DB_UNAVAILABLE": 503,
}


async def test_health_reports_db(client):
    resp = await client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok" and body["db"] == "ok"
    assert body["time"].endswith("Z")
    assert (await client.get("/api/v1/health")).status_code == 200


async def test_health_db_unavailable_without_pool(config):
    app = create_app(config)  # lifespan not run: no pool
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as ac:
        resp = await ac.get("/health")
    assert resp.status_code == 503
    assert resp.json() == {"error": {"code": "DB_UNAVAILABLE", "message": "Database temporarily unavailable; retry"}}


async def test_connection_lost_mid_request_is_503(config):
    class Broken:
        async def fetchval(self, *args):
            raise ConnectionResetError("connection lost")

    app = create_app(config)

    async def broken_conn():
        yield Broken()

    app.dependency_overrides[get_conn] = broken_conn
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as ac:
        resp = await ac.get("/health")
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "DB_UNAVAILABLE"


async def test_openapi_and_docs(client):
    assert (await client.get("/docs")).status_code == 200
    spec = (await client.get("/openapi.json")).json()
    for path in (
        "/api/v1/auth/google",
        "/api/v1/auth/phone/request",
        "/api/v1/auth/phone/verify",
        "/api/v1/auth/refresh",
        "/api/v1/auth/logout",
        "/api/v1/me",
        "/api/v1/me/push-token",
    ):
        assert path in spec["paths"], path


def test_every_spec_error_code_exists():
    assert {cls.code: cls.status_code for cls in ERROR_CLASSES} == SPEC_CODES


@pytest.mark.parametrize("cls", ERROR_CLASSES, ids=lambda c: c.code)
async def test_error_envelope(config, cls):
    app = create_app(config)
    router = APIRouter()

    @router.get("/boom")
    async def boom():
        raise cls(7) if cls is RateLimited else cls()

    app.include_router(router)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as ac:
        resp = await ac.get("/boom")
    assert resp.status_code == cls.status_code
    assert resp.json() == {"error": {"code": cls.code, "message": cls.message}}
    if cls is RateLimited:
        assert resp.headers["Retry-After"] == "7"


async def test_unknown_route_is_not_found_envelope(client):
    resp = await client.get("/api/v1/nope")
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


async def test_unexpected_error_hides_details(config):
    app = create_app(config)

    @app.get("/crash")
    async def crash():
        raise RuntimeError("secret detail")

    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport, base_url="http://t") as ac:
        resp = await ac.get("/crash")
    assert resp.status_code == 500
    assert "secret" not in resp.text
    assert resp.json()["error"]["code"] == "INTERNAL_ERROR"


@pytest.mark.parametrize("body", [{}, {"id_token": ""}, {"id_token": 5}, None])
async def test_validation_error_is_400(client, body):
    resp = await client.post("/api/v1/auth/google", json=body)
    assert resp.status_code == 400
    err = resp.json()["error"]
    assert err["code"] == "VALIDATION_ERROR" and err["message"]


async def test_bad_phone_is_400(client):
    resp = await client.post("/api/v1/auth/phone/request", json={"phone": "98765"})
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"
    assert "phone" in resp.json()["error"]["message"]


@pytest.mark.parametrize("config_overrides", [{"rate_general_per_ip": 2}])
async def test_general_ip_rate_limit_429_shape(client):
    for _ in range(2):
        assert (await client.post("/api/v1/auth/refresh", json={"refresh_token": "x"})).status_code == 401
    resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": "x"})
    assert resp.status_code == 429
    assert resp.json()["error"]["code"] == "RATE_LIMITED"
    assert 1 <= int(resp.headers["Retry-After"]) <= 60


@pytest.mark.parametrize("config_overrides", [{"rate_general_per_user": 2}])
async def test_per_user_rate_limit(client, google_login):
    access = (await google_login())["access_token"]
    headers = {"Authorization": f"Bearer {access}"}
    assert (await client.get("/api/v1/me", headers=headers)).status_code == 200
    assert (await client.get("/api/v1/me", headers=headers)).status_code == 200
    resp = await client.get("/api/v1/me", headers=headers)
    assert resp.status_code == 429 and "Retry-After" in resp.headers


@pytest.mark.parametrize("config_overrides", [{"trust_proxy": True, "rate_general_per_ip": 1}])
async def test_forwarded_for_used_behind_proxy(client):
    h1 = {"X-Forwarded-For": "203.0.113.5, 10.0.0.1"}
    h2 = {"X-Forwarded-For": "203.0.113.6"}
    assert (await client.post("/api/v1/auth/refresh", json={"refresh_token": "x"}, headers=h1)).status_code == 401
    assert (await client.post("/api/v1/auth/refresh", json={"refresh_token": "x"}, headers=h2)).status_code == 401
    assert (await client.post("/api/v1/auth/refresh", json={"refresh_token": "x"}, headers=h1)).status_code == 429


async def test_rate_limiter_sliding_window():
    now = [1000.0]
    limiter = RateLimiter(clock=lambda: now[0])
    await limiter.hit("b", "k", 2, 10)
    now[0] += 4
    await limiter.hit("b", "k", 2, 10)
    with pytest.raises(RateLimited) as exc:
        await limiter.hit("b", "k", 2, 10)
    assert exc.value.retry_after == 6
    await limiter.hit("b", "other", 2, 10)  # keys are independent
    now[0] += 6.01
    await limiter.hit("b", "k", 2, 10)  # oldest hit left the window


def test_config_fail_fast_outside_dev():
    with pytest.raises(ValueError, match="JWT_SECRET"):
        Settings(_env_file=None, app_env="production")
    good = {
        "app_env": "production",
        "database_url": "postgresql://u:p@db:5432/x",
        "jwt_secret": "s" * 40,
        "google_oauth_client_ids": "a.apps.googleusercontent.com,b",
        "fcm_credentials": "{}",
        "google_directions_key": "k",
    }
    with pytest.raises(ValueError, match="OTP_PROVIDER must be set"):
        Settings(_env_file=None, **good)
    with pytest.raises(ValueError, match="development only"):
        Settings(_env_file=None, otp_provider="console", **good)
    ok = Settings(_env_file=None, otp_provider="firebase", **good)
    assert ok.google_oauth_client_ids == ["a.apps.googleusercontent.com", "b"]
    assert make_config().resolved_otp_provider == "console"


async def test_settings_store_db_overrides_config(con):
    store = SettingsStore(make_config(alert_radius_m=777, otp_max_attempts=9), ttl_s=1000)
    assert store.get_cached("alert_radius_m") == 777  # nothing loaded yet: config fallback
    assert await store.get("alert_radius_m", con) == 500.0  # seeded DB value wins
    await con.execute("update public.settings set value = '650' where key = 'alert_radius_m'")
    assert await store.get("alert_radius_m", con) == 500.0  # cached
    store.invalidate()
    assert await store.get("alert_radius_m", con) == 650.0
    await con.execute("delete from public.settings where key = 'otp_max_attempts'")
    store.invalidate()
    assert await store.get("otp_max_attempts", con) == 9  # missing key: config fallback
    assert await store.get("timezone", con) == "Asia/Kolkata"
    with pytest.raises(KeyError):
        store.get_cached("no_such_setting")


async def test_role_comes_from_db_not_token(app, client, con, google_login):
    router = APIRouter()

    @router.get("/api/v1/test-admin-only")
    async def admin_only(user: Annotated[CurrentUser, Depends(require_role("admin"))]):
        return {"role": user.role}

    app.include_router(router)
    tokens = await google_login()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    resp = await client.get("/api/v1/test-admin-only", headers=headers)
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "FORBIDDEN_ROLE"  # TC4 (role part)
    await con.execute("update public.users set role = 'admin' where id = $1", tokens["user"]["id"])
    resp = await client.get("/api/v1/test-admin-only", headers=headers)  # same token, role from DB
    assert resp.status_code == 200 and resp.json() == {"role": "admin"}


async def test_event_hooks_publish_and_isolate_errors():
    seen = []

    async def ok(app, *, user_id):
        seen.append(user_id)

    async def bad(app, *, user_id):
        raise RuntimeError("handler bug")

    live.subscribe("test_event")(bad)
    live.subscribe("test_event")(ok)
    try:
        await live.publish(None, "test_event", user_id="u1")
    finally:
        live._handlers.pop("test_event", None)
    assert seen == ["u1"]


async def test_jobs_start_tick_and_stop(config):
    ticks = asyncio.Event()

    async def tick(app):
        ticks.set()

    jobs.register_job("test_job", tick, interval_s=0.01)
    app = create_app(config)
    try:
        await jobs.start_jobs(app)
        await asyncio.wait_for(ticks.wait(), timeout=2)
        await jobs.stop_jobs(app)
        assert app.state.job_tasks == []
    finally:
        jobs._jobs.pop("test_job", None)


def test_app_error_custom_message():
    assert AppError("x").message == "x"
    assert RateLimited(0).retry_after == 1
