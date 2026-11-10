"""The digital bus card: a signed payload (v13-spec decision 6).

qr_payload = base64url(canonical JSON payload) + "." + base64url(HMAC-SHA256(key, canonical JSON)).
The key is derived from the server secret with a fixed label, so rotating JWT_SECRET invalidates every
card (students just re-open the card to get a new one). The signature is checked with a constant-time
compare; a token that was changed in any byte is simply "not valid".
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
from datetime import date, datetime
from typing import Any
from zoneinfo import ZoneInfo

CARD_KEY_LABEL = b"ctms/bus-card/v1"
PAYLOAD_VERSION = 1


def derive_key(secret: str) -> bytes:
    return hmac.new(secret.encode(), CARD_KEY_LABEL, hashlib.sha256).digest()


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def canonical(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sign(key: bytes, payload: dict[str, Any]) -> tuple[str, str]:
    """(signature, qr_payload) for a payload."""
    raw = canonical(payload)
    signature = _b64(hmac.new(key, raw, hashlib.sha256).digest())
    return signature, f"{_b64(raw)}.{signature}"


def open_token(key: bytes, token: str) -> dict[str, Any] | None:
    """The payload of an authentic token, or None for anything malformed or tampered with."""
    try:
        body, signature = token.split(".")
        raw = _unb64(body)
        given = _unb64(signature)
    except (ValueError, binascii.Error):
        return None
    if not hmac.compare_digest(hmac.new(key, raw, hashlib.sha256).digest(), given):
        return None
    try:
        payload = json.loads(raw)
    except ValueError:
        return None
    return payload if isinstance(payload, dict) and payload.get("v") == PAYLOAD_VERSION else None


def default_valid_until(today: date) -> date:
    """The next 31 July on or after `today`."""
    this_year = date(today.year, 7, 31)
    return this_year if today <= this_year else date(today.year + 1, 7, 31)


def valid_until(configured: str | None, today: date) -> date:
    try:
        return date.fromisoformat(str(configured)) if configured else default_valid_until(today)
    except ValueError:
        return default_valid_until(today)


def local_today(now: datetime, tz_name: str) -> date:
    return now.astimezone(ZoneInfo(tz_name)).date()


def card_no(user_id: Any, issued_at: datetime) -> str:
    return f"UOK-{issued_at.year}-{str(user_id).replace('-', '')[:8].upper()}"
