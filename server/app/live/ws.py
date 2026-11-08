"""WebSocket live channel `/api/v1/ws/live` (API spec p.6).

Protocol:
  1. Client connects and must send `{"type": "auth", "token": "<access token>"}`
     within `ws_auth_timeout_s` (5 s); the token is never in the URL.
  2. Client sends `{"type": "ping"}` every `ws_heartbeat_s` (25 s); server replies
     `{"type": "pong"}`. A client silent for `ws_idle_timeout_s` is dropped.
  3. Server pushes `bus_position`, `bus_status`, `trip_started`, `trip_ended`
     (and `announcement` from Phase 4) to every authenticated client via the hub.

Close codes: 4401 with reason AUTH_TIMEOUT | AUTH_REQUIRED | TOKEN_INVALID |
TOKEN_EXPIRED | SESSION_REPLACED (also sent when the session is revoked while
connected); 1013 DB_UNAVAILABLE during the handshake; 1001 IDLE_TIMEOUT.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any
from uuid import UUID

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from app.errors import AppError, DbUnavailable, SessionReplaced, TokenInvalid
from app.live import SESSIONS_REVOKED, USER_DELETED, subscribe
from app.live.conn import live_conn
from app.live.hub import get_hub
from app.live.state import get_live
from app.security import decode_access_token

log = logging.getLogger("ctms.live.ws")

CLOSE_AUTH = 4401
CLOSE_TRY_AGAIN = 1013
CLOSE_GOING_AWAY = 1001
# Raised by Starlette when the peer is gone or a frame is not text.
_GONE = (WebSocketDisconnect, RuntimeError, KeyError)


async def authenticate(app: Any, token: str) -> tuple[UUID, UUID]:
    """(user_id, session_id) for a valid access token whose session and user are live."""
    claims = decode_access_token(token, app.state.config.jwt_secret)
    async with live_conn(app) as con:
        row = await con.fetchrow(
            """select u.active, s.revoked_at, s.revoked_reason
                 from public.sessions s join public.users u on u.id = s.user_id
                where s.id = $1 and s.user_id = $2""",
            claims.session_id, claims.user_id,
        )
    if row is None or not row["active"]:
        raise TokenInvalid()
    if row["revoked_at"] is not None:
        raise SessionReplaced() if row["revoked_reason"] == "replaced" else TokenInvalid()
    return claims.user_id, claims.session_id


async def _close(ws: Any, code: int, reason: str) -> None:
    try:
        await ws.close(code=code, reason=reason)
    except Exception:
        log.debug("ws close failed", exc_info=True)


def _parse(raw: str) -> dict:
    try:
        msg = json.loads(raw)
    except ValueError:
        return {}
    return msg if isinstance(msg, dict) else {}


async def live_ws(ws: WebSocket) -> None:
    app = ws.app
    store = app.state.settings_store
    await ws.accept()
    try:
        raw = await asyncio.wait_for(ws.receive_text(), timeout=float(store.get_cached("ws_auth_timeout_s")))
    except TimeoutError:
        await _close(ws, CLOSE_AUTH, "AUTH_TIMEOUT")
        return
    except _GONE:
        return
    msg = _parse(raw)
    token = msg.get("token")
    if msg.get("type") != "auth" or not isinstance(token, str) or not token:
        await _close(ws, CLOSE_AUTH, "AUTH_REQUIRED")
        return
    try:
        user_id, session_id = await authenticate(app, token)
    except DbUnavailable:
        await _close(ws, CLOSE_TRY_AGAIN, DbUnavailable.code)
        return
    except AppError as exc:
        await _close(ws, CLOSE_AUTH, exc.code)
        return
    hub = get_hub(app)
    hub.add(ws, user_id, session_id)
    idle = float(store.get_cached("ws_idle_timeout_s"))
    try:
        while True:
            msg = _parse(await asyncio.wait_for(ws.receive_text(), timeout=idle))
            if msg.get("type") == "ping":
                await ws.send_json({"type": "pong"})
    except TimeoutError:
        await _close(ws, CLOSE_GOING_AWAY, "IDLE_TIMEOUT")
    except _GONE:
        pass
    finally:
        hub.remove(ws)


async def close_user_sockets(app: Any, *, user_id: UUID, session_ids: set[UUID] | None, reason: str) -> int:
    """Close the given sessions' sockets (or all of the user's when `session_ids` is empty)."""
    hub = get_hub(app)
    victims = [ws for ws, (uid, sid) in list(hub.clients.items())
               if (sid in session_ids if session_ids else uid == user_id)]
    for ws in victims:
        hub.remove(ws)
        await _close(ws, CLOSE_AUTH, reason)
    return len(victims)


@subscribe(SESSIONS_REVOKED)
async def on_sessions_revoked(app: Any, *, user_id: UUID, reason: str, session_ids: list[UUID]) -> None:
    get_live(app).revoked_sessions.update(session_ids)
    code = SessionReplaced.code if reason == "replaced" else TokenInvalid.code
    await close_user_sockets(app, user_id=user_id, session_ids=set(session_ids), reason=code)


@subscribe(USER_DELETED)
async def on_user_deleted(app: Any, *, user_id: UUID) -> None:
    await close_user_sockets(app, user_id=user_id, session_ids=None, reason=TokenInvalid.code)


def register(app: FastAPI) -> None:
    from app.api.router import API_PREFIX

    app.add_api_websocket_route(f"{API_PREFIX}/ws/live", live_ws, name="ws_live")
