"""Polyline codec (Google's documented example), haversine, forward-only snapping."""

from __future__ import annotations

import pytest

from app.geo import cumulative_distances, haversine_m
from app.geo.polyline import PolylineError, decode, encode
from app.geo.snap import snap_forward

GOOGLE_EXAMPLE = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
GOOGLE_POINTS = [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]


def test_decode_google_documented_example():
    assert decode(GOOGLE_EXAMPLE) == GOOGLE_POINTS


def test_encode_google_documented_example_and_roundtrip():
    assert encode(GOOGLE_POINTS) == GOOGLE_EXAMPLE
    pts = [(34.12601, 74.83499), (34.0, 74.0), (-33.86, 151.21), (0.0, 0.0)]
    assert decode(encode(pts)) == pts


def test_decode_rejects_garbage():
    with pytest.raises(PolylineError):
        decode("_p~iF~ps|U_")  # truncated


def test_demo_seed_route_cumulative_distances_match():
    pts = decode("ofhoEwewgMsDsDsDsDiDkCiDkCgEiDgEiD")
    cum = cumulative_distances(pts)
    assert len(pts) == 7
    seed = [0.0, 129.9, 259.8, 374.2, 488.6, 624.6, 760.6]
    assert all(abs(a - b) < 0.5 for a, b in zip(cum, seed, strict=True))


def test_haversine_one_millidegree_latitude():
    assert haversine_m(34.0, 74.0, 34.001, 74.0) == pytest.approx(111.2, abs=0.2)


def _line(n):
    pts = [(34.0 + i * 0.001, 74.0) for i in range(n)]
    return pts, cumulative_distances(pts)


def test_snap_projects_onto_segment():
    pts, cum = _line(5)
    snap = snap_forward(pts, cum, 34.0015, 74.0001)
    assert snap.index == 1
    assert snap.along_m == pytest.approx(cum[1] + (cum[2] - cum[1]) / 2, abs=1)
    assert snap.offset_m == pytest.approx(9.2, abs=0.5)


def test_snap_never_moves_backwards():
    pts, cum = _line(5)
    snap = snap_forward(pts, cum, 34.0005, 74.0, start_index=3)  # position behind the last snap
    assert snap.index == 3 and snap.along_m == pytest.approx(cum[3])


def test_snap_on_loop_prefers_earlier_pass():
    # Out north 0.002 deg, then back south on the same road: the return leg overlaps.
    pts = [(34.0, 74.0), (34.001, 74.0), (34.002, 74.0), (34.001, 74.00001), (34.0, 74.00002)]
    cum = cumulative_distances(pts)
    first = snap_forward(pts, cum, 34.0009, 74.0, start_index=0)
    assert first.index == 0  # outbound leg, not the return leg
    later = snap_forward(pts, cum, 34.0005, 74.000015, start_index=2)
    assert later.index == 3  # on the way back, forward search only sees the return leg
