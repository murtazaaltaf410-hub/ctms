"""Private geo helpers for route generation (P5). Follow-up: switch to `app.geo` once P3 lands it.

Encoded Polyline Algorithm Format, precision 1e5
(developers.google.com/maps/documentation/utilities/polylinealgorithm).
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from itertools import pairwise

EARTH_RADIUS_M = 6_371_008.8

LatLng = tuple[float, float]


def _encode_value(value: int) -> str:
    value = ~(value << 1) if value < 0 else value << 1
    out = []
    while value >= 0x20:
        out.append(chr((0x20 | (value & 0x1F)) + 63))
        value >>= 5
    out.append(chr(value + 63))
    return "".join(out)


def encode_polyline(points: Sequence[LatLng]) -> str:
    out, prev_lat, prev_lng = [], 0, 0
    for lat, lng in points:
        ilat, ilng = round(lat * 1e5), round(lng * 1e5)
        out.append(_encode_value(ilat - prev_lat))
        out.append(_encode_value(ilng - prev_lng))
        prev_lat, prev_lng = ilat, ilng
    return "".join(out)


def decode_polyline(encoded: str) -> list[LatLng]:
    points: list[LatLng] = []
    index, lat, lng = 0, 0, 0
    while index < len(encoded):
        deltas = []
        for _ in range(2):
            shift, result = 0, 0
            while True:
                if index >= len(encoded):
                    raise ValueError("truncated polyline")
                byte = ord(encoded[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            deltas.append(~(result >> 1) if result & 1 else result >> 1)
        lat += deltas[0]
        lng += deltas[1]
        points.append((lat / 1e5, lng / 1e5))
    return points


def haversine_m(a: LatLng, b: LatLng) -> float:
    lat1, lng1, lat2, lng2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(h))


def cumulative_distances(points: Sequence[LatLng]) -> list[float]:
    cum = [0.0]
    for prev, cur in pairwise(points):
        cum.append(cum[-1] + haversine_m(prev, cur))
    return cum


def _project_on_segment(p: LatLng, a: LatLng, b: LatLng) -> tuple[float, float]:
    """(distance from p to segment a-b in metres, fraction t along the segment), local flat projection."""
    k = math.radians(1) * EARTH_RADIUS_M
    cos_lat = math.cos(math.radians(a[0]))
    bx, by = (b[1] - a[1]) * cos_lat * k, (b[0] - a[0]) * k
    px, py = (p[1] - a[1]) * cos_lat * k, (p[0] - a[0]) * k
    seg2 = bx * bx + by * by
    t = 0.0 if seg2 == 0 else max(0.0, min(1.0, (px * bx + py * by) / seg2))
    return math.hypot(px - t * bx, py - t * by), t


def project_stops(points: Sequence[LatLng], cum: Sequence[float], stops: Sequence[LatLng]) -> list[float]:
    """Distance along the polyline of each stop, searching forward only so the order is kept."""
    if len(points) < 2:
        return [0.0 for _ in stops]
    result: list[float] = []
    start = 0
    for stop in stops:
        best = (math.inf, start, 0.0)
        for i in range(start, len(points) - 1):
            dist, t = _project_on_segment(stop, points[i], points[i + 1])
            if dist < best[0]:
                best = (dist, i, t)
        _, seg, t = best
        along = cum[seg] + t * (cum[seg + 1] - cum[seg])
        result.append(max(along, result[-1]) if result else along)
        start = seg
    return result
