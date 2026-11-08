"""Google ID token verification (google-auth), injectable for tests.

`app.state.google_verifier` is an async callable token -> claims that raises
TokenInvalid. Tests replace it with a fake; production uses `GoogleVerifier`.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable

import google.auth.exceptions
from fastapi import Request
from google.auth.transport import requests as g_requests
from google.oauth2 import id_token

from app.errors import TokenInvalid

GOOGLE_ISSUERS = frozenset({"accounts.google.com", "https://accounts.google.com"})

GoogleTokenVerifier = Callable[[str], Awaitable[dict]]


class GoogleVerifier:
    def __init__(self, client_ids: list[str]) -> None:
        self._client_ids = list(client_ids)
        self._request = g_requests.Request()

    def _verify_sync(self, token: str) -> dict:
        # verify_token accepts a list of audiences but skips the issuer check (allowed-apis.md).
        info = dict(id_token.verify_token(token, self._request, audience=self._client_ids))
        if info.get("iss") not in GOOGLE_ISSUERS:
            raise ValueError("wrong issuer")
        return info

    async def __call__(self, token: str) -> dict:
        if not self._client_ids:
            raise TokenInvalid("Google sign-in is not configured (GOOGLE_OAUTH_CLIENT_IDS)")
        try:
            return await asyncio.to_thread(self._verify_sync, token)
        except (ValueError, google.auth.exceptions.GoogleAuthError) as exc:
            raise TokenInvalid("Google ID token rejected") from exc


def get_google_verifier(request: Request) -> GoogleTokenVerifier:
    return request.app.state.google_verifier
