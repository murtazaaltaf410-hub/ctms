"""WebSocket broadcast hub.

    from app.live.hub import broadcast
    await broadcast(app, {"type": "announcement", "id": "...", "title": "...", "urgent": False})

`broadcast` sends a JSON message to every authenticated `/api/v1/ws/live` client;
a dead client is dropped and never fails the caller. The hub lives on
`app.state.ws_hub` (created lazily so tests need no lifespan).
"""

from __future__ import annotations

import logging
from typing import Any

log = logging.getLogger("ctms.live.hub")


class Hub:
    """Authenticated WS clients. `clients` maps a client object to (user_id, session_id)."""

    def __init__(self) -> None:
        self.clients: dict[Any, tuple[Any, Any]] = {}

    def add(self, ws: Any, user_id: Any, session_id: Any) -> None:
        self.clients[ws] = (user_id, session_id)

    def remove(self, ws: Any) -> None:
        self.clients.pop(ws, None)

    async def send_all(self, message: dict) -> None:
        for ws in list(self.clients):
            try:
                await ws.send_json(message)
            except Exception:
                log.debug("dropping dead ws client", exc_info=True)
                self.remove(ws)


def get_hub(app: Any) -> Hub:
    hub = getattr(app.state, "ws_hub", None)
    if hub is None:
        hub = app.state.ws_hub = Hub()
    return hub


async def broadcast(app: Any, message: dict) -> None:
    await get_hub(app).send_all(message)
