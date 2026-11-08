"""ETA formula (TC12), cap (A9), passed stops, and GET /stops/{id}/eta."""

from __future__ import annotations

from datetime import time, timedelta
from zoneinfo import ZoneInfo

import pytest

from app.modules.eta.service import compute_eta
from tests.conftest import bearer
from tests.tracking_support import along_fix

pytest_plugins = ["tests.tracking_support"]

V_MIN = 10 / 3.6
CAP = 1800


@pytest.mark.parametrize(("remaining", "speed"), [(500, 5.0), (1200, 8.3), (300, 12.0), (2000, 6.5)])
def test_tc12_eta_matches_formula_within_5_percent(remaining, speed):
    eta = compute_eta(1000 + remaining, 1000, speed, v_min_mps=V_MIN, cap_s=CAP, passed_tolerance_m=25)
    expected = remaining / max(speed, V_MIN)
    assert not eta.passed and not eta.capped
    assert abs(eta.eta_seconds - expected) <= 0.05 * expected
    assert eta.distance_m == remaining


def test_v_min_floor_for_slow_bus():
    eta = compute_eta(900, 0, 0.1, v_min_mps=V_MIN, cap_s=CAP, passed_tolerance_m=25)
    assert eta.eta_seconds == round(900 / V_MIN)


def test_a9_stationary_bus_is_capped():
    eta = compute_eta(6000, 0, 0.0, v_min_mps=V_MIN, cap_s=CAP, passed_tolerance_m=25)
    assert eta.capped and eta.eta_seconds == CAP


def test_passed_stop_and_tolerance():
    assert compute_eta(100, 200, 5, v_min_mps=V_MIN, cap_s=CAP, passed_tolerance_m=25).passed
    at_stop = compute_eta(100, 110, 5, v_min_mps=V_MIN, cap_s=CAP, passed_tolerance_m=25)
    assert not at_stop.passed and at_stop.eta_seconds == 0


async def test_stop_eta_without_buses_returns_empty_list_and_next_scheduled(
    client, con, live_app, make_route, google_login, fake_clock
):
    route = await make_route()
    tz = ZoneInfo("Asia/Kolkata")
    slot_local = (fake_clock.current.astimezone(tz) + timedelta(hours=2)).time().replace(second=0)
    await con.execute(
        "insert into public.schedules (route_id, departure_time, days_of_week) values ($1, $2, '{1,2,3,4,5,6,7}')",
        route["id"],
        time(slot_local.hour, slot_local.minute),
    )
    student = await google_login()
    resp = await client.get(f"/api/v1/stops/{route['stops'][1]}/eta", headers=bearer(student["access_token"]))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["etas"] == []
    assert body["next_scheduled"] is not None and body["next_scheduled"].endswith("Z")


async def test_stop_eta_unknown_stop_is_404(client, live_app, google_login):
    student = await google_login()
    resp = await client.get(
        "/api/v1/stops/00000000-0000-4000-8000-000000000999/eta", headers=bearer(student["access_token"])
    )
    assert resp.status_code == 404


async def test_stop_eta_for_moving_bus_and_passed_stop(
    client, live_app, driver_with_bus, start_trip, post_fixes, google_login, fake_clock
):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    t0 = fake_clock.current
    # Constant 10 m/s from 100 m to 300 m along the route.
    await post_fixes(
        driver, trip["id"], [along_fix(100 + 10 * i, t0 + timedelta(seconds=i), speed=10.0) for i in range(0, 21, 4)]
    )
    student = await google_login()
    stops = driver["route"]["stops"]  # at 0 m, 555 m, end
    passed = (await client.get(f"/api/v1/stops/{stops[0]}/eta", headers=bearer(student["access_token"]))).json()
    ahead = (await client.get(f"/api/v1/stops/{stops[1]}/eta", headers=bearer(student["access_token"]))).json()
    assert passed["etas"][0]["passed"] is True and passed["etas"][0]["eta_seconds"] is None
    item = ahead["etas"][0]
    assert item["passed"] is False and item["bus_id"] == trip["bus_id"]
    assert item["distance_m"] == pytest.approx(555 - 300, abs=3)
    assert item["eta_seconds"] == pytest.approx((555 - 300) / 10.0, rel=0.05)
    assert item["state"] == "live" and item["trip_type"] == "ad_hoc"
