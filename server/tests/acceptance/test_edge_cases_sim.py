"""Edge cases driven end to end by the simulator: T2, T13, T14, EC-A4, EC-A8."""

from __future__ import annotations

from datetime import timedelta
from uuid import UUID

from app.jobs.trips import auto_close_tick
from app.live.writer import get_writer
from scripts.simulate import StatusChange
from tests.acceptance.sim_support import alert_student, drain_alerts, live_bus, plan, stop_eta


async def test_t2_driver_forgets_to_end_trip_auto_closed_after_15_min(client, con, live_app, admin, sim_trip):
    _, adm = await admin()
    route, driver, trip, player = await sim_trip()
    fixes, events = plan(route.geom, player.start, speed_kmh=30, interval_s=5, minutes=3)
    await player.play(events)
    last = events[-1].t
    player.move_clock(last + 14 * 60 + 59)
    assert await auto_close_tick(live_app) == 0
    player.move_clock(last + 15 * 60)
    assert await auto_close_tick(live_app) == 1
    assert await live_bus(client, driver["headers"], trip["bus_id"]) is None
    assert (await client.get("/api/v1/trips/active", headers=driver["headers"])).json() is None
    [row] = (await client.get("/api/v1/admin/trips", headers=adm)).json()["items"]
    assert row["closed_by"] == "auto" and row["ended_at"] == player.at(last).isoformat().replace("+00:00", "Z")
    assert abs(row["distance_m"] - fixes[-1].along_m) <= fixes[-1].along_m * 0.02


async def test_t13_phone_clock_running_ahead_like_time_scale(client, live_app, sim_trip):
    """What `simulate.py --time-scale 5` produces: phone timestamps run ahead of server time.
    Fixes are still accepted, freshness uses receive time, and the skew is flagged."""
    route, driver, trip, player = await sim_trip()
    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=10, minutes=4)
    for ev in events:
        player.move_clock(ev.t / 5)  # wall clock runs 5x slower than simulated time
        resp = await client.post(
            f"/api/v1/trips/{trip['id']}/locations", json=ev.item.payload, headers=driver["headers"]
        )
        assert resp.status_code == 200 and not resp.json()["rejected"], resp.text
    bus = await live_bus(client, driver["headers"], trip["bus_id"])
    assert bus["state"] == "live" and bus["clock_skew_s"] is not None and bus["clock_skew_s"] < -30
    assert bus["last_fix_at"] == player.at(events[-1].t / 5).isoformat().replace("+00:00", "Z")


async def test_t14_parked_with_engine_running_is_stopped_not_offline(client, live_app, sim_trip):
    route, driver, trip, player = await sim_trip()
    # --minutes beyond the end of the route: the bus parks at the last stop and keeps reporting.
    _, events = plan(route.geom, player.start, speed_kmh=40, interval_s=5, minutes=12)
    await player.play(events)
    bus = await live_bus(client, driver["headers"], trip["bus_id"])
    assert bus["state"] == "stopped" and bus["speed"] < 0.5


async def test_ec_a4_two_buses_within_a_minute_give_one_combined_alert(
    client, live_app, push, sim_trip, sim_route, google_login, fake_clock
):
    route = await sim_route()
    _, _d1, _t1, p1 = await sim_trip(route=route, label="Bus 1")
    _, _d2, _t2, p2 = await sim_trip(route=route, label="Bus 2")
    p2.start = p1.start + timedelta(seconds=20)  # the second bus follows 20 s behind
    s = await alert_student(client, google_login, 51, *route.stop_point(2))
    _, e1 = plan(route.geom, p1.start, speed_kmh=30, interval_s=10)
    _, e2 = plan(route.geom, p2.start, speed_kmh=30, interval_s=10)
    # Interleave the two drivers' uploads in wall-clock order.
    merged = sorted([(p1.at(e.t), p1, e) for e in e1] + [(p2.at(e.t), p2, e) for e in e2], key=lambda x: x[0])
    for _, player, ev in merged:
        await player.play([ev])
        await drain_alerts(live_app)
    mine = [m for m in push.sent if m.token == s.push_token]
    assert [m.title for m in mine] == ["Bus nearby", "2 buses are nearby"]
    assert mine[1].tag == mine[0].tag == "nearby_alert"  # the second replaces the first on the phone
    assert "Bus 1" in mine[1].body and "Bus 2" in mine[1].body


async def test_ec_a8_breakdown_status_stops_alerts_and_shows_status(client, live_app, push, sim_trip, google_login):
    route, _driver, trip, player = await sim_trip()
    s = await alert_student(client, google_login, 52, *route.stop_point(3))
    _, events = plan(
        route.geom,
        player.start,
        speed_kmh=30,
        interval_s=10,
        statuses=[StatusChange(60, "breakdown", "Engine trouble")],
    )

    async def after(upload):
        await drain_alerts(live_app)

    await player.play(events, after=after)
    assert not [m for m in push.sent if m.token == s.push_token]
    [eta] = (await stop_eta(client, s.headers, route.stops[-1]))["etas"]
    assert eta["status"] == "breakdown" and eta["note"] == "Engine trouble"
    bus = await live_bus(client, s.headers, trip["bus_id"])
    assert bus["status"] == "breakdown"


async def test_n6_n5_history_complete_after_simulated_drive(con, live_app, sim_trip):
    """The batched writer stores every accepted fix exactly once over a long drive with faults."""
    route, _driver, trip, player = await sim_trip()
    fixes, events = plan(route.geom, player.start, speed_kmh=30, interval_s=5, duplicate_every=3, bad_accuracy_every=7)
    await player.play(events)
    await get_writer(live_app).flush(live_app)
    stored = await con.fetchval("select count(*) from public.locations where trip_id = $1", UUID(trip["id"]))
    assert stored == sum(f.kind == "good" for f in fixes)
