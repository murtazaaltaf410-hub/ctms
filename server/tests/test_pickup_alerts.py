"""Pickup-pin alerts (ADR-9, X3): driver push when the bus nears a waiting student, student push,
once per (pin, trip), picked_up when passed, direction and expiry respected."""
# ruff: noqa: F811  (pytest fixtures imported from tests.alerts_support)

from __future__ import annotations

from datetime import timedelta
from uuid import UUID

import pytest

from app import clock
from app.modules.alerts.engine import ALERT_TAG, PICKUP_TAG, pickup_driver_text
from app.modules.alerts.geo import offset
from tests.alerts_support import BASE, engine, push, student, world  # noqa: F401  (fixtures)
from tests.tracking_support import fake_clock  # noqa: F401


@pytest.fixture(autouse=True)
def _frozen(fake_clock):
    return fake_clock


async def add_pin(con, student_id: UUID, trip, *, direction="to_campus", label="Near the gate", ttl_s=3600):
    lat, lng = offset(*BASE, north_m=0, east_m=0)
    return await con.fetchval(
        """insert into public.pickup_requests (student_id, route_id, direction, lat, lng, label, expires_at)
           values ($1, $2, $3, $4, $5, $6, $7) returning id""",
        student_id, trip.route_id, direction, lat, lng, label, clock.now() + timedelta(seconds=ttl_s),
    )


async def give_driver_token(con, trip) -> UUID:
    driver_id = await con.fetchval("select driver_id from public.trips where id = $1", trip.trip_id)
    await con.execute(
        "insert into public.push_tokens (user_id, token, platform) values ($1, 'driver-token', 'android')", driver_id
    )
    return driver_id


async def approach(app, engine, fake_clock, trip, distances):
    for d in distances:
        await engine.process(app, trip.fix(d))
        fake_clock.advance(4.0)
    await app.state.push.drain(app)


def test_pickup_driver_text():
    assert pickup_driver_text(431, "Near the gate") == "Student waiting about 450 m ahead: Near the gate"
    assert pickup_driver_text(12, None) == "Student waiting about 50 m ahead"


async def test_driver_and_student_are_alerted_once_when_the_bus_approaches(
    app, con, engine, push, world, student, fake_clock
):
    trip = await world()
    sid = await student(north_m=5000)  # far away: only the pin matters, not their GPS
    await give_driver_token(con, trip)
    await add_pin(con, sid, trip)
    await approach(app, engine, fake_clock, trip, [700, 600, 450, 350, 250])
    by_token = {m.token: m for m in push.sent}
    driver_msg = next(m for m in push.sent if m.tag == PICKUP_TAG)
    assert driver_msg.title == "Student waiting"
    assert driver_msg.body == "Student waiting about 450 m ahead: Near the gate"
    assert driver_msg.data["type"] == PICKUP_TAG and driver_msg.data["trip_id"] == str(trip.trip_id)
    student_msg = next(m for m in push.sent if m.tag == ALERT_TAG)
    assert student_msg.title == "Bus nearby" and "450 m" in student_msg.body
    assert len(push.sent) == 2 and len(by_token) == 2


async def test_moving_away_never_alerts(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student(north_m=5000)
    await give_driver_token(con, trip)
    await add_pin(con, sid, trip)
    await approach(app, engine, fake_clock, trip, [300, 350, 400, 450])
    assert push.sent == []


async def test_no_second_student_push_when_the_nearby_alert_already_fired(
    app, con, engine, push, world, student, fake_clock
):
    trip = await world()
    sid = await student()  # at BASE, alerts on: gets the normal nearby-bus alert at 400 m
    await give_driver_token(con, trip)
    await add_pin(con, sid, trip)
    await approach(app, engine, fake_clock, trip, [600, 500, 400, 300])
    student_pushes = [m for m in push.sent if m.tag == ALERT_TAG]
    assert len(student_pushes) == 1
    assert len([m for m in push.sent if m.tag == PICKUP_TAG]) == 1


async def test_pin_is_marked_picked_up_when_the_bus_passes(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    sid = await student(north_m=5000)
    pin = await add_pin(con, sid, trip)
    await approach(app, engine, fake_clock, trip, [200, 100, 30])
    row = await con.fetchrow("select status, trip_id from public.pickup_requests where id = $1", pin)
    assert row["status"] == "picked_up" and row["trip_id"] == trip.trip_id


async def test_other_direction_and_expired_pins_are_ignored(app, con, engine, push, world, student, fake_clock):
    trip = await world()
    await give_driver_token(con, trip)
    s1, s2 = await student(north_m=5000), await student(north_m=5000)
    await add_pin(con, s1, trip, direction="from_campus")
    await add_pin(con, s2, trip, ttl_s=-10)
    await approach(app, engine, fake_clock, trip, [700, 600, 450, 350])
    assert [m for m in push.sent if m.tag == PICKUP_TAG] == []
