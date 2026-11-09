"""Structured request logging with redaction (Phase 9, runbook "server logs").

    install_request_logging(app, config)     # once, in create_app

- One log line per HTTP request (`ctms.request`): method, path WITHOUT the query
  string, status, duration_ms, request_id. WebSockets get one line on close.
  `/health` is logged at DEBUG so keep-alive pings do not flood the logs.
- `X-Request-ID` is accepted from the client when it looks safe, otherwise
  generated, and echoed on the response.
- Every formatted log line (message, args, traceback) passes through `redact()`:
  coordinates, bearer/JWT/refresh tokens, push tokens, OTP codes and secrets
  given as key/value are replaced. Logs never carry lat/lng, tokens or OTP codes.
  (The dev console OTP provider prints codes by design; config refuses
  OTP_PROVIDER=console outside dev/test.)
- Outside dev/test the root handler writes JSON lines (one object per record),
  which Render log search indexes; dev keeps plain text.

Uvicorn's own access log prints raw query strings, so the container runs uvicorn
with `--no-access-log`; this middleware replaces it.
"""

from __future__ import annotations

import json
import logging
import re
import time
import uuid
from collections.abc import Awaitable, Callable, MutableMapping
from datetime import UTC, datetime
from typing import Any

from fastapi import FastAPI

from app.config import Settings

log = logging.getLogger("ctms.request")

Scope = MutableMapping[str, Any]
Message = MutableMapping[str, Any]
Receive = Callable[[], Awaitable[Message]]
Send = Callable[[Message], Awaitable[None]]
ASGIApp = Callable[[Scope, Receive, Send], Awaitable[None]]

REDACTED = "[redacted]"

# Keys whose values must never reach the logs, in `key=value`, `key: value`,
# `"key": value` or `'key': 'value'` form (case-insensitive).
_SENSITIVE_KEYS = (
    r"lat|lng|lon|latitude|longitude|"
    r"access_token|refresh_token|id_token|token|push_token|fcm_token|"
    r"otp|otp_code|password|secret|jwt_secret|authorization|api_key|x-goog-api-key"
)
_KV = re.compile(
    rf"""(?P<k>["']?\b(?:{_SENSITIVE_KEYS})\b["']?\s*[:=]\s*)(?P<v>"[^"]*"|'[^']*'|[^\s,;&}}\])]+)""",
    re.IGNORECASE,
)
_BEARER = re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]+", re.IGNORECASE)
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+")
# A bare coordinate pair such as "34.12345, 74.83456" (4+ decimals each).
_COORD_PAIR = re.compile(r"-?\b\d{1,3}\.\d{4,}\s*,\s*-?\d{1,3}\.\d{4,}\b")
# Our refresh tokens are "<session uuid>.<random>".
_REFRESH = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[A-Za-z0-9_-]{16,}")

_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
_QUIET_PATHS = frozenset({"/health", "/api/v1/health"})


def redact(text: str) -> str:
    """Remove coordinates, tokens, OTP codes and secrets from a log string."""
    text = _BEARER.sub(f"Bearer {REDACTED}", text)
    text = _JWT.sub(REDACTED, text)
    text = _REFRESH.sub(REDACTED, text)
    text = _KV.sub(lambda m: m.group("k") + REDACTED, text)
    return _COORD_PAIR.sub(REDACTED, text)


class RedactingFormatter(logging.Formatter):
    """Wraps another formatter and redacts its whole output (message + traceback)."""

    def __init__(self, inner: logging.Formatter | None = None) -> None:
        super().__init__()
        self.inner = inner or logging.Formatter("%(levelname)s [%(name)s] %(message)s")

    def format(self, record: logging.LogRecord) -> str:
        return redact(self.inner.format(record))


# Fields of a LogRecord that are not user-supplied `extra=` values.
_RECORD_ATTRS = frozenset(vars(logging.makeLogRecord({}))) | {"message", "asctime", "taskName", "color_message"}


class JsonFormatter(logging.Formatter):
    """One JSON object per record: ts, level, logger, msg, extra fields, exc. All redacted."""

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat().replace("+00:00", "Z"),
            "level": record.levelname,
            "logger": record.name,
            "msg": redact(record.getMessage()),
        }
        for key, value in vars(record).items():
            if key not in _RECORD_ATTRS and not key.startswith("_"):
                entry[key] = redact(value) if isinstance(value, str) else value
        if record.exc_info:
            entry["exc"] = redact(self.formatException(record.exc_info))
        if record.stack_info:
            entry["stack"] = redact(self.formatStack(record.stack_info))
        return json.dumps(entry, default=str, ensure_ascii=False)


def configure_logging(config: Settings) -> None:
    """Root handler with redaction (JSON outside dev). Idempotent; leaves pytest's handlers alone."""
    root = logging.getLogger()
    formatter: logging.Formatter = RedactingFormatter() if config.is_dev else JsonFormatter()
    for handler in list(root.handlers):
        if getattr(handler, "_ctms", False) or type(handler) is logging.StreamHandler:
            root.removeHandler(handler)   # basicConfig's handler, or ours from an earlier create_app
    handler = logging.StreamHandler()
    handler._ctms = True  # type: ignore[attr-defined]
    handler.setFormatter(formatter)
    root.addHandler(handler)
    root.setLevel(config.log_level)
    # Uvicorn's loggers do not propagate: redact their output too.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        for uv_handler in logging.getLogger(name).handlers:
            if not isinstance(uv_handler.formatter, RedactingFormatter | JsonFormatter):
                uv_handler.setFormatter(JsonFormatter() if not config.is_dev
                                        else RedactingFormatter(uv_handler.formatter))


def _request_id(scope: Scope) -> str:
    for name, value in scope.get("headers", ()):
        if name == b"x-request-id":
            candidate = value.decode("latin-1")
            if _REQUEST_ID.match(candidate):
                return candidate
            break
    return uuid.uuid4().hex


class RequestLoggingMiddleware:
    """Pure ASGI (works for HTTP and WebSocket, keeps streaming intact)."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return
        request_id = _request_id(scope)
        scope.setdefault("state", {})["request_id"] = request_id
        start = time.perf_counter()
        status: int | None = None

        async def send_wrapper(message: Message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                message.setdefault("headers", [])
                message["headers"] = [*message["headers"], (b"x-request-id", request_id.encode())]
            elif message["type"] == "websocket.close":
                status = message.get("code", 1000)
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        except Exception:
            status = status or 500
            raise
        finally:
            self._log(scope, status, start, request_id)

    @staticmethod
    def _log(scope: Scope, status: int | None, start: float, request_id: str) -> None:
        path = scope.get("path", "")   # never the query string
        is_ws = scope["type"] == "websocket"
        level = logging.DEBUG if path in _QUIET_PATHS else logging.INFO
        if not is_ws and status is not None and status >= 500:
            level = logging.WARNING
        method = "WS" if is_ws else scope.get("method", "")
        duration_ms = round((time.perf_counter() - start) * 1000, 1)
        log.log(level, "%s %s %s %.1fms", method, path, status, duration_ms,
                extra={"method": method, "path": path, "status": status, "duration_ms": duration_ms,
                       "request_id": request_id})


def install_request_logging(app: FastAPI, config: Settings) -> None:
    configure_logging(config)
    app.add_middleware(RequestLoggingMiddleware)
