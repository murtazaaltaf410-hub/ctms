"""Interface contract for Phase 4: hooks registry + hub broadcast (no DB)."""

from __future__ import annotations

from datetime import UTC, datetime
from types import SimpleNamespace
from uuid import uuid4

from app.live import hooks
from app.live.hub import broadcast, get_hub


def _fix() -> hooks.FixEvent:
    now = datetime.now(UTC)
    return hooks.FixEvent(trip_id=uuid4(), bus_id=uuid4(), route_id=uuid4(), bus_label="B1",
                          route_name="R1", lat=34.1, lng=74.8, speed_mps=5.0, heading=90.0,
                          recorded_at=now, received_at=now, trip_status="on_time")


async def test_emit_fix_isolates_failing_listener(monkeypatch):
    monkeypatch.setattr(hooks, "_fix_listeners", [])
    seen = []

    async def boom(app, ev):
        raise RuntimeError("listener bug")

    async def ok(app, ev):
        seen.append(ev)

    hooks.register_fix_listener(boom)
    hooks.register_fix_listener(ok)
    hooks.register_fix_listener(ok)  # idempotent
    ev = _fix()
    await hooks.emit_fix(object(), ev)
    assert seen == [ev]


async def test_emit_trip_calls_listeners(monkeypatch):
    monkeypatch.setattr(hooks, "_trip_listeners", [])
    seen = []

    async def ok(app, ev):
        seen.append(ev.kind)

    hooks.register_trip_listener(ok)
    await hooks.emit_trip(object(), hooks.TripEvent(uuid4(), uuid4(), uuid4(), "started"))
    assert seen == ["started"]


class _FakeWS:
    def __init__(self, fail: bool = False) -> None:
        self.sent: list[dict] = []
        self.fail = fail

    async def send_json(self, msg: dict) -> None:
        if self.fail:
            raise RuntimeError("closed")
        self.sent.append(msg)


async def test_broadcast_reaches_clients_and_drops_dead():
    app = SimpleNamespace(state=SimpleNamespace())
    hub = get_hub(app)
    good, dead = _FakeWS(), _FakeWS(fail=True)
    hub.add(good, uuid4(), uuid4())
    hub.add(dead, uuid4(), uuid4())
    await broadcast(app, {"type": "announcement", "data": {}})
    assert good.sent == [{"type": "announcement", "data": {}}]
    assert dead not in hub.clients
