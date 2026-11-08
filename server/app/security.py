"""Tokens and hashes.

* Access token: HS256 JWT with `sub` (user id), `sid` (sessions.id), `role`
  (informational only; the role is always re-read from the DB), `iat`, `exp`.
* Refresh token: `<session id>.<random>`; only its SHA-256 is stored
  (`sessions.refresh_hash`). Carrying the session id lets the server tell a
  replayed (already rotated) token from an unknown one -> reuse detection.
* OTP codes: HMAC-SHA256 of phone + code keyed with JWT_SECRET.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID

import jwl

from app.errors import TokenExpired, TokenInvalid

JWT_ALGORITHM = "HS256"


@dataclass(frozen=True, slots=True)
class AccessClaims:
    user_id: UUID
    session_id: UUID
    role: str


def create_access_token(*, user_id: UUID, session_id: UUID, role: str, secret: str, ttl_s: int,
                        now: datetime) -> str:
    payload = {
        "sub": str(user_id),
        "sid": str(session_id),
        "role": role,
        "typ": "access",
        "iat": now,
        "exp": now + timedelta(seconds=ttl_s),
    }
    return jwt.encode(payload, secret, algorithm=JWT_ALGORITHM)


def decode_access_token(token: str, secret: str) -> AccessClaims:
    try:
        payload = jwt.decode(token, secret, algorithms=[JWT_ALGORITHM],
                             options={"require": ["exp", "iat", "sub", "sid"]})
    except jwt.ExpiredSignatureError as exc:
        raise TokenExpired() from exc
    except jwt.InvalidTokenError as exc:
        raise TokenInvalid() from exc
    if payload.get("typ") != "access":
        raise TokenInvalid()
    try:
        return AccessClaims(UUID(payload["sub"]), UUID(payload["sid"]), str(payload.get("role", "")))
    except (ValueError, TypeError) as exc:
        raise TokenInvalid() from exc


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def new_refresh_token(session_id: UUID) -> str:
    return f"{session_id}.{secrets.token_urlsafe(32)}"


def parse_refresh_token(token: str) -> UUID:
    """The session id embedded in a refresh token; TOKEN_INVALID if malformed."""
    sid, sep, rest = token.partition(".")
    if not sep or not rest:
        raise TokenInvalid()
    try:
        return UUID(sid)
    except ValueError as exc:
        raise TokenInvalid() from exc


def hash_matches(stored_hex: str, presented: str) -> bool:
    return hmac.compare_digest(stored_hex, sha256_hex(presented))


def new_otp_code(digits: int = 6) -> str:
    return f"{secrets.randbelow(10**digits):0{digits}d}"


def hash_otp(phone: str, code: str, secret: str) -> str:
    return hmac.new(secret.encode(), f"{phone}:{code}".encode(), hashlib.sha256).hexdigest()
