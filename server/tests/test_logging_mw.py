"""Structured logs: redaction of coordinates/tokens/OTP codes, request lines, X-Request-ID, prod OTP guard."""

from __future__ import annotations

import json
import logging

import pytest
from pydantic import ValidationError

from app.config import Settings
from app.logging_mw import REDACTED, JsonFormatter, RedactingFormatter, configure_logging, redact

JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXNpZ25hdHVyZQ"


@pytest.mark.parametrize(
    "text",
    [
        "fix lat=34.12345 lng=74.83456 accepted",
        '{"lat": 34.12345, "lng": 74.83456}',
        "{'latitude': 34.1, 'longitude': 74.8}",
        "student at 34.123456, 74.834567",
    ],
)
def test_redacts_coordinates(text):
    out = redact(text)
    assert "34.1" not in out and "74.8" not in out
    assert REDACTED in out


@pytest.mark.parametrize(
    "text, secret",
    [
        (f"Authorization: Bearer {JWT}", JWT),
        (f"got token {JWT}", JWT),
        ("refresh_token=0b6f3f9e-8a8c-4e57-9d1a-2f3f5d6c7b8a.Zm9vYmFyYmF6cXV4cXV1eDEyMzQ", "Zm9vYmFy"),
        ("0b6f3f9e-8a8c-4e57-9d1a-2f3f5d6c7b8a.Zm9vYmFyYmF6cXV4cXV1eDEyMzQ", "Zm9vYmFy"),
        ('{"otp": "123456"}', "123456"),
        ("push_token=fcm-abc-def-123", "fcm-abc-def-123"),
        ("X-Goog-Api-Key: AIzaSyDUMMYKEY", "AIzaSyDUMMYKEY"),
    ],
)
def test_redacts_tokens_and_codes(text, secret):
    assert secret not in redact(text)


def test_keeps_harmless_text():
    text = "auto-closed trip 7d1e (no fix since 2026-11-08T10:00:00+00:00), 3 rows"
    assert redact(text) == text


def _record(msg: str, *args, exc: BaseException | None = None, **extra) -> logging.LogRecord:
    record = logging.makeLogRecord(
        {"name": "ctms.test", "levelno": logging.INFO, "levelname": "INFO", "msg": msg, "args": args, **extra}
    )
    if exc is not None:
        try:
            raise exc
        except type(exc):
            import sys

            record.exc_info = sys.exc_info()
    return record


def test_json_formatter_redacts_message_args_extra_and_traceback():
    record = _record("bad fix lat=%s", 34.12345, exc=ValueError("lng=74.83456"), path="/api/v1/x", note=f"Bearer {JWT}")
    entry = json.loads(JsonFormatter().format(record))
    assert entry["level"] == "INFO" and entry["logger"] == "ctms.test"
    assert entry["ts"].endswith("Z")
    assert entry["path"] == "/api/v1/x"
    dumped = json.dumps(entry)
    assert "34.12345" not in dumped and "74.83456" not in dumped and JWT not in dumped
    assert "ValueError" in entry["exc"]


def test_redacting_formatter_wraps_output():
    out = RedactingFormatter().format(_record("lat=%s lng=%s", 34.12345, 74.83456))
    assert "34.12345" not in out and "74.83456" not in out


def test_configure_logging_is_idempotent_and_keeps_foreign_handlers():
    root = logging.getLogger()
    foreign = logging.NullHandler()
    root.addHandler(foreign)
    try:
        config = Settings(_env_file=None, app_env="test")
        configure_logging(config)
        configure_logging(config)
        ours = [h for h in root.handlers if getattr(h, "_ctms", False)]
        assert len(ours) == 1
        assert foreign in root.handlers
    finally:
        root.removeHandler(foreign)


async def test_request_line_has_no_query_string_and_request_id(client, caplog):
    caplog.set_level(logging.INFO, logger="ctms.request")
    resp = await client.get("/api/v1/config?lat=34.12345&lng=74.83456", headers={"X-Request-ID": "abc-123"})
    assert resp.status_code == 200
    assert resp.headers["x-request-id"] == "abc-123"
    lines = [r for r in caplog.records if r.name == "ctms.request"]
    assert lines, "no request log line"
    rec = lines[-1]
    assert rec.path == "/api/v1/config" and rec.status == 200 and rec.method == "GET"
    assert rec.request_id == "abc-123"
    assert "34.12345" not in rec.getMessage()


async def test_unsafe_request_id_is_replaced(client):
    resp = await client.get("/api/v1/config", headers={"X-Request-ID": "bad id\nwith newline" * 10})
    rid = resp.headers["x-request-id"]
    assert len(rid) == 32 and rid.isalnum()


async def test_health_is_logged_at_debug(client, caplog):
    caplog.set_level(logging.DEBUG, logger="ctms.request")
    await client.get("/health")
    lines = [r for r in caplog.records if r.name == "ctms.request" and r.path == "/health"]
    assert lines and lines[-1].levelno == logging.DEBUG


@pytest.mark.parametrize("env", ["staging", "production"])
def test_console_otp_refused_outside_dev(env):
    """The console OTP provider logs codes by design, so it must never run in staging/prod."""
    with pytest.raises(ValidationError, match="OTP_PROVIDER=console is for development only"):
        Settings(
            _env_file=None,
            app_env=env,
            otp_provider="console",
            jwt_secret="x" * 40,
            database_url="postgresql://u:p@db:5432/ctms",
            google_oauth_client_ids=["id"],
            fcm_credentials="{}",
            google_directions_key="k",
        )
