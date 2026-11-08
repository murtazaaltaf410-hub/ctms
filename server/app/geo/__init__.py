"""Small geodesy helpers: haversine distance and the local metric projection used
for snapping. Good to well under 1 m over a campus-sized route."""

from __future__ import annotations

import math

EARTH_RADIUS_M = 6_371_008.8


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def cumulative_distances(points: list[tuple[float, float]]) -> list[float]:
    """Cumulative haversine distance (m) at every point; the first is 0."""
    out: list[float] = []
    total = 0.0
    for i, (lat, lng) in enumerate(points):
        if i:
            total += haversine_m(points[i - 1][0], points[i - 1][1], lat, lng)
        out.append(total)
    return out


def to_local_xy(lat: float, lng: float, lat0: float, lng0: float) -> tuple[float, float]:
    """Equirectangular projection around (lat0, lng0), in metres."""
    x = math.radians(lng - lng0) * math.cos(math.radians(lat0)) * EARTH_RADIUS_M
    y = math.radians(lat - lat0) * EARTH_RADIUS_M
    return x, y
