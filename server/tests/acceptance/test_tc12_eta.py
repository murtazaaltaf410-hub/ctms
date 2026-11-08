"""TC12 (+ EC-A9): with the bus at known distances from a stop at fixed speeds, the ETA from
`GET /stops/{id}/eta` matches ETA = remaining distance / max(speed, v_min) within 5 %."""

from __future__ import annotations

import pytest

from tests.acceptance.sim_support import plan, stop_eta, within

V_MIN_MPS = 10 / 3.6
CAP_S = 1800


@pytest.mark.parametrize("speed_kmh", [15, 30, 45])
async def test_tc12_eta_matches_formula_within_5_percent(client, live_app, sim_trip, google_login, speed_kmh):
    route, _driver, _trip, player = await sim_trip()
    headers = {"Authorization": f"Bearer {(await google_login())['access_token']}"}
    target = len(route.stops) - 2                       # the stop at 2250 m, past the corner
    stop_along = route.stop_along[target]
    _, events = plan(route.geom, player.start, speed_kmh=speed_kmh, fix_every_s=3, interval_s=6)
    v = speed_kmh / 3.6
    checked = []

    async def check(upload):
        bus_along = upload.batch.fixes[-1].along_m
        remaining = stop_along - bus_along
        [eta] = (await stop_eta(client, headers, route.stops[target]))["etas"]
        if remaining > 50:
            expected = remaining / max(v, V_MIN_MPS)
            assert not eta["passed"]
            assert within(eta["eta_seconds"], min(expected, CAP_S), 5), (bus_along, eta, expected)
            assert within(eta["distance_m"], remaining, 5)
            checked.append(remaining)
        elif remaining < -30:
            assert eta["passed"] and eta["eta_seconds"] is None

    await player.play(events, after=check)
    assert len(checked) > 10 and max(checked) > 2000


async def test_tc12_slow_bus_uses_v_min(client, live_app, sim_trip, google_login):
    route, _driver, _trip, player = await sim_trip()
    headers = {"Authorization": f"Bearer {(await google_login())['access_token']}"}
    last_stop = route.stops[-1]
    # 5 km/h is below v_min (10 km/h): the ETA uses v_min.
    _, events = plan(route.geom, player.start, speed_kmh=5, fix_every_s=3, interval_s=6, minutes=2)
    uploads = await player.play(events)
    bus_along = uploads[-1].batch.fixes[-1].along_m
    [eta] = (await stop_eta(client, headers, last_stop))["etas"]
    remaining = route.stop_along[-1] - bus_along
    assert within(eta["eta_seconds"], min(remaining / V_MIN_MPS, CAP_S), 5)


async def test_a9_parked_bus_eta_is_capped_at_30_min(client, live_app, sim_trip, google_login, sim_route):
    """EC-A9: a long route and a stationary bus give the 30-minute cap with `capped`, not a growing number."""
    long_route = await sim_route([(34.1200, 74.8300), (34.1650, 74.8300)], [0.0, None])   # ~5 km straight
    route, _driver, _trip, player = await sim_trip(route=long_route)
    headers = {"Authorization": f"Bearer {(await google_login())['access_token']}"}
    _, events = plan(route.geom, player.start, speed_kmh=0.01, fix_every_s=5, interval_s=10, minutes=3)
    await player.play(events)
    [eta] = (await stop_eta(client, headers, route.stops[-1]))["etas"]
    assert eta["capped"] is True and eta["eta_seconds"] == CAP_S and eta["state"] == "stopped"
