"""Straight-line distance and the bounding box used to pre-filter students (TRD p.3-4)."""

from __future__ import annotations

import math

EARTH_RADIUS_M = 6_371_008.8
METRES_PER_DEG_LAT = math.pi * EARTH_RADIUS_M / 180  # same sphere as haversine_m


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def bounding_box(lat: float, lng: float, radius_m: float) -> tuple[float, float, float, float]:
    """(min_lat, max_lat, min_lng, max_lng) enclosing a circle of `radius_m` (slightly generous)."""
    dlat = radius_m / METRES_PER_DEG_LAT
    dlng = radius_m / (METRES_PER_DEG_LAT * max(math.cos(math.radians(lat)), 0.01))
    return lat - dlat, lat + dlat, lng - dlng, lng + dlng


def offset(lat: float, lng: float, north_m: float = 0.0, east_m: float = 0.0) -> tuple[float, float]:
    """A point `north_m`/`east_m` metres away (for simulations and tests)."""
    return (lat + north_m / METRES_PER_DEG_LAT,
            lng + east_m / (METRES_PER_DEG_LAT * math.cos(math.radians(lat))))
