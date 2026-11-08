"""Push sender interface (PUSH_PROVIDER = fcm | fake | log).

A sender delivers one batch of `PushMessage`s and reports a `PushResult` per
message; it never raises for a single bad token. `is_invalid_token(exc)` decides
which failures mean "delete this token" (N9) rather than "retry once".
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

from firebase_admin import exceptions as fb_exceptions
from firebase_admin import messaging


@dataclass(frozen=True)
class PushMessage:
    token: str
    title: str
    body: str
    data: dict[str, str] = field(default_factory=dict)
    # Android notification tag: a later push with the same tag replaces the shown one (A4).
    tag: str | None = None


@dataclass(frozen=True)
class PushResult:
    token: str
    exception: Exception | None = None

    @property
    def ok(self) -> bool:
        return self.exception is None


class PushSender(Protocol):
    name: str

    async def send(self, messages: list[PushMessage]) -> list[PushResult]: ...


def is_invalid_token(exc: Exception | None) -> bool:
    """FCM says the token can never work again (allowed-apis.md: firebase-admin error table)."""
    if isinstance(exc, messaging.UnregisteredError | messaging.SenderIdMismatchError):
        return True
    # A malformed token comes back as INVALID_ARGUMENT; our payloads are fixed, so only
    # treat it as a token problem when FCM says so.
    return isinstance(exc, fb_exceptions.InvalidArgumentError) and "registration token" in str(exc).lower()


def redact(token: str) -> str:
    return f"{token[:6]}…" if len(token) > 6 else "…"
