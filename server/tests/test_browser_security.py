"""CORS, WebSocket Origin and security headers (no database needed)."""

from __future__ import annotations

import json

import httpx
import pytest
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.config import Settings
from app.main import create_app
from tests.conftest import make_config

ALLOWED = "https://app.example.test"
DENIED = "https://evil.example.test"


def _app(**overrides):
    return create_app(make_config(cors_origins=[ALLOWED], **overrides))


async def _request(app, method, path, **kw):
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        return await c.request(method, path, **kw)


def _preflight(origin: str, headers: str = "authorization,content-type"):
    return {"Origin": origin, "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": headers}


async def test_cors_allowed_origin_simple_request():
    r = await _request(_app(), "GET", "/openapi.json", headers={"Origin": ALLOWED})
    assert r.headers["access-control-allow-origin"] == ALLOWED
    assert "access-control-allow-credentials" not in r.headers


async def test_cors_denied_origin_gets_no_allow_header():
    r = await _request(_app(), "GET", "/openapi.json", headers={"Origin": DENIED})
    assert "access-control-allow-origin" not in r.headers


async def test_cors_preflight_allowed():
    r = await _request(_app(), "OPTIONS", "/api/v1/auth/login", headers=_preflight(ALLOWED, "authorization,x-request-id"))
    assert r.status_code == 200
    assert r.headers["access-control-allow-origin"] == ALLOWED
    allowed = {h.strip().lower() for h in r.headers["access-control-allow-headers"].split(",")}
    assert {"authorization", "content-type", "x-request-id"} <= allowed
    assert "access-control-allow-credentials" not in r.headers
    assert "*" not in r.headers["access-control-allow-origin"]


async def test_cors_preflight_denied_origin_and_header():
    app = _app()
    r = await _request(app, "OPTIONS", "/api/v1/auth/login", headers=_preflight(DENIED))
    assert r.status_code == 400 and "access-control-allow-origin" not in r.headers
    r = await _request(app, "OPTIONS", "/api/v1/auth/login", headers=_preflight(ALLOWED, "x-custom"))
    assert r.status_code == 400


def test_wildcard_origin_rejected():
    with pytest.raises(ValueError):
        make_config(cors_origins=["*"])


def test_dev_default_only_outside_production():
    assert make_config().allowed_origins == ["http://localhost:5173"]
    assert make_config(cors_origins=[ALLOWED + "/"]).allowed_origins == [ALLOWED]
    prod = Settings(
        _env_file=None, app_env="production", database_url="postgresql://u:p@db.example/x",
        jwt_secret="x" * 40, google_oauth_client_ids=["c"], fcm_credentials="{}", google_directions_key="k",
        push_provider="fcm",
    )
    assert prod.allowed_origins == []


# --- WebSocket Origin ---------------------------------------------------------

def test_ws_allowed_origin_reaches_auth():
    with TestClient(_app()).websocket_connect("/api/v1/ws/live", headers={"origin": ALLOWED}) as ws:
        ws.send_text(json.dumps({"type": "auth", "token": "garbage"}))
        with pytest.raises(WebSocketDisconnect) as info:
            ws.receive_text()
    assert info.value.code == 4401


def test_ws_missing_origin_allowed():
    with TestClient(_app()).websocket_connect("/api/v1/ws/live") as ws:
        ws.send_text(json.dumps({"type": "auth", "token": "garbage"}))
        with pytest.raises(WebSocketDisconnect) as info:
            ws.receive_text()
    assert info.value.code == 4401


def test_ws_disallowed_origin_rejected_before_auth():
    with pytest.raises(WebSocketDisconnect) as info:
        with TestClient(_app()).websocket_connect("/api/v1/ws/live", headers={"origin": DENIED}):
            pass
    assert info.value.code != 4401


# --- Security headers -----------------------------------------------------------

async def test_security_headers_present_no_hsts_outside_production():
    r = await _request(_app(), "GET", "/openapi.json")
    assert r.headers["x-content-type-options"] == "nosniff"
    assert r.headers["referrer-policy"] == "strict-origin-when-cross-origin"
    assert r.headers["content-security-policy"] == "frame-ancestors 'none'"
    assert "geolocation=()" in r.headers["permissions-policy"]
    assert "strict-transport-security" not in r.headers


async def test_headers_on_error_responses():
    r = await _request(_app(), "GET", "/api/v1/does-not-exist")
    assert r.status_code == 404 and r.headers["x-content-type-options"] == "nosniff"


async def test_hsts_only_in_production():
    config = Settings(
        _env_file=None, app_env="production", database_url="postgresql://u:p@db.example/x",
        jwt_secret="x" * 40, google_oauth_client_ids=["c"], fcm_credentials="{}", google_directions_key="k",
        push_provider="fcm", cors_origins=[ALLOWED],
    )
    r = await _request(create_app(config), "GET", "/openapi.json")
    assert r.headers["strict-transport-security"].startswith("max-age=")
    staging = config.model_copy(update={"app_env": "staging"})
    r = await _request(create_app(staging), "GET", "/openapi.json")
    assert "strict-transport-security" not in r.headers
