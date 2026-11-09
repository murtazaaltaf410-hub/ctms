"""Tokens and hashes.

* Access token: HS256 JWT with `sub` (user id), `sid` (sessions.id), `role`
  (informational only; the role is always re-read from the DB), `iat`, `exp`.
* Refresh token: `<session id>.<random>`; only its SHA-256 is stored
  (`sessions.refresh_hash`). Carrying the session id lets the server tell a
  replayed (already rotated) token from an unknown one -> reuse detection.
* Driver passwords (ADR-10): salted scrypt (hashlib.scrypt), stored as
  `scrypt$n$r$p$salt_b64$hash_b64`; verified with hmac.compare_digest. Never logged or returned.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID

import jwt

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


# --- Passwords (ADR-10) -------------------------------------------------------------
# hashlib.scrypt (https://docs.python.org/3/library/hashlib.html#hashlib.scrypt): n=2**14, r=8, p=1
# needs 128*n*r = 16 MiB, above OpenSSL's 32 MiB default maxmem headroom for some builds, so maxmem is set.
SCRYPT_N = 2**14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 32
SCRYPT_MAXMEM = 64 * 1024 * 1024
_SALT_BYTES = 16


def _scrypt(password: str, salt: bytes, n: int, r: int, p: int, dklen: int) -> bytes:
    return hashlib.scrypt(password.encode(), salt=salt, n=n, r=r, p=p, maxmem=SCRYPT_MAXMEM, dklen=dklen)


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(_SALT_BYTES)
    digest = _scrypt(password, salt, SCRYPT_N, SCRYPT_R, SCRYPT_P, SCRYPT_DKLEN)
    b64 = base64.b64encode
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${b64(salt).decode()}${b64(digest).decode()}"


def verify_password(password: str, stored: str | None) -> bool:
    """Constant-time check. With no/garbled `stored` it still burns one scrypt run (same cost as a
    real check) and returns False, so unknown users are not distinguishable by timing."""
    try:
        if stored is None:
            raise ValueError
        scheme, n, r, p, salt_b64, hash_b64 = stored.split("$")
        if scheme != "scrypt":
            raise ValueError
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(hash_b64)
        digest = _scrypt(password, salt, int(n), int(r), int(p), len(expected))
    except (ValueError, TypeError):
        _scrypt(password, DUMMY_SALT, SCRYPT_N, SCRYPT_R, SCRYPT_P, SCRYPT_DKLEN)
        return False
    return hmac.compare_digest(digest, expected)


DUMMY_SALT = b"ctms-dummy-salt!"  # 16 bytes; only used to equalise timing


def generate_temporary_password(length: int = 12) -> str:
    """Readable random password (no 0/O/1/l/I), at least one letter and one digit."""
    alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    while True:
        pw = "".join(secrets.choice(alphabet) for _ in range(length))
        if any(c.isalpha() for c in pw) and any(c.isdigit() for c in pw):
            return pw
