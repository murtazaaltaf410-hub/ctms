"""Injectable wall clock (ADR-4).

All Phase 3 code reads time through `clock.now()` so tests can freeze and advance
it (TC8 stale/offline, T2 auto-close) without sleeping:

    from app import clock
    fake = clock.FakeClock(start)
    monkeypatch.setattr(clock, "_source", fake)
    fake.advance(31)
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, datetime, timedelta


def _system_now() -> datetime:
    return datetime.now(UTC)


_source: Callable[[], datetime] = _system_now


def now() -> datetime:
    return _source()


class FakeClock:
    def __init__(self, start: datetime | None = None) -> None:
        self.current = start or datetime.now(UTC)

    def __call__(self) -> datetime:
        return self.current

    def advance(self, seconds: float) -> datetime:
        self.current += timedelta(seconds=seconds)
        return self.current
