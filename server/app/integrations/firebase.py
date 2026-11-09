"""Firebase Admin helpers: ID-token verification (`/auth/firebase`) and the shared default app (FCM push).

The token verifier is injected so tests never call Firebase. The default one uses
`firebase_admin.auth.verify_id_token` in a worker thread.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable

import firebase_admin
from fastapi import Request
from firebase_admin import auth, credentials

from app.config import Settings


class TokenExpiredError(Exception):
    """Raised by a verifier when the Firebase ID token is expired."""


TokenVerifier = Callable[[str], Awaitable[dict]]


def ensure_firebase_app(config: Settings) -> firebase_admin.App:
    """Initialise the default firebase_admin app once (shared with FCM push, P4)."""
    try:
        return firebase_admin.get_app()
    except ValueError:
        info = config.fcm_credentials_info()
        cred = credentials.Certificate(info) if info is not None else None
        return firebase_admin.initialize_app(cred)


def firebase_token_verifier(config: Settings) -> TokenVerifier:
    async def verify(token: str) -> dict:
        ensure_firebase_app(config)
        try:
            return await asyncio.to_thread(auth.verify_id_token, token, None, False, 0)
        except auth.ExpiredIdTokenError as exc:
            raise TokenExpiredError() from exc

    return verify


def get_firebase_token_verifier(request: Request) -> TokenVerifier:
    """Return the app override in tests, otherwise verify Firebase Admin tokens."""
    override = getattr(request.app.state, "firebase_token_verifier", None)
    return override or firebase_token_verifier(request.app.state.config)
