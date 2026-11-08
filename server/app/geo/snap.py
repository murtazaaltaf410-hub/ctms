"""Forward-only snapping of a position onto a route polyline (TRD p.3 ETA step 1).

The search starts at the bus's last snapped segment and only moves forward, so a
route that loops back or runs beside itself never makes the bus jump backwards.
Among forward segments the nearest wins, but an earlier segment within
`tie_tolerance_m` of the best is preferred, so a later pass of a loop does not
steal the snap.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.geo import to_local_xy


@dataclass(frozen=True)
class Snap:
    index: int          # segment start index (points[index] -> points[index + 1])
    along_m: float      # cumulative distance of the snapped point
    offset_m: float     # perpendicular distance from the route


def snap_forward(points: list[tuple[float, float]], cum: list[float], lat: float, lng: float,
                 start_index: int = 0, tie_tolerance_m: float = 25.0) -> Snap:
    if not points:
        raise ValueError("empty route")
    if len(points) == 1:
        x, y = to_local_xy(lat, lng, points[0][0], points[0][1])
        return Snap(0, cum[0], (x * x + y * y) ** 0.5)
    start = max(0, min(start_index, len(points) - 2))
    candidates: list[Snap] = []
    for i in range(start, len(points) - 1):
        a_lat, a_lng = points[i]
        bx, by = to_local_xy(points[i + 1][0], points[i + 1][1], a_lat, a_lng)
        px, py = to_local_xy(lat, lng, a_lat, a_lng)
        seg2 = bx * bx + by * by
        t = 0.0 if seg2 == 0 else max(0.0, min(1.0, (px * bx + py * by) / seg2))
        dx, dy = px - t * bx, py - t * by
        along = cum[i] + t * (cum[i + 1] - cum[i])
        candidates.append(Snap(i, along, (dx * dx + dy * dy) ** 0.5))
    best = min(c.offset_m for c in candidates)
    return next(c for c in candidates if c.offset_m <= best + tie_tolerance_m)
