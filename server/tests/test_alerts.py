"""Nearby-bus alert engine: TC13, TC14, A1-A5, A8, U2 (TRD p.3-4, edge cases)."""
# ruff: noqa: F811  (pytest fixtures imported from tests.alerts_support)

from __future__ import annotations

from uuid import UUID

import pytest

from app import clock
from app.live.hooks import TripEvent, emit_fix, emit_trip
from app.modules.alerts.engine import ALERT_TAG, alert_text
from tests.alerts_support import (  # noqa: F401  (fixtures)
    alert_count,
    engine,
    push,
    set_location,
    student,
    world,
)
from tests.conftest import bearer
from tests.tracking_support import fake_clock  # noqa: F401


@pytest.fixture(autouse=True)
def _frozen(fake_clock):
    """Every test here runs on a frozen `app.clock`; `approach` advances it."""
    return fake_clock


async def approach(app, engine, fake_clock, trip, distances, *, step_s=4.0, status="on_time"):
    """Feed fixes at the given distances north of the student, `step_s` apart on the frozen
    clock; returns the students alerted per fix."""
    out = []
    for d in distances:
        out.append(await engine.process(app, trip.fix(d, status=status)))
        fake_clock.advance(step_s)
    return out


def test_alert_text_follows_trd():
    assert alert_text("Bus 2", "North Campus", 400) == "Bus 2 (North Campus route) is about 400 m away"
    assert alert_text("Bus 2", "North Campus Route", 431) == "Bus 2 (North Campus Route) is about 450 m away"
    assert alert_text("Bus 7", "Hazratbal", 12) == "Bus 7 (Hazratbal route) is about 50 m away"


async def test_tc13_approach_600_500_400_sends_exactly_one_alert(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student()
    per_fix = await approach(app, engine, fake_clock, trip, [600, 500, 400, 300, 200])
    assert per_fix == [[], [], [sid], [], []]
    assert await alert_count(con, sid) == 1
    await app.state.push.drain(app)
    assert len(push.sent) == 1
    msg = push.sent[0]
    assert msg.title == "Bus nearby"
    assert msg.body == "Bus 2 (North Campus route) is about 400 m away"
    assert msg.tag == ALERT_TAG
    assert msg.data == {"type": ALERT_TAG, "trip_id": str(trip.trip_id), "bus_id": str(trip.bus_id), "bus_count": "1"}


async def test_alert_radius_comes_from_settings_table(app, con, engine, push, world, student, fake_clock):
    await con.execute("update public.settings set value = '300'::jsonb where key = 'alert_radius_m'")
    app.state.settings_store.invalidate()
    trip = await world()
    sid = await student()
    assert await approach(app, engine, fake_clock, trip, [500, 400, 350, 250]) == [[], [], [], [sid]]


async def test_tc14_a3_bus_moving_away_inside_radius_no_alert(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student()
    assert await approach(app, engine, fake_clock, trip, [200, 300, 400, 450]) == [[]] * 4
    assert await alert_count(con, sid) == 0


async def test_first_fix_inside_radius_waits_for_a_second_fix(app, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student()
    assert await approach(app, engine, fake_clock, trip, [300, 300, 250]) == [[], [], [sid]]


async def test_tc14_a1_student_riding_the_bus_is_suppressed(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student()
    # On board: within 50 m on consecutive fixes, with GPS noise that sometimes "decreases"
    # and once jumps beyond the 50 m rider distance.
    assert await approach(app, engine, fake_clock, trip, [30, 20, 45, 10, 70, 40, 25]) == [[]] * 7
    assert await alert_count(con, sid) == 0
    assert (sid, trip.trip_id) in engine.state.riders


async def test_rider_flag_clears_once_beyond_radius(app, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student()
    await approach(app, engine, fake_clock, trip, [20, 10])
    assert (sid, trip.trip_id) in engine.state.riders
    # Got off; the bus leaves and later comes back on a loop.
    assert await approach(app, engine, fake_clock, trip, [300, 600, 450, 350]) == [[], [], [sid], []]


async def test_a4_two_buses_within_a_minute_give_one_combined_alert(app, con, engine, push, world, student, fake_clock):
    bus2 = await world("Bus 2")
    bus3 = await world("Bus 3", route_id=bus2.route_id)  # a student sees one route; both buses run it
    sid = await student()
    await approach(app, engine, fake_clock, bus2, [600, 420])  # alert at t+4
    fake_clock.advance(12)
    await approach(app, engine, fake_clock, bus3, [600, 380])  # alert at t+24, inside 60 s
    await app.state.push.drain(app)
    assert [m.title for m in push.sent] == ["Bus nearby", "2 buses are nearby"]
    combined = push.sent[1]
    assert combined.body == (
        "Bus 2 (North Campus route) is about 400 m away; Bus 3 (North Campus route) is about 400 m away"
    )
    # Same notification tag: the combined push replaces the first one on the device.
    assert {m.tag for m in push.sent} == {ALERT_TAG}
    assert combined.data["bus_count"] == "2"
    assert await alert_count(con, sid) == 2


async def test_a4_bus_after_the_window_alerts_on_its_own(app, engine, push, world, student, fake_clock):
    bus2 = await world("Bus 2")
    bus3 = await world("Bus 3", route_id=bus2.route_id)
    await student()
    await approach(app, engine, fake_clock, bus2, [600, 420])  # alert at t+4
    fake_clock.advance(53)
    await approach(app, engine, fake_clock, bus3, [600, 380])  # alert at t+65, 61 s later
    await app.state.push.drain(app)
    assert [m.title for m in push.sent] == ["Bus nearby", "Bus nearby"]


async def test_a5_stale_or_inaccurate_student_location_no_alert(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    stale = await student(age_s=301)
    vague = await student(accuracy=100)
    fresh = await student(accuracy=99)
    assert await approach(app, engine, fake_clock, trip, [600, 400]) == [[], [fresh]]
    assert await alert_count(con, stale) == 0
    assert await alert_count(con, vague) == 0


async def test_old_bus_fix_is_ignored(app, engine, push, world, student, fake_clock):
    trip = await world()
    await student()
    old = [trip.fix(600), trip.fix(400)]
    fake_clock.advance(31)  # both fixes are now older than alert_bus_fix_max_age_s (30 s)
    assert [await engine.process(app, ev) for ev in old] == [[], []]


async def test_alert_mode_off_or_far_away_students_are_not_considered(app, engine, push, world, student, fake_clock):
    trip = await world()
    off = await student(enabled=False)
    far = await student(east_m=3000)
    await approach(app, engine, fake_clock, trip, [600, 400])
    assert not engine.state.keys_for(student_id=off)
    assert not engine.state.keys_for(student_id=far)


async def test_a8_breakdown_status_no_alert(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student()
    assert await approach(app, engine, fake_clock, trip, [600, 400, 300], status="breakdown") == [[]] * 3
    await con.execute("update public.trips set status = 'breakdown' where id = $1", trip.trip_id)
    assert await approach(app, engine, fake_clock, trip, [600, 400]) == [[], []]
    assert await alert_count(con, sid) == 0


async def test_a8_ended_trip_no_alert_and_state_cleared(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student()
    await approach(app, engine, fake_clock, trip, [600])
    assert engine.state.keys_for(trip_id=trip.trip_id)
    await con.execute("update public.trips set ended_at = now(), closed_by = 'driver' where id = $1", trip.trip_id)
    await emit_trip(app, TripEvent(trip.trip_id, trip.bus_id, trip.route_id, "ended"))
    assert not engine.state.keys_for(trip_id=trip.trip_id)
    assert await approach(app, engine, fake_clock, trip, [500, 400]) == [[], []]
    assert await alert_count(con, sid) == 0


async def test_one_alert_per_trip_even_after_state_loss(app, con, engine, push, world, student, fake_clock):
    """alert_log is the guard: a restart (empty memory) never re-alerts the same trip."""
    trip = await world()
    sid = await student()
    await approach(app, engine, fake_clock, trip, [600, 400])
    engine.state.prev_distance.clear()
    assert await approach(app, engine, fake_clock, trip, [450, 300]) == [[], []]
    assert await alert_count(con, sid) == 1


async def test_listener_queues_fix_without_evaluating(app, con, engine, push, world, student):
    trip = await world()
    sid = await student()
    await emit_fix(app, trip.fix(600))
    await emit_fix(app, trip.fix(400))
    assert engine.queue.qsize() == 2 and await alert_count(con, sid) == 0  # ingestion did no alert work
    await engine.drain(app)
    assert await alert_count(con, sid) == 1


async def test_full_alert_queue_drops_the_oldest_fix(app, world):
    from app.modules.alerts.engine import AlertEngine

    trip = await world()
    small = AlertEngine(maxsize=2)
    for d in (600, 500, 400):
        small.submit(trip.fix(d))
    assert small.queue.qsize() == 2
    assert small.queue.get_nowait().lat > small.queue.get_nowait().lat  # 500 then 400 remain


async def test_u2_deleting_account_stops_alerts(app, con, client, engine, push, world, google_login, fake_clock):
    trip = await world()
    body = await google_login(sub="p4-u2", email="p4-u2@uok.edu.in")
    sid, auth = body["user"]["id"], bearer(body["access_token"])
    assert (
        await client.put("/api/v1/me/push-token", json={"token": "tok-u2", "platform": "android"}, headers=auth)
    ).status_code == 204
    assert (await client.put("/api/v1/me/alert-settings", json={"enabled": True}, headers=auth)).status_code == 200
    resp = await client.post(
        "/api/v1/me/location",
        headers=auth,
        json={"lat": 34.1310, "lng": 74.8370, "accuracy": 15, "recorded_at": clock.now().isoformat()},
    )
    assert resp.status_code == 204
    await approach(app, engine, fake_clock, trip, [600, 500])
    assert engine.state.keys_for(student_id=UUID(sid))

    assert (await client.delete("/api/v1/me", headers=auth)).status_code == 204
    assert not engine.state.prev_distance  # USER_DELETED dropped the in-memory state
    assert await approach(app, engine, fake_clock, trip, [400, 300]) == [[], []]
    await app.state.push.drain(app)
    assert push.attempts == []
    for table, col in (
        ("student_locations", "user_id"),
        ("alert_settings", "user_id"),
        ("alert_log", "student_id"),
        ("push_tokens", "user_id"),
    ):
        assert await con.fetchval(f"select count(*) from public.{table} where {col} = $1::uuid", sid) == 0


async def test_u2_push_queued_before_deletion_is_not_delivered(
    app, con, client, engine, push, world, student, fake_clock
):
    trip = await world()
    sid = await student()
    await approach(app, engine, fake_clock, trip, [600, 400])
    assert app.state.push.queue.qsize() == 1
    await con.execute("delete from public.users where id = $1", sid)
    await app.state.push.drain(app)
    assert push.attempts == []  # tokens are resolved at delivery time


async def test_student_moving_location_is_used(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student(north_m=-2000)
    await approach(app, engine, fake_clock, trip, [600, 500])
    await set_location(con, sid, north_m=0)
    assert await approach(app, engine, fake_clock, trip, [450, 400]) == [[], [sid]]


async def test_a5_location_goes_stale_on_the_app_clock(app, con, client, engine, push, world, google_login, fake_clock):
    """A location posted through the API stops counting once the clock passes 5 minutes."""
    trip = await world()
    body = await google_login(sub="p4-stale", email="p4-stale@uok.edu.in")
    auth = bearer(body["access_token"])
    await client.put("/api/v1/me/push-token", json={"token": "tok-stale", "platform": "android"}, headers=auth)
    await client.put("/api/v1/me/alert-settings", json={"enabled": True}, headers=auth)
    resp = await client.post(
        "/api/v1/me/location",
        headers=auth,
        json={"lat": 34.1310, "lng": 74.8370, "accuracy": 15, "recorded_at": clock.now().isoformat()},
    )
    assert resp.status_code == 204
    fake_clock.advance(301)
    assert await approach(app, engine, fake_clock, trip, [600, 400]) == [[], []]
