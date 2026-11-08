"""The three push senders and `build_sender(config)`.

- `FcmSender`: firebase-admin `messaging.send_each` (<=500 per call) in a worker thread.
- `LogSender`: logs each message with a redacted token (dev default).
- `FakeSender`: records messages for tests; can return invalid-token or transient errors.
"""

from __future__ import annotations

import asyncio
import logging
import warnings

from firebase_admin import exceptions as fb_exceptions
from firebase_admin import messaging

from app.config import Settings
from app.otp.firebase import ensure_firebase_app
from app.push.base import PushMessage, PushResult, PushSender, redact

log = logging.getLogger("ctms.push")

FCM_BATCH_MAX = 500


def _to_fcm(msg: PushMessage) -> messaging.Message:
    # firebase-admin 7.x marks `token` deprecated in favour of `fid` (Firebase Installation
    # ID), but the app registers FCM registration tokens (`getToken()`), which `fid` does
    # not target. Keep `token` until the app sends installation IDs.
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", message="Message.token is deprecated", category=DeprecationWarning)
        return messaging.Message(
            token=msg.token,
            notification=messaging.Notification(title=msg.title, body=msg.body),
            data=msg.data or None,
            android=messaging.AndroidConfig(
                priority="high",
                collapse_key=msg.tag,
                notification=messaging.AndroidNotification(tag=msg.tag) if msg.tag else None,
            ),
        )


class FcmSender:
    name = "fcm"

    def __init__(self, config: Settings) -> None:
        self._config = config

    async def send(self, messages: list[PushMessage]) -> list[PushResult]:
        ensure_firebase_app(self._config)
        results: list[PushResult] = []
        for start in range(0, len(messages), FCM_BATCH_MAX):
            chunk = messages[start:start + FCM_BATCH_MAX]
            try:
                batch = await asyncio.to_thread(messaging.send_each, [_to_fcm(m) for m in chunk])
            except Exception as exc:  # whole call failed (network, auth): every message failed
                log.warning("fcm send_each failed: %s", type(exc).__name__)
                results.extend(PushResult(m.token, exc) for m in chunk)
                continue
            results.extend(PushResult(m.token, r.exception) for m, r in zip(chunk, batch.responses, strict=True))
        return results


class LogSender:
    name = "log"

    async def send(self, messages: list[PushMessage]) -> list[PushResult]:
        for msg in messages:
            log.info("push (log provider) to %s: %s | %s", redact(msg.token), msg.title, msg.body)
        return [PushResult(m.token) for m in messages]


class FakeSender:
    """Test sender. Tokens in `invalid` always fail with UnregisteredError; tokens in
    `fail_once` fail once with a transient UnavailableError, then succeed; tokens in
    `down` always fail with UnavailableError."""

    name = "fake"

    def __init__(self) -> None:
        self.sent: list[PushMessage] = []
        self.attempts: list[PushMessage] = []
        self.invalid: set[str] = set()
        self.fail_once: set[str] = set()
        self.down: set[str] = set()

    async def send(self, messages: list[PushMessage]) -> list[PushResult]:
        results = []
        for msg in messages:
            self.attempts.append(msg)
            if msg.token in self.invalid:
                results.append(PushResult(msg.token, messaging.UnregisteredError("Requested entity was not found.")))
            elif msg.token in self.down or msg.token in self.fail_once:
                self.fail_once.discard(msg.token)
                results.append(PushResult(msg.token, fb_exceptions.UnavailableError("FCM unavailable")))
            else:
                self.sent.append(msg)
                results.append(PushResult(msg.token))
        return results


def build_sender(config: Settings) -> PushSender:
    provider = config.resolved_push_provider
    if provider == "fcm":
        return FcmSender(config)
    if provider == "fake":
        return FakeSender()
    return LogSender()
