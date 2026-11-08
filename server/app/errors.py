"""Error envelope and every error code from the API spec (p.6-7).

Raise an `AppError` subclass anywhere; `install_error_handlers` renders it as
`{"error": {"code": ..., "message": ...}}` with the right status (and
`Retry-After` for 429). Validation errors become 400 VALIDATION_ERROR, and lost
database connections become 503 DB_UNAVAILABLE.
"""

from __future__ import annotations

import logging

import asyncpg
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("ctms.errors")


class AppError(Exception):
    status_code: int = 500
    code: str = "INTERNAL_ERROR"
    message: str = "Unexpected server error"

    def __init__(self, message: str | None = None, *, headers: dict[str, str] | None = None) -> None:
        self.message = message or type(self).message
        self.headers = headers or {}
        super().__init__(self.message)


# 400
class ValidationFailed(AppError):
    status_code, code, message = 400, "VALIDATION_ERROR", "Field missing or out of range"


class OtpInvalid(AppError):
    status_code, code, message = 400, "OTP_INVALID", "Phone sign-in failed"


class OtpExpired(AppError):
    status_code, code, message = 400, "OTP_EXPIRED", "The code has expired; request a new one"


# 401
class _Unauthorized(AppError):
    status_code = 401

    def __init__(self, message: str | None = None, *, headers: dict[str, str] | None = None) -> None:
        super().__init__(message, headers={"WWW-Authenticate": "Bearer", **(headers or {})})


class TokenExpired(_Unauthorized):
    code, message = "TOKEN_EXPIRED", "Token expired; sign in again"


class TokenInvalid(_Unauthorized):
    code, message = "TOKEN_INVALID", "Invalid token; sign in again"


class SessionReplaced(_Unauthorized):
    code, message = "SESSION_REPLACED", "Signed in on another device; sign in again"


# 403
class ForbiddenRole(AppError):
    status_code, code, message = 403, "FORBIDDEN_ROLE", "Your role may not call this endpoint"


class NotYourTrip(AppError):
    status_code, code, message = 403, "NOT_YOUR_TRIP", "This trip belongs to another driver"


# 404
class NotFound(AppError):
    status_code, code, message = 404, "NOT_FOUND", "Unknown ID"


# 409
class TripAlreadyActive(AppError):
    status_code, code, message = 409, "TRIP_ALREADY_ACTIVE", "A trip is already active"


class LastAdmin(AppError):
    status_code, code, message = 409, "LAST_ADMIN", "The last admin cannot be removed"


class InUse(AppError):
    status_code, code, message = 409, "IN_USE", "In use by an active trip"


# 422
class PolylineFailed(AppError):
    status_code, code, message = 422, "POLYLINE_FAILED", "Route could not be generated"


# 429
class RateLimited(AppError):
    status_code, code, message = 429, "RATE_LIMITED", "Too many requests; wait and retry"

    def __init__(self, retry_after: int, message: str | None = None) -> None:
        self.retry_after = max(1, int(retry_after))
        super().__init__(message, headers={"Retry-After": str(self.retry_after)})


# 503
class DbUnavailable(AppError):
    status_code, code, message = 503, "DB_UNAVAILABLE", "Database temporarily unavailable; retry"


ERROR_CLASSES: tuple[type[AppError], ...] = (
    ValidationFailed, OtpInvalid, OtpExpired, TokenExpired, TokenInvalid, SessionReplaced,
    ForbiddenRole, NotYourTrip, NotFound, TripAlreadyActive, LastAdmin, InUse, PolylineFailed,
    RateLimited, DbUnavailable,
)

# Lost or refused DB connections (asyncpg errors.md; network errors are OSError/TimeoutError).
DB_CONNECTION_ERRORS: tuple[type[BaseException], ...] = (
    asyncpg.PostgresConnectionError,
    asyncpg.CannotConnectNowError,
    OSError,
    TimeoutError,
)

_HTTP_CODES = {401: "TOKEN_INVALID", 403: "FORBIDDEN_ROLE", 404: "NOT_FOUND", 405: "METHOD_NOT_ALLOWED"}


def error_body(code: str, message: str) -> dict:
    return {"error": {"code": code, "message": message}}


def _render(exc: AppError) -> JSONResponse:
    return JSONResponse(error_body(exc.code, exc.message), status_code=exc.status_code, headers=exc.headers)


def _validation_message(exc: RequestValidationError) -> str:
    errors = exc.errors()
    if not errors:
        return ValidationFailed.message
    first = errors[0]
    loc = ".".join(str(part) for part in first.get("loc", ()) if part != "body") or "request"
    return f"{loc}: {first.get('msg', 'invalid value')}"


def install_error_handlers(app: FastAPI) -> None:
    async def app_error(request: Request, exc: AppError) -> JSONResponse:
        return _render(exc)

    async def validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        return _render(ValidationFailed(_validation_message(exc)))

    async def http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _HTTP_CODES.get(exc.status_code, f"HTTP_{exc.status_code}")
        return JSONResponse(error_body(code, str(exc.detail)), status_code=exc.status_code,
                            headers=getattr(exc, "headers", None))

    async def db_down(request: Request, exc: Exception) -> JSONResponse:
        log.warning("database unavailable: %s: %s", type(exc).__name__, exc)
        return _render(DbUnavailable())

    async def unexpected(request: Request, exc: Exception) -> JSONResponse:
        log.exception("unhandled error on %s %s", request.method, request.url.path)
        return _render(AppError())

    app.add_exception_handler(AppError, app_error)
    app.add_exception_handler(RequestValidationError, validation_error)
    app.add_exception_handler(StarletteHTTPException, http_error)
    for exc_type in DB_CONNECTION_ERRORS:
        app.add_exception_handler(exc_type, db_down)
    app.add_exception_handler(Exception, unexpected)
