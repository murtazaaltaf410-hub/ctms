"""Google Encoded Polyline Algorithm Format (precision 1e5), in-house.

Spec: developers.google.com/maps/documentation/utilities/polylinealgorithm.
Written here instead of depending on a package context7 cannot confirm
(docs/v1/allowed-apis.md); tested against Google's documented example.
"""

from __future__ import annotations

PRECISION = 1e5


class PolylineError(ValueError):
    pass


def decode(encoded: str) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    index, lat, lng, n = 0, 0, 0, len(encoded)
    while index < n:
        deltas = []
        for _ in range(2):
            shift = result = 0
            while True:
                if index >= n:
                    raise PolylineError("truncated polyline")
                b = ord(encoded[index]) - 63
                index += 1
                if b < 0 or b > 63:
                    raise PolylineError("invalid polyline character")
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            deltas.append(~(result >> 1) if result & 1 else result >> 1)
        lat += deltas[0]
        lng += deltas[1]
        points.append((lat / PRECISION, lng / PRECISION))
    return points


def _encode_value(value: int) -> str:
    value = ~(value << 1) if value < 0 else value << 1
    chunks = []
    while value >= 0x20:
        chunks.append(chr((0x20 | (value & 0x1F)) + 63))
        value >>= 5
    chunks.append(chr(value + 63))
    return "".join(chunks)


def encode(points: list[tuple[float, float]]) -> str:
    out: list[str] = []
    prev_lat = prev_lng = 0
    for lat, lng in points:
        ilat, ilng = round(lat * PRECISION), round(lng * PRECISION)
        out.append(_encode_value(ilat - prev_lat))
        out.append(_encode_value(ilng - prev_lng))
        prev_lat, prev_lng = ilat, ilng
    return "".join(out)
