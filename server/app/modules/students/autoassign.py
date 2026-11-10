"""Bus auto-assignment on approval (v13-spec decision 3).

`choose_bus` is a pure function so the rule is unit-tested without a database:
  1. the bus matching the student's requested label (label or plate, case-insensitive) that has a free seat;
  2. else the bus with the most free seats (ties: label, then id, so the choice is deterministic);
  3. else None (the caller answers 409 NO_SEAT).
A bus without a capacity set never has a seat.
"""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

import asyncpg


@dataclass(frozen=True, slots=True)
class Candidate:
    bus_id: UUID
    label: str
    plate: str
    capacity: int | None
    assigned: int

    @property
    def free(self) -> int:
        return 0 if self.capacity is None else max(0, self.capacity - self.assigned)


def _same(a: str | None, b: str | None) -> bool:
    return bool(a) and bool(b) and a.strip().casefold() == b.strip().casefold()


def choose_bus(candidates: list[Candidate], requested_label: str | None) -> Candidate | None:
    free = [c for c in candidates if c.free > 0]
    if not free:
        return None
    if requested_label:
        for c in sorted(free, key=lambda c: (c.label, str(c.bus_id))):
            if _same(c.label, requested_label) or _same(c.plate, requested_label):
                return c
    return min(free, key=lambda c: (-c.free, c.label, str(c.bus_id)))


async def serving_candidates(con: asyncpg.Connection, route_id: UUID, student_id: UUID) -> list[Candidate]:
    """Active buses that serve `route_id` (default route, or a route their driver is assigned to), with the
    number of OTHER approved students already on each."""
    rows = await con.fetch(
        """select b.id, b.label, b.plate, b.capacity,
                  (select count(*)::int from public.student_profiles sp
                    where sp.bus_id = b.id and sp.status = 'approved' and sp.user_id <> $2) as assigned
             from public.buses b
            where b.active
              and (b.default_route_id = $1
                   or exists (select 1 from public.driver_route_assignments dra
                               where dra.driver_id = b.driver_id and dra.route_id = $1))""",
        route_id, student_id)
    return [Candidate(r["id"], r["label"], r["plate"], r["capacity"], r["assigned"]) for r in rows]
