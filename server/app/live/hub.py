"""WebSocket broadcast hub.

    from app.live.hub import broadcast
    await broadcast(app, {"type": "announcement", "id": "...", "title": "...", "urgent": False})

`broadcast` sends a JSON message to every authenticated `/api/v1/ws/live` client;
a dead client is dropped and never fails the caller. A message about one route
(`route_id=`) reaches admins, drivers and only those students whose approved registration
is for that route (ADR-10); a student without an approved registration gets no route
messages. Messages without `route_id` (announcements) reach everyone. The hub lives on
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
        # Students only: ws -> the route they may see (None = not approved, no route messages).
        self.student_routes: dict[Any, Any] = {}

    def add(self, ws: Any, user_id: Any, session_id: Any, *, student: bool = False,
            route_id: Any = None) -> None:
        self.clients[ws] = (user_id, session_id)
        if student:
            self.student_routes[ws] = route_id

    def remove(self, ws: Any) -> None:
        self.clients.pop(ws, None)
        self.student_routes.pop(ws, None)

    def set_student_route(self, user_id: Any, route_id: Any) -> None:
        """An admin approved, reassigned or rejected this student: re-scope their open sockets."""
        for ws, (uid, _sid) in self.clients.items():
            if uid == user_id and ws in self.student_routes:
                self.student_routes[ws] = route_id

    async def send_all(self, message: dict, route_id: Any = None) -> None:
        for ws in list(self.clients):
            if route_id is not None and ws in self.student_routes and self.student_routes[ws] != route_id:
                continue
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


async def broadcast(app: Any, message: dict, route_id: Any = None) -> None:
    await get_hub(app).send_all(message, route_id)
