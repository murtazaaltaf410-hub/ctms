"""V1.3 decision 9: pins from students of another bus need the driver's decision."""

# Fixtures imported from tests.alerts_support are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

import pytest

from app.modules.alerts.engine import get_engine
from app.push import get_push
from tests.alerts_support import push  # noqa: F401
from tests.conftest import add_student_profile, bearer
from tests.tracking_support import point_at

pytest_plugins = ["tests.tracking_support"]

API = "/api/v1"


@dataclass
class Student:
    user_id: UUID
    headers: dict


@dataclass
class World:
    a: dict   # driver + bus A
    b: dict   # driver + bus B
    route_id: UUID


@pytest.fixture
async def world(con, live_app, push, driver_with_bus) -> World:
    a = await driver_with_bus(label="Bus A")
    b = await driver_with_bus(label="Bus B", route=a["route"])
    for driver, tok in ((a, "tok-a"), (b, "tok-b")):
        await con.execute("insert into public.push_tokens (user_id, token, platform) values ($1, $2, 'android')",
                          driver["driver_id"], tok)
    return World(a, b, a["route"]["id"])


@pytest.fixture
def student(con, google_login, world):
    async def make(n: int, bus: dict | None, *, name: str | None = None) -> Student:
        body = await google_login(f"sub-{n}", f"s{n}@uok.edu.in", name or f"Student {n}", profile=None)
        uid = UUID(body["user"]["id"])
        await add_student_profile(con, uid, name=name or f"Student {n}", route_id=world.route_id,
                                  bus_id=bus["bus_id"] if bus else None, department="Physics")
        await con.execute("update public.student_profiles set enrollment_no = $2 where user_id = $1",
                          uid, f"UOK-{n:04d}")
        await con.execute("insert into public.push_tokens (user_id, token, platform) values ($1, $2, 'android')",
                          uid, f"tok-s{n}")
        return Student(uid, bearer(body["access_token"]))

    return make


def pin(route_id, along_m: float = 300.0, **extra) -> dict:
    lat, lng = point_at(along_m)
    return {"route_id": str(route_id), "lat": lat, "lng": lng, **extra}


async def pins_for(client, driver, trip_id: str) -> list[dict]:
    resp = await client.get(f"{API}/trips/{trip_id}/pickups", headers=driver["headers"])
    assert resp.status_code == 200, resp.text
    return resp.json()["items"]


async def pushed(app, push) -> list:
    await get_push(app).drain(app)
    sent, push.sent[:] = list(push.sent), []
    return sent


async def test_pin_from_another_buss_student_needs_the_drivers_decision(
        client, app, world, student, push, start_trip):
    trip = await start_trip(world.a)
    other = await student(1, world.b)
    resp = await client.post(f"{API}/pickups", json=pin(world.route_id, label="Gate"), headers=other.headers)
    assert resp.status_code == 201, resp.text
    assert resp.json()["decision"] == "needs_decision" and resp.json()["decided_at"] is None
    assert (await client.get(f"{API}/me/pickup", headers=other.headers)).json()["decision"] == "needs_decision"

    [m] = await pushed(app, push)
    assert m.token == "tok-a" and m.title == "Unknown student wants a pickup" and m.tag == "pickup_decision"
    assert m.data["trip_id"] == trip["id"] and m.data["request_id"] == resp.json()["id"]

    [item] = await pins_for(client, world.a, trip["id"])
    assert item["decision"] == "needs_decision"
    assert item["student"] == {"student_id": str(other.user_id), "name": "Student 1", "department": "Physics",
                               "enrollment_no": "UOK-0001", "has_photo": False}


async def test_students_on_the_bus_and_without_a_bus_stay_automatic(client, app, world, student, push, start_trip):
    trip = await start_trip(world.a)
    mine = await student(1, world.a)
    nobody = await student(2, None)
    for s in (mine, nobody):
        resp = await client.post(f"{API}/pickups", json=pin(world.route_id), headers=s.headers)
        assert resp.json()["decision"] == "auto"
    assert await pushed(app, push) == []
    items = await pins_for(client, world.a, trip["id"])
    assert [i["decision"] for i in items] == ["auto", "auto"] and all(i["student"] is None for i in items)


async def test_a_pin_is_not_flagged_while_the_students_own_bus_runs_that_leg(
        client, app, world, student, push, start_trip):
    await start_trip(world.a)
    trip_b = await start_trip(world.b)
    other = await student(1, world.b)
    assert (await client.post(f"{API}/pickups", json=pin(world.route_id), headers=other.headers)
            ).json()["decision"] == "auto"
    assert await pushed(app, push) == []
    [item] = await pins_for(client, world.b, trip_b["id"])
    assert item["decision"] == "auto" and item["student"] is None


async def test_accept_keeps_the_pin_and_tells_the_student(client, app, world, student, push, start_trip):
    trip = await start_trip(world.a)
    other = await student(1, world.b)
    pin_id = (await client.post(f"{API}/pickups", json=pin(world.route_id), headers=other.headers)).json()["id"]
    await pushed(app, push)
    resp = await client.post(f"{API}/pickups/{pin_id}/decision", json={"decision": "accept"},
                             headers=world.a["headers"])
    assert resp.status_code == 200 and resp.json() == {"id": pin_id, "decision": "accepted"}
    mine = (await client.get(f"{API}/me/pickup", headers=other.headers)).json()
    assert mine["status"] == "waiting" and mine["decision"] == "accepted" and mine["decided_at"].endswith("Z")
    [item] = await pins_for(client, world.a, trip["id"])
    assert item["decision"] == "accepted" and item["student"]["name"] == "Student 1"
    [m] = await pushed(app, push)
    assert m.token == "tok-s1" and m.title == "Pickup request accepted" and m.data["decision"] == "accepted"
    # Accepting again is a no-op and does not notify twice.
    again = await client.post(f"{API}/pickups/{pin_id}/decision", json={"decision": "accept"},
                              headers=world.a["headers"])
    assert again.status_code == 200 and await pushed(app, push) == []


async def test_reject_removes_the_pin_and_the_student_sees_why(client, app, world, student, push, start_trip):
    trip = await start_trip(world.a)
    other = await student(1, world.b)
    pin_id = (await client.post(f"{API}/pickups", json=pin(world.route_id), headers=other.headers)).json()["id"]
    await pushed(app, push)
    resp = await client.post(f"{API}/pickups/{pin_id}/decision", json={"decision": "reject"},
                             headers=world.a["headers"])
    assert resp.status_code == 200 and resp.json()["decision"] == "rejected"
    assert await pins_for(client, world.a, trip["id"]) == []
    mine = (await client.get(f"{API}/me/pickup", headers=other.headers)).json()
    assert mine["status"] == "cancelled" and mine["decision"] == "rejected"
    [m] = await pushed(app, push)
    assert m.title == "Pickup request declined" and m.data["decision"] == "rejected"
    # Gone for decisions; a new pin replaces the rejected one in /me/pickup.
    gone = await client.post(f"{API}/pickups/{pin_id}/decision", json={"decision": "accept"},
                             headers=world.a["headers"])
    assert gone.status_code == 404 and gone.json()["error"]["code"] == "NOT_FOUND"
    fresh = (await client.post(f"{API}/pickups", json=pin(world.route_id, 500), headers=other.headers)).json()
    assert (await client.get(f"{API}/me/pickup", headers=other.headers)).json()["id"] == fresh["id"]


async def test_rejected_notice_expires(client, world, student, start_trip, fake_clock):
    await start_trip(world.a)
    other = await student(1, world.b)
    pin_id = (await client.post(f"{API}/pickups", json=pin(world.route_id), headers=other.headers)).json()["id"]
    await client.post(f"{API}/pickups/{pin_id}/decision", json={"decision": "reject"}, headers=world.a["headers"])
    fake_clock.advance(2 * 3600)
    assert (await client.get(f"{API}/me/pickup", headers=other.headers)).json() is None


async def test_decision_endpoint_rules(client, world, student, start_trip, driver_with_bus):
    await start_trip(world.a)
    other = await student(1, world.b)
    own = await student(2, world.a)
    foreign_id = (await client.post(f"{API}/pickups", json=pin(world.route_id), headers=other.headers)).json()["id"]
    own_id = (await client.post(f"{API}/pickups", json=pin(world.route_id), headers=own.headers)).json()["id"]
    url = f"{API}/pickups/{foreign_id}/decision"
    for bad in ({}, {"decision": "maybe"}, {"decision": "accepted"}):
        resp = await client.post(url, json=bad, headers=world.a["headers"])
        assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR", bad
    assert (await client.post(url, json={"decision": "accept"}, headers=other.headers)).status_code == 403
    # Not for the driver's own student, an unknown pin, or a driver with no active trip.
    assert (await client.post(f"{API}/pickups/{own_id}/decision", json={"decision": "accept"},
                              headers=world.a["headers"])).status_code == 404
    assert (await client.post(f"{API}/pickups/{UUID(int=9)}/decision", json={"decision": "accept"},
                              headers=world.a["headers"])).status_code == 404
    assert (await client.post(url, json={"decision": "accept"}, headers=world.b["headers"])).status_code == 404


async def test_starting_a_trip_flags_pins_already_waiting(client, app, world, student, push, start_trip):
    other = await student(1, world.b)
    resp = await client.post(f"{API}/pickups", json=pin(world.route_id), headers=other.headers)
    assert resp.json()["decision"] == "auto"       # nobody is driving yet
    trip = await start_trip(world.a)
    [m] = await pushed(app, push)
    assert m.token == "tok-a" and m.title == "Unknown student wants a pickup"
    [item] = await pins_for(client, world.a, trip["id"])
    assert item["decision"] == "needs_decision" and item["student"]["enrollment_no"] == "UOK-0001"
    # The student's own driver starts later: for bus B the same pin is automatic again.
    trip_b = await start_trip(world.b)
    [item_b] = await pins_for(client, world.b, trip_b["id"])
    assert item_b["decision"] == "auto" and item_b["student"] is None


async def test_undecided_pin_does_not_alert_a_foreign_driver_nearby(
        client, app, world, student, push, start_trip, post_fixes, fake_clock):
    """Pickup 'student waiting ahead' alerts wait for the decision (accepted pins alert as before)."""
    from tests.tracking_support import along_fix

    trip = await start_trip(world.a)
    other = await student(1, world.b)
    pin_id = (await client.post(f"{API}/pickups", json=pin(world.route_id, 300), headers=other.headers)).json()["id"]
    await pushed(app, push)
    await post_fixes(world.a, trip["id"], [along_fix(150, fake_clock.current, speed=8.0)])
    await get_engine(app).drain(app)
    assert [m for m in await pushed(app, push) if m.tag == "pickup_nearby"] == []
    await client.post(f"{API}/pickups/{pin_id}/decision", json={"decision": "accept"}, headers=world.a["headers"])
    await pushed(app, push)
    fake_clock.advance(10)
    await post_fixes(world.a, trip["id"], [along_fix(180, fake_clock.current, speed=8.0)])
    fake_clock.advance(10)
    await post_fixes(world.a, trip["id"], [along_fix(230, fake_clock.current, speed=8.0)])
    await get_engine(app).drain(app)
    assert any(m.tag == "pickup_nearby" and m.token == "tok-a" for m in await pushed(app, push))
