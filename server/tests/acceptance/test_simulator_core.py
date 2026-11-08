"""The simulator's pure core (scripts/simulate.py): geometry, fix stream, batching, CLI parsing."""

from __future__ import annotations

import itertools
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from app.geo import haversine_m
from app.geo.polyline import encode
from scripts.simulate import (
    Batch,
    DriveConfig,
    Dropout,
    Route,
    StatusChange,
    batches,
    build_parser,
    decode_polyline,
    drive,
    driven_distance_m,
    load_route_file,
    parse_mmss,
    parse_status,
    timeline,
)
from tests.acceptance.sim_support import L_ROUTE

T0 = datetime(2026, 11, 4, 9, 30, tzinfo=UTC)
ROUTES_DIR = Path(__file__).resolve().parents[2] / "scripts" / "routes"


def test_polyline_decoder_matches_the_server_encoder():
    assert decode_polyline(encode(L_ROUTE)) == L_ROUTE
    # Google's documented example.
    assert decode_polyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@") == [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]


def test_route_interpolation_and_heading():
    route = Route(L_ROUTE)
    assert route.length_m == pytest.approx(1500 + 1500, rel=0.02)
    lat, lng, heading = route.at(0)
    assert (lat, lng, heading) == (*L_ROUTE[0], 0.0)
    lat, lng, heading = route.at(route.length_m - 1)
    assert heading == pytest.approx(90.0, abs=0.5)
    assert route.at(route.length_m + 500)[:2] == pytest.approx(L_ROUTE[-1])
    mid = route.at(750)
    assert haversine_m(*L_ROUTE[0], mid[0], mid[1]) == pytest.approx(750, abs=1)
    with pytest.raises(ValueError):
        Route([(34.0, 74.0), (34.0, 74.0)])


def test_drive_emits_timed_fixes_to_the_end_of_the_route():
    route = Route(L_ROUTE)
    fixes = list(drive(route, DriveConfig(speed_kmh=36, fix_every_s=3), T0))   # 10 m/s
    assert fixes[0].t == 0 and fixes[0].recorded_at == T0 and fixes[0].along_m == 0
    assert all(b.t - a.t <= 3 + 1e-9 for a, b in itertools.pairwise(fixes))
    assert fixes[-1].along_m == pytest.approx(route.length_m)
    assert fixes[-1].t == pytest.approx(route.length_m / 10)
    assert fixes[5].recorded_at == T0 + timedelta(seconds=15) and fixes[5].speed == pytest.approx(10)
    assert len({f.fix_id for f in fixes}) == len(fixes)
    assert all(f.kind == "good" and f.expected is None for f in fixes)
    payload = fixes[1].payload()
    assert set(payload) == {"fix_id", "lat", "lng", "accuracy", "speed", "heading", "recorded_at"}
    assert payload["recorded_at"] == "2026-11-04T09:30:03Z"
    # Distance between consecutive fixes = the odometer, except the corner is cut a little.
    assert driven_distance_m(fixes) == pytest.approx(route.length_m, rel=0.002)


def test_minutes_longer_than_the_route_parks_at_the_end():
    route = Route(L_ROUTE)
    fixes = list(drive(route, DriveConfig(speed_kmh=36, fix_every_s=5, minutes=10), T0))
    assert fixes[-1].t == 600
    parked = [f for f in fixes if f.along_m >= route.length_m]
    assert len(parked) > 50 and all(f.speed == 0 for f in parked)
    assert len({(f.lat, f.lng) for f in parked}) == 1


def test_faults_every_n_never_the_first_fix():
    route = Route(L_ROUTE)
    cfg = DriveConfig(speed_kmh=30, fix_every_s=3, minutes=2, bad_accuracy_every=4, spike_every=5,
                      duplicate_every=3)
    fixes = list(drive(route, cfg, T0))
    by_kind = {k: [f for f in fixes if f.kind == k] for k in ("good", "bad_accuracy", "spike", "duplicate")}
    assert fixes[0].kind == "good"
    assert all(f.seq % 5 == 0 for f in by_kind["spike"])
    assert all(f.seq % 4 == 0 and f.seq % 5 for f in by_kind["bad_accuracy"])   # a spike wins a tie
    assert all(f.accuracy == 80 and f.expected == "ACCURACY_TOO_LOW" for f in by_kind["bad_accuracy"])
    for spike in by_kind["spike"]:
        lat, lng, _ = route.at(spike.along_m)
        assert haversine_m(lat, lng, spike.lat, spike.lng) == pytest.approx(2000, rel=0.01)
        assert spike.expected == "SPEED_IMPLAUSIBLE"
    for dup in by_kind["duplicate"]:
        original = next(f for f in fixes if f.fix_id == dup.fix_id and f.kind == "good")
        assert dup.seq % 3 == 0 and dup.payload() == original.payload() and dup.expected == "DUPLICATE"
    # Every N-th fix where N=1 still leaves the first fix good.
    assert next(drive(route, DriveConfig(spike_every=1), T0)).kind == "good"


def test_batches_upload_every_interval_in_order():
    fixes = list(drive(Route(L_ROUTE), DriveConfig(speed_kmh=30, fix_every_s=2, minutes=1), T0))
    out = list(batches(fixes, interval_s=6))
    assert out[0].send_t == 0 and [f.t for f in out[0].fixes] == [0]
    assert [b.send_t for b in out[:4]] == [0, 6, 12, 18]
    assert [f.t for f in out[1].fixes] == [2, 4, 6]
    sent = [f for b in out for f in b.fixes]
    assert sent == fixes and not any(b.backlog for b in out)
    assert all(f.t <= b.send_t for b in out for f in b.fixes)


def test_dropout_buffers_then_uploads_in_order_in_chunks():
    fixes = list(drive(Route(L_ROUTE), DriveConfig(speed_kmh=30, fix_every_s=3, minutes=6), T0))
    out = list(batches(fixes, interval_s=5, dropouts=[Dropout(60, 180)], batch_max=20))
    assert not [b for b in out if 60 <= b.send_t < 240]
    catch_up = [b for b in out if b.send_t == 240]
    assert len(catch_up) == 4 and all(b.backlog for b in catch_up)        # fixes 57..240 s = 62 -> 20+20+20+2
    assert [len(b.fixes) for b in catch_up] == [20, 20, 20, 2]
    assert [f for b in out for f in b.fixes] == fixes                      # nothing lost or reordered
    after = [b for b in out if b.send_t > 240]
    assert after and not any(b.backlog for b in after)


def test_timeline_puts_status_changes_in_time_order():
    fixes = list(drive(Route(L_ROUTE), DriveConfig(minutes=1), T0))
    statuses = [StatusChange(25, "delayed", "Traffic"), StatusChange(10, "on_time")]
    events = timeline(batches(fixes, interval_s=10), statuses)
    times = [e.t for e in events]
    assert times == sorted(times)
    at10 = [e.item for e in events if e.t == 10]
    assert isinstance(at10[0], StatusChange) and isinstance(at10[1], Batch)


def test_cli_parsing_helpers():
    assert parse_mmss("01:30") == 90 and parse_mmss("75") == 75 and parse_mmss("1:00:05") == 3605
    assert parse_status("delayed@01:30") == StatusChange(90, "delayed", None)
    assert parse_status("breakdown@2:00@Flat tyre") == StatusChange(120, "breakdown", "Flat tyre")
    args = build_parser().parse_args(["--phone", "+910000000001", "--dropout", "30:60", "--dropout", "300:30",
                                      "--status", "delayed@00:45", "--no-end", "--time-scale", "10"])
    assert args.dropout == [Dropout(30, 60), Dropout(300, 30)] and args.end is False and args.time_scale == 10
    assert args.status == [StatusChange(45, "delayed", None)] and args.interval == 5 and args.fix_every == 3
    with pytest.raises(SystemExit):
        build_parser().parse_args(["--status", "parked@00:10"])


def test_sample_route_files_load():
    gpx = load_route_file(ROUTES_DIR / "campus_loop.gpx")
    assert len(gpx) == 11 and gpx[0] == gpx[-1] and Route(gpx).length_m > 3000
    demo = load_route_file(ROUTES_DIR / "north_campus.json")
    # Same geometry as the demo route in supabase/migrations/0003_seed.sql.
    assert demo == decode_polyline("ofhoEwewgMsDsDsDsDiDkCiDkCgEiDgEiD")
