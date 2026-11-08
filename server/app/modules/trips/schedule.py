"""Timetable matching. Slots are LOCAL times (settings `timezone`) on ISO weekdays
(1 = Mon .. 7 = Sun), per the schema comment on public.schedules."""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime, time, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo


@dataclass(frozen=True)
class Slot:
    schedule_id: UUID
    departure_time: time
    days_of_week: tuple[int, ...]


def _occurrences(slot: Slot, around: datetime, tz: ZoneInfo, day_offsets: Iterable[int]) -> Iterable[datetime]:
    local_day = around.astimezone(tz).date()
    for offset in day_offsets:
        day = local_day + timedelta(days=offset)
        if day.isoweekday() in slot.days_of_week:
            yield datetime.combine(day, slot.departure_time, tzinfo=tz).astimezone(UTC)


def nearest_slot(slots: Iterable[Slot], at: datetime, tz: ZoneInfo,
                 window_s: float) -> tuple[Slot, datetime] | None:
    """The slot occurrence closest to `at`, if within `window_s` (else ad hoc)."""
    best: tuple[float, Slot, datetime] | None = None
    for slot in slots:
        for when in _occurrences(slot, at, tz, (-1, 0, 1)):
            diff = abs((when - at).total_seconds())
            if diff <= window_s and (best is None or diff < best[0]):
                best = (diff, slot, when)
    return None if best is None else (best[1], best[2])


def next_departure(slots: Iterable[Slot], after: datetime, tz: ZoneInfo) -> datetime | None:
    upcoming = [when for slot in slots for when in _occurrences(slot, after, tz, range(8)) if when > after]
    return min(upcoming, default=None)


def slot_occurrence(departure_time: time, started_at: datetime, tz: ZoneInfo) -> datetime:
    """The occurrence of a slot time nearest to a trip start (for scheduled_departure)."""
    slot = Slot(UUID(int=0), departure_time, (1, 2, 3, 4, 5, 6, 7))
    return min(_occurrences(slot, started_at, tz, (-1, 0, 1)),
               key=lambda when: abs((when - started_at).total_seconds()))
