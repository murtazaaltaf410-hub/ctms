"""Student registration, seats and admin approval (ADR-10, requirements X5-X7).

Fixture note: `google_login(..., profile=None)` signs a student in WITHOUT a registration (the default
makes an approved one so older tests keep working); the tests here register through the API.
"""
# ruff: noqa: F811  (pytest fixtures imported from the helper modules)

from __future__ import annotations

import asyncio
import json
from uuid import UUID, uuid4

import asyncpg
import httpx
import pytest

from app.db import create_pool
from app.live.hub import get_hub
from app.live.ws import live_ws
from app.main import create_app
from tests.admin_helpers import admin, err, insert_route  # noqa: F401
from tests.alerts_support import alert_count, engine, push, student, world  # noqa: F401
from tests.conftest import bearer, make_config
from tests.tracking_support import FakeWS, along_fix, driver_with_bus, fake_clock, hub_clients, wait_until  # noqa: F401

pytest_plugins = ["tests.tracking_support"]

API = "/api/v1"
PHONE = "+919876543210"


JPEG = bytes.fromhex("ffd8ffe0") + b"photo" * 20 + bytes.fromhex("ffd9")


def body(route_id, **extra) -> dict:
    return {"full_name": "Asha Khan", "phone": PHONE, "department": "Physics", "enrollment_no": "UOK-2024-001",
            "home_address": "12 Lake Road, Srinagar", "route_id": str(route_id),
            "requested_bus_label": "Bus 2", "claims_registered": False, **extra}


@pytest.fixture
def new_student(google_login):
    """`await new_student(n)` -> (user_id, headers) of a student with NO registration."""

    async def make(n: int = 1, *, profile: str | None = None) -> tuple[UUID, dict]:
        tokens = await google_login(f"stu-sub-{n}", f"stu{n}@uok.edu.in", f"Student {n}", profile=profile)
        return UUID(tokens["user"]["id"]), bearer(tokens["access_token"])

    return make


@pytest.fixture
def set_bus(con):
    """Make a bus on a route with a capacity (None = not set)."""
    counter = {"n": 0}

    async def make(route_id, capacity: int | None = 2, *, label: str | None = None, active: bool = True) -> UUID:
        counter["n"] += 1
        n = counter["n"]
        return await con.fetchval(
            """insert into public.buses (label, plate, default_route_id, capacity, active)
               values ($1, $2, $3, $4, $5) returning id""",
            label or f"Seat Bus {n}", f"JK01S{n:05d}", route_id, capacity, active)

    return make


@pytest.fixture
def register(client, new_student):
    """Register student `n` for `route_id` through the API and return (user_id, headers)."""

    async def go(n: int, route_id, **extra) -> tuple[UUID, dict]:
        uid, headers = await new_student(n)
        resp = await client.put(f"{API}/me/registration", json=body(route_id, full_name=f"Student {n}", **extra),
                                headers=headers)
        assert resp.status_code == 200, resp.text
        resp = await client.put(f"{API}/me/registration/photo", content=JPEG,
                                headers={**headers, "Content-Type": "image/jpeg"})
        assert resp.status_code == 200, resp.text
        return uid, headers

    return go


async def approve(client, headers, uid, bus_id, expect=200):
    resp = await client.post(f"{API}/admin/students/{uid}/approve", json={"bus_id": str(bus_id)}, headers=headers)
    assert resp.status_code == expect, resp.text
    return resp


# --- registration (student side) -------------------------------------------------------------------
async def test_x5_registration_create_read_and_one_profile_per_student(client, con, make_route, new_student):
    route = await make_route()
    uid, headers = await new_student()
    assert (await client.get(f"{API}/me/registration", headers=headers)).json() is None
    resp = await client.put(f"{API}/me/registration", json=body(route["id"], claims_registered=True),
                            headers=headers)
    assert resp.status_code == 200, resp.text
    reg = resp.json()
    assert reg["status"] == "pending" and reg["route_name"] == "Test Route" and reg["bus_id"] is None
    assert reg["phone"] == PHONE and reg["claims_registered"] is True and reg["admin_note"] is None
    assert reg["created_at"].endswith("Z")
    # A second submit updates the same row.
    resp = await client.put(f"{API}/me/registration", json=body(route["id"], department="Chemistry"), headers=headers)
    assert resp.status_code == 200 and resp.json()["department"] == "Chemistry"
    assert await con.fetchval("select count(*) from public.student_profiles where user_id = $1", uid) == 1
    assert (await client.get(f"{API}/me/registration", headers=headers)).json()["department"] == "Chemistry"


@pytest.mark.parametrize("patch", [
    {"phone": "98765"}, {"phone": "not a number"}, {"full_name": ""}, {"department": ""},
    {"requested_bus_label": ""}, {"route_id": "nope"}, {"enrollment_no": ""}, {"home_address": ""},
])
async def test_x5_registration_validation(client, make_route, new_student, patch):
    route = await make_route()
    _, headers = await new_student()
    resp = await client.put(f"{API}/me/registration", json={**body(route["id"]), **patch}, headers=headers)
    assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"


async def test_x5_phone_is_normalised_to_e164(client, make_route, new_student):
    route = await make_route()
    _, headers = await new_student()
    resp = await client.put(f"{API}/me/registration", json=body(route["id"], phone="+91 98765-43210"), headers=headers)
    assert resp.status_code == 200 and resp.json()["phone"] == "+919876543210"


async def test_x5_route_must_be_active(client, con, make_route, new_student):
    route = await make_route()
    draft = await con.fetchval("insert into public.routes (name) values ('Draft') returning id")
    _, headers = await new_student()
    for rid in (draft, uuid4()):
        resp = await client.put(f"{API}/me/registration", json=body(rid), headers=headers)
        assert resp.status_code == 400 and "route_id" in resp.json()["error"]["message"]
    await con.execute("update public.routes set active = false where id = $1", route["id"])
    resp = await client.put(f"{API}/me/registration", json=body(route["id"]), headers=headers)
    assert resp.status_code == 400


async def test_x5_resubmit_after_rejection_goes_back_to_pending_and_clears_the_note(
        client, admin, make_route, register):
    route = await make_route()
    uid, headers = await register(1, route["id"])
    _, adm = await admin()
    resp = await client.post(f"{API}/admin/students/{uid}/reject", json={"note": "Not on our list"}, headers=adm)
    assert resp.status_code == 200 and resp.json()["status"] == "rejected"
    reg = (await client.get(f"{API}/me/registration", headers=headers)).json()
    assert reg["status"] == "rejected" and reg["admin_note"] == "Not on our list"
    resp = await client.put(f"{API}/me/registration", json=body(route["id"]), headers=headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "pending" and resp.json()["admin_note"] is None


async def test_x5_approved_student_cannot_change_route_or_bus_but_can_update_contact(
        client, admin, make_route, set_bus, register):
    route, other = await make_route(), await make_route("Other")
    bus = await set_bus(route["id"])
    uid, headers = await register(1, route["id"])
    _, adm = await admin()
    await approve(client, adm, uid, bus)
    resp = await client.put(f"{API}/me/registration", json=body(other["id"]), headers=headers)
    assert resp.status_code == 409 and err(resp) == "IN_USE"
    resp = await client.put(f"{API}/me/registration", json=body(route["id"], requested_bus_label="Bus 9"),
                            headers=headers)
    assert resp.status_code == 409
    resp = await client.put(f"{API}/me/registration", json=body(route["id"], phone="+919811111111",
                                                                 full_name="Asha K"), headers=headers)
    assert resp.status_code == 200
    reg = resp.json()
    assert reg["status"] == "approved" and reg["phone"] == "+919811111111" and reg["full_name"] == "Asha K"
    assert reg["bus_id"] == str(bus)


async def test_x5_nearest_route(client, con, make_route, new_student):
    near = await make_route("Near")
    far = await insert_route(con, name="Far Route")  # the CAMPUS line, about 0.5 km east of the test road
    _, headers = await new_student()
    lat, lng = 34.1203, 74.8300  # on the first route
    resp = await client.get(f"{API}/routes/nearest", params={"lat": lat, "lng": lng}, headers=headers)
    assert resp.status_code == 200
    assert resp.json()["route_id"] == str(near["id"]) and resp.json()["offset_m"] < 10
    resp = await client.get(f"{API}/routes/nearest", params={"lat": 34.1260, "lng": 74.8349}, headers=headers)
    assert resp.json()["route_id"] == str(far)
    resp = await client.get(f"{API}/routes/nearest", params={"lat": 10.0, "lng": 10.0}, headers=headers)
    assert resp.status_code == 200 and resp.json() is None
    assert (await client.get(f"{API}/routes/nearest", params={"lat": 99, "lng": 0}, headers=headers)).status_code == 400
    # The id route still works next to /routes/nearest.
    assert (await client.get(f"{API}/routes/{near['id']}", headers=headers)).status_code == 200


# --- admin: approve / reject / reassign / seats ------------------------------------------------------
async def test_x6_approve_assigns_bus_and_audits(client, con, admin, make_route, set_bus, register):
    route = await make_route()
    bus = await set_bus(route["id"], label="Bus 5")
    uid, headers = await register(1, route["id"])
    actor, adm = await admin()
    resp = await approve(client, adm, uid, bus)
    out = resp.json()
    assert out["status"] == "approved" and out["bus_id"] == str(bus) and out["bus_label"] == "Bus 5"
    assert out["admin_note"] is None and out["reviewed_at"].endswith("Z")
    reg = (await client.get(f"{API}/me/registration", headers=headers)).json()
    assert reg["status"] == "approved" and reg["bus_label"] == "Bus 5"
    row = await con.fetchrow("select action, actor_id, meta from public.audit_log where action = 'student.approve'")
    assert row["actor_id"] == actor and row["meta"]["bus_id"] == str(bus)
    assert PHONE not in json.dumps(row["meta"])


async def test_x6_wrong_route_inactive_unknown_bus_and_unset_capacity_are_refused(
        client, admin, make_route, set_bus, register):
    route, other = await make_route(), await make_route("Other")
    uid, _ = await register(1, route["id"])
    _, adm = await admin()
    wrong = await set_bus(other["id"])
    resp = await approve(client, adm, uid, wrong, expect=400)
    assert err(resp) == "VALIDATION_ERROR" and "route" in resp.json()["error"]["message"]
    resp = await approve(client, adm, uid, await set_bus(route["id"], active=False), expect=400)
    assert "not active" in resp.json()["error"]["message"]
    resp = await approve(client, adm, uid, uuid4(), expect=404)
    assert err(resp) == "NOT_FOUND"
    await approve(client, adm, uuid4(), await set_bus(route["id"]), expect=404)
    unset = await set_bus(route["id"], capacity=None)
    resp = await approve(client, adm, uid, unset, expect=409)  # capacity unset = no seats: 409 NO_SEAT
    assert err(resp) == "NO_SEAT"
    zero = await set_bus(route["id"], capacity=0)
    assert err(await approve(client, adm, uid, zero, expect=409)) == "NO_SEAT"
    still = (await client.get(f"{API}/admin/students/{uid}", headers=adm)).json()
    assert still["status"] == "pending" and still["bus_id"] is None


async def test_x6_seat_limit_reassign_and_reject_frees_the_seat(client, admin, make_route, set_bus, register):
    route = await make_route()
    bus_a, bus_b = await set_bus(route["id"], 1, label="A"), await set_bus(route["id"], 1, label="B")
    s1, _ = await register(1, route["id"])
    s2, _ = await register(2, route["id"])
    _, adm = await admin()
    await approve(client, adm, s1, bus_a)
    assert err(await approve(client, adm, s2, bus_a, expect=409)) == "NO_SEAT"
    # Re-approving the same student on their own full bus is fine (their seat is excluded from the count).
    await approve(client, adm, s1, bus_a)
    # Reassign needs an approved student and a bus with a free seat.
    resp = await client.post(f"{API}/admin/students/{s2}/reassign", json={"bus_id": str(bus_b)}, headers=adm)
    assert resp.status_code == 400
    await approve(client, adm, s2, bus_b)
    resp = await client.post(f"{API}/admin/students/{s2}/reassign", json={"bus_id": str(bus_a)}, headers=adm)
    assert resp.status_code == 409 and err(resp) == "NO_SEAT"
    # Rejecting s1 frees bus A and clears the bus; then s2 can move there.
    resp = await client.post(f"{API}/admin/students/{s1}/reject", json={"note": "Fee unpaid"}, headers=adm)
    assert resp.json()["bus_id"] is None and resp.json()["admin_note"] == "Fee unpaid"
    resp = await client.post(f"{API}/admin/students/{s2}/reassign", json={"bus_id": str(bus_a)}, headers=adm)
    assert resp.status_code == 200 and resp.json()["bus_id"] == str(bus_a)
    summary = (await client.get(f"{API}/admin/students/summary", headers=adm)).json()
    seats = {b["label"]: b for b in summary["buses"]}
    assert seats["A"]["assigned"] == 1 and seats["A"]["seats_left"] == 0
    assert seats["B"]["assigned"] == 0 and seats["B"]["seats_left"] == 1


async def test_x6_bus_serves_every_route_its_driver_is_assigned_to(
        client, con, admin, make_route, register, driver_with_bus):
    """The admin decides which routes a driver runs; a bus seats students of any of them (one seat pool)."""
    first, second, third = await make_route(), await make_route("Second"), await make_route("Third")
    d = await driver_with_bus(route=first)
    await con.execute("update public.buses set capacity = 1 where id = $1", d["bus_id"])
    await con.execute("insert into public.driver_route_assignments (driver_id, route_id) values ($1, $2)",
                      d["driver_id"], second["id"])
    _, adm = await admin()
    buses = (await client.get(f"{API}/admin/students/summary", headers=adm)).json()["buses"]
    mine = next(b for b in buses if b["bus_id"] == str(d["bus_id"]))
    assert mine["route_id"] == str(first["id"])  # unchanged for older clients
    assert set(mine["route_ids"]) == {str(first["id"]), str(second["id"])}
    uid, _ = await register(1, second["id"])
    resp = await approve(client, adm, uid, d["bus_id"])
    assert resp.json()["status"] == "approved" and resp.json()["bus_id"] == str(d["bus_id"])
    uid3, _ = await register(2, third["id"])  # a route the driver does not run is still refused
    assert err(await approve(client, adm, uid3, d["bus_id"], expect=400)) == "VALIDATION_ERROR"
    uid4, _ = await register(3, first["id"])  # seats are shared across routes: the bus is now full
    assert err(await approve(client, adm, uid4, d["bus_id"], expect=409)) == "NO_SEAT"


async def test_x6_reject_needs_a_note_and_a_known_student(client, admin, make_route, register):
    route = await make_route()
    uid, _ = await register(1, route["id"])
    _, adm = await admin()
    for payload in ({}, {"note": ""}, {"note": "   "}):
        resp = await client.post(f"{API}/admin/students/{uid}/reject", json=payload, headers=adm)
        assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"
    resp = await client.post(f"{API}/admin/students/{uuid4()}/reject", json={"note": "x"}, headers=adm)
    assert resp.status_code == 404


async def test_x6_two_concurrent_approvals_for_the_last_seat(google):
    """Real pool, committed rows: exactly one of two simultaneous approvals gets the last seat."""
    app = create_app(make_config())
    app.state.google_verifier = google
    app.state.pool = await create_pool(app.state.config)
    admin_email = f"race-admin-{uuid4().hex[:8]}@uok.edu.in"
    plate = f"RACE{uuid4().hex[:8]}".upper()
    ids: dict[str, list] = {"users": [], "routes": [], "buses": []}
    async with app.state.pool.acquire() as con:
        route = await con.fetchval("insert into public.routes (name) values ('Race') returning id")
        bus = await con.fetchval(
            "insert into public.buses (label, plate, default_route_id, capacity) values ('Race bus', $1, $2, 1) "
            "returning id", plate, route)
        ids["routes"].append(route)
        ids["buses"].append(bus)
        students = []
        for n in range(2):
            uid = await con.fetchval(
                "insert into public.users (role, name, email) values ('student', $1, $2) returning id",
                f"Racer {n}", f"racer{n}-{uuid4().hex[:6]}@uok.edu.in")
            await con.execute(
                """insert into public.student_profiles (user_id, full_name, phone, department, route_id,
                                                         enrollment_no, home_address, photo, photo_mime)
                   values ($1, 'Racer', '+919876543210', 'Physics', $2, 'ENR', 'Addr', $3, 'image/jpeg')""",
                uid, route, JPEG)
            ids["users"].append(uid)
            students.append(uid)
        await con.execute("insert into public.admin_allowlist (email) values ($1)", admin_email)
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://race") as ac:
            tok = await ac.post(f"{API}/auth/google",
                                json={"id_token": google.token("race-admin", admin_email, "Race Admin")})
            assert tok.status_code == 200, tok.text
            ids["users"].append(UUID(tok.json()["user"]["id"]))
            headers = bearer(tok.json()["access_token"])
            results = await asyncio.gather(*[
                ac.post(f"{API}/admin/students/{uid}/approve", json={"bus_id": str(bus)}, headers=headers)
                for uid in students])
        codes = sorted(r.status_code for r in results)
        assert codes == [200, 409], [r.text for r in results]
        loser = next(r for r in results if r.status_code == 409)
        assert loser.json()["error"]["code"] == "NO_SEAT"
        async with app.state.pool.acquire() as con:
            assert await con.fetchval(
                "select count(*) from public.student_profiles where bus_id = $1 and status = 'approved'", bus) == 1
    finally:
        async with app.state.pool.acquire() as con:
            await con.execute("delete from public.audit_log where actor_id = any($1::uuid[])", ids["users"])
            await con.execute("delete from public.users where id = any($1::uuid[])", ids["users"])
            await con.execute("delete from public.buses where id = any($1::uuid[])", ids["buses"])
            await con.execute("delete from public.routes where id = any($1::uuid[])", ids["routes"])
            await con.execute("delete from public.admin_allowlist where email = $1", admin_email)
        await app.state.pool.close()


async def test_x6_bus_capacity_can_be_set_and_cleared(client, admin, make_route):
    route = await make_route()
    _, adm = await admin()
    resp = await client.post(f"{API}/admin/buses", json={"label": "C1", "plate": "JK01C0001",
                                                          "default_route_id": str(route["id"]), "capacity": 40},
                             headers=adm)
    assert resp.status_code == 201 and resp.json()["capacity"] == 40
    bus_id = resp.json()["id"]
    resp = await client.patch(f"{API}/admin/buses/{bus_id}", json={"capacity": 35}, headers=adm)
    assert resp.json()["capacity"] == 35
    resp = await client.patch(f"{API}/admin/buses/{bus_id}", json={"capacity": None}, headers=adm)
    assert resp.status_code == 200 and resp.json()["capacity"] is None
    resp = await client.patch(f"{API}/admin/buses/{bus_id}", json={"capacity": -1}, headers=adm)
    assert resp.status_code == 400


# --- admin list, filters, search, summary --------------------------------------------------------------
async def test_x6_admin_list_filters_search_cursor_and_summary(client, admin, make_route, set_bus, register):
    r1, r2 = await make_route("R1"), await make_route("R2")
    bus1 = await set_bus(r1["id"], 5, label="B1")
    s1, _ = await register(1, r1["id"], department="Physics")
    s2, _ = await register(2, r1["id"], department="History")
    s3, _ = await register(3, r2["id"], department="Physics", phone="+919800000003")
    _, adm = await admin()
    await approve(client, adm, s1, bus1)
    await client.post(f"{API}/admin/students/{s2}/reject", json={"note": "no"}, headers=adm)

    async def ids(**params) -> list[str]:
        resp = await client.get(f"{API}/admin/students", params=params, headers=adm)
        assert resp.status_code == 200, resp.text
        return [i["id"] for i in resp.json()["items"]]

    by_id = lambda *uids: sorted(str(u) for u in uids)  # noqa: E731  (same created_at in one test transaction)
    assert await ids() == by_id(s1, s2, s3)
    assert await ids(status="approved") == [str(s1)]
    assert await ids(status="rejected") == [str(s2)]
    assert await ids(route_id=str(r2["id"])) == [str(s3)]
    assert await ids(bus_id=str(bus1)) == [str(s1)]
    assert await ids(q="physics") == by_id(s1, s3)
    assert await ids(q="stu2@") == [str(s2)]
    assert await ids(q="9800000003") == [str(s3)]
    assert await ids(q="Student 3") == [str(s3)]
    assert await ids(q="100%") == []
    assert (await client.get(f"{API}/admin/students", params={"status": "bogus"}, headers=adm)).status_code == 400
    first = (await client.get(f"{API}/admin/students", params={"limit": 2}, headers=adm)).json()
    assert len(first["items"]) == 2 and first["next_cursor"]
    second = (await client.get(f"{API}/admin/students", params={"limit": 2, "cursor": first["next_cursor"]},
                               headers=adm)).json()
    paged = [i["id"] for i in first["items"]] + [i["id"] for i in second["items"]]
    assert paged == by_id(s1, s2, s3) and len(second["items"]) == 1 and second["next_cursor"] is None
    item = next(i for i in first["items"] + second["items"] if i["id"] == str(s1))
    assert item["email"] == "stu1@uok.edu.in" and item["route_name"] == "R1" and item["bus_label"] == "B1"
    one = await client.get(f"{API}/admin/students/{s1}", headers=adm)
    assert one.status_code == 200 and one.json()["phone"] == PHONE
    assert (await client.get(f"{API}/admin/students/{uuid4()}", headers=adm)).status_code == 404

    summary = (await client.get(f"{API}/admin/students/summary", headers=adm)).json()
    assert summary["totals"] == {"unregistered": 0, "pending": 1, "approved": 1, "rejected": 1, "total": 3}
    routes = {r["route_name"]: r for r in summary["routes"]}
    assert (routes["R1"]["approved"], routes["R1"]["rejected"], routes["R1"]["pending"]) == (1, 1, 0)
    assert routes["R2"]["pending"] == 1
    bus = next(b for b in summary["buses"] if b["bus_id"] == str(bus1))
    assert (bus["capacity"], bus["assigned"], bus["seats_left"]) == (5, 1, 4)


async def test_x6_admin_sees_unregistered_and_incomplete_students_with_safe_diagnostics(
        client, con, admin, make_route, new_student):
    route = await make_route()
    unregistered_id, _ = await new_student(1)
    incomplete_id, _ = await new_student(2)
    await con.execute(
        """insert into public.student_profiles (user_id, full_name, phone, department, route_id)
           values ($1, 'Incomplete Student', null, 'Physics', $2)""",
        incomplete_id, route["id"])
    _, adm = await admin()

    response = await client.get(f"{API}/admin/students", headers=adm)
    assert response.status_code == 200, response.text
    students = {item["id"]: item for item in response.json()["items"]}
    assert students[str(unregistered_id)]["status"] is None
    assert students[str(unregistered_id)]["registration_state"] == "unregistered"
    assert students[str(unregistered_id)]["approval_diagnostic"] == "Student has not submitted a registration."
    assert students[str(incomplete_id)]["registration_state"] == "incomplete"
    assert "phone" in students[str(incomplete_id)]["approval_diagnostic"]
    assert PHONE not in students[str(incomplete_id)]["approval_diagnostic"]

    detail = await client.get(f"{API}/admin/students/{unregistered_id}", headers=adm)
    assert detail.status_code == 200 and detail.json()["registration_state"] == "unregistered"
    summary = (await client.get(f"{API}/admin/students/summary", headers=adm)).json()
    assert summary["totals"]["unregistered"] == 1 and summary["totals"]["total"] == 2


async def test_x6_approval_refuses_an_incomplete_registration(client, con, admin, make_route, set_bus, new_student):
    route = await make_route()
    student_id, _ = await new_student()
    await con.execute(
        """insert into public.student_profiles (user_id, full_name, phone, department, route_id)
           values ($1, 'Incomplete Student', null, 'Physics', $2)""",
        student_id, route["id"])
    _, adm = await admin()
    response = await approve(client, adm, student_id, await set_bus(route["id"]), expect=400)
    assert err(response) == "VALIDATION_ERROR"
    assert "incomplete" in response.json()["error"]["message"]


# --- role checks ----------------------------------------------------------------------------------------
async def test_x5_role_checks(client, admin, make_route, create_user, driver_login, new_student):
    route = await make_route()
    uid, student = await new_student()
    await create_user("driver", phone="+919000000077")
    driver = bearer((await driver_login("+919000000077"))["access_token"])
    _, adm = await admin()
    for method, url, kw in (
        ("get", "/admin/students", {}), ("get", "/admin/students/summary", {}),
        ("get", f"/admin/students/{uid}", {}),
        ("post", f"/admin/students/{uid}/approve", {"json": {"bus_id": str(uuid4())}}),
        ("post", f"/admin/students/{uid}/reject", {"json": {"note": "x"}}),
        ("post", f"/admin/students/{uid}/reassign", {"json": {"bus_id": str(uuid4())}}),
    ):
        for who in (student, driver):
            resp = await getattr(client, method)(f"{API}{url}", headers=who, **kw)
            assert resp.status_code == 403 and err(resp) == "FORBIDDEN_ROLE", (url, resp.text)
    for method, url, kw in (
        ("get", "/me/registration", {}), ("put", "/me/registration", {"json": body(route["id"])}),
        ("get", "/routes/nearest", {"params": {"lat": 34.1, "lng": 74.8}}),
    ):
        for who in (driver, adm):
            resp = await getattr(client, method)(f"{API}{url}", headers=who, **kw)
            assert resp.status_code == 403 and err(resp) == "FORBIDDEN_ROLE", (url, resp.text)


# --- gating -------------------------------------------------------------------------------------------
GATED = [
    ("get", "/buses/live", {}),
    ("get", "/stops/{stop}/eta", {}),
    ("put", "/me/alert-settings", {"json": {"enabled": False}}),
    ("post", "/me/location", {"json": {"lat": 34.12, "lng": 74.83, "accuracy": 10,
                                       "recorded_at": "2030-01-01T00:00:00Z"}}),
    ("post", "/pickups", {"json": {"route_id": "{route}", "lat": 34.12, "lng": 74.83}}),
    ("get", "/me/pickup", {}),
]


def fill(value, route, stop):
    if isinstance(value, str):
        return value.replace("{route}", str(route)).replace("{stop}", str(stop))
    if isinstance(value, dict):
        return {k: fill(v, route, stop) for k, v in value.items()}
    return value


@pytest.mark.parametrize("state", ["none", "pending", "rejected"])
async def test_x7_unapproved_students_are_gated(client, admin, make_route, new_student, state):
    route = await make_route()
    uid, headers = await new_student()
    if state != "none":
        await client.put(f"{API}/me/registration", json=body(route["id"]), headers=headers)
    if state == "rejected":
        _, adm = await admin()
        await client.post(f"{API}/admin/students/{uid}/reject", json={"note": "no"}, headers=adm)
    for method, url, kw in GATED:
        resp = await getattr(client, method)(f"{API}{fill(url, route['id'], route['stops'][0])}", headers=headers,
                                             **fill(kw, route["id"], route["stops"][0]))
        assert resp.status_code == 403 and err(resp) == "REGISTRATION_REQUIRED", (state, method, url, resp.text)
    # Still open: registration, routes, schedules, announcements, push token, consents, alert-settings read.
    for method, url, kw in (
        ("get", "/me/registration", {}), ("get", "/routes", {}), ("get", f"/routes/{route['id']}", {}),
        ("get", "/schedules", {}), ("get", "/announcements", {}), ("get", "/me", {}),
        ("get", "/me/alert-settings", {}),
        ("put", "/me/push-token", {"json": {"token": "t-1", "platform": "android"}}),
        ("put", "/me/consents", {"json": {"kind": "privacy_notice", "version": "1"}}),
    ):
        resp = await getattr(client, method)(f"{API}{url}", headers=headers, **kw)
        assert resp.status_code in (200, 204), (url, resp.status_code, resp.text)


async def _running(client, driver_with_bus, start_trip, post_fixes, fake_clock, route, label):
    driver = await driver_with_bus(route=route, label=label)
    trip = await start_trip(driver)
    await post_fixes(driver, trip["id"], [along_fix(100, fake_clock.current, speed=6.0)])
    return driver, trip


async def test_x7_approved_student_sees_only_their_routes_buses(
        client, live_app, admin, make_route, set_bus, register, driver_with_bus, start_trip, post_fixes,
        fake_clock, create_user, driver_login):
    r1, r2 = await make_route("R1"), await make_route("R2")
    uid, student = await register(1, r1["id"])
    bus = await set_bus(r1["id"])
    _, adm = await admin()
    await approve(client, adm, uid, bus)
    d1, _ = await _running(client, driver_with_bus, start_trip, post_fixes, fake_clock, r1, "Bus R1")
    d2, _ = await _running(client, driver_with_bus, start_trip, post_fixes, fake_clock, r2, "Bus R2")
    mine = (await client.get(f"{API}/buses/live", headers=student)).json()
    assert [b["label"] for b in mine] == ["Bus R1"]
    for headers in (adm, d1["headers"], d2["headers"]):
        assert [b["label"] for b in (await client.get(f"{API}/buses/live", headers=headers)).json()] == [
            "Bus R1", "Bus R2"]
    assert (await client.get(f"{API}/stops/{r1['stops'][1]}/eta", headers=student)).status_code == 200
    resp = await client.get(f"{API}/stops/{r2['stops'][1]}/eta", headers=student)
    assert resp.status_code == 404  # another route's stop: never leaks its buses
    assert (await client.get(f"{API}/stops/{r2['stops'][1]}/eta", headers=adm)).status_code == 200
    # Reassigned to another route's bus after a re-registration is not possible; rejecting hides everything.
    await client.post(f"{API}/admin/students/{uid}/reject", json={"note": "left"}, headers=adm)
    resp = await client.get(f"{API}/buses/live", headers=student)
    assert resp.status_code == 403 and err(resp) == "REGISTRATION_REQUIRED"


async def test_x7_websocket_fan_out_is_scoped_to_the_students_route(
        client, live_app, admin, make_route, set_bus, register, new_student, driver_with_bus, start_trip, post_fixes,
        fake_clock):
    r1, r2 = await make_route("R1"), await make_route("R2")
    bus = await set_bus(r1["id"])
    approved_id, approved = await register(1, r1["id"])
    pending_id, pending = await register(2, r1["id"])
    _, adm = await admin()
    await approve(client, adm, approved_id, bus)

    async def connect(headers):
        ws = FakeWS(live_app)
        task = asyncio.create_task(live_ws(ws))
        ws.say(json.dumps({"type": "auth", "token": headers["Authorization"].split()[1]}))
        await wait_until(lambda: any(c is ws for c in get_hub(live_app).clients))
        return ws, task

    ws_ok, t_ok = await connect(approved)
    ws_pending, t_pending = await connect(pending)
    ws_admin, t_admin = await connect(adm)
    await wait_until(lambda: hub_clients(live_app) == 3)
    d1 = await driver_with_bus(route=r1, label="Bus R1")
    d2 = await driver_with_bus(route=r2, label="Bus R2")
    trip1, trip2 = await start_trip(d1), await start_trip(d2)
    await post_fixes(d1, trip1["id"], [along_fix(100, fake_clock.current, speed=5.0)])
    await post_fixes(d2, trip2["id"], [along_fix(100, fake_clock.current, speed=5.0)])
    seen = lambda ws: sorted({m["trip_id"] for m in ws.sent if "trip_id" in m})  # noqa: E731
    assert seen(ws_ok) == [trip1["id"]]
    assert seen(ws_pending) == []
    assert seen(ws_admin) == sorted([trip1["id"], trip2["id"]])
    # Approving re-scopes the open socket at once.
    await approve(client, adm, pending_id, bus)
    fake_clock.advance(5)
    await post_fixes(d1, trip1["id"], [along_fix(150, fake_clock.current, speed=5.0)])
    assert seen(ws_pending) == [trip1["id"]]
    for ws in (ws_ok, ws_pending, ws_admin):
        ws.hang_up()
    await asyncio.gather(t_ok, t_pending, t_admin)


async def test_x7_pins_need_approval_and_the_profile_route(
        client, live_app, admin, make_route, set_bus, register):
    r1, r2 = await make_route("R1"), await make_route("R2")
    uid, student = await register(1, r1["id"])
    lat, lng = 34.1205, 74.8300
    pin = {"lat": lat, "lng": lng}
    resp = await client.post(f"{API}/pickups", json={"route_id": str(r1["id"]), **pin}, headers=student)
    assert resp.status_code == 403 and err(resp) == "REGISTRATION_REQUIRED"
    _, adm = await admin()
    await approve(client, adm, uid, await set_bus(r1["id"]))
    resp = await client.post(f"{API}/pickups", json={"route_id": str(r2["id"]), **pin}, headers=student)
    assert resp.status_code == 400 and "route_id" in resp.json()["error"]["message"]
    resp = await client.post(f"{API}/pickups", json={"route_id": str(r1["id"]), **pin}, headers=student)
    assert resp.status_code == 201


async def test_x7_alerts_only_reach_approved_students_on_the_trips_route(
        app, con, engine, push, world, student, fake_clock):
    from tests.test_alerts import approach  # same helper the alert tests use

    trip_a = await world("Bus A", route_name="Route A")
    trip_b = await world("Bus B", route_name="Route B")
    on_a = await student()                      # default test student: approved on the first route (A)
    on_b = await student()
    await con.execute("update public.student_profiles set route_id = $2 where user_id = $1", on_b, trip_b.route_id)
    pending = await student()
    await con.execute("update public.student_profiles set status = 'pending' where user_id = $1", pending)
    rejected = await student()
    await con.execute("update public.student_profiles set status = 'rejected' where user_id = $1", rejected)
    unregistered = await student()
    await con.execute("delete from public.student_profiles where user_id = $1", unregistered)
    await approach(app, engine, fake_clock, trip_a, [600, 420])
    assert await alert_count(con, on_a) == 1
    for other in (on_b, pending, rejected, unregistered):
        assert await alert_count(con, other) == 0
    await approach(app, engine, fake_clock, trip_b, [600, 420])
    assert await alert_count(con, on_b) == 1 and await alert_count(con, on_a) == 1
    assert await alert_count(con, pending) == 0


# --- driver roster ------------------------------------------------------------------------------------
async def test_x6_driver_roster_shows_name_and_department_only(
        client, admin, make_route, set_bus, register, driver_with_bus, start_trip, con, google_login):
    route = await make_route()
    driver = await driver_with_bus(route=route, label="Bus R")
    other_driver = await driver_with_bus(route=route, label="Bus S")
    s1, _ = await register(1, route["id"], department="Physics")
    s2, _ = await register(2, route["id"], department="History")
    await register(3, route["id"])             # pending: not listed
    s4, _ = await register(4, route["id"])       # approved on the other bus: not listed
    _, adm = await admin()
    await con.execute("update public.buses set capacity = 5 where id = any($1::uuid[])",
                      [driver["bus_id"], other_driver["bus_id"]])
    await approve(client, adm, s1, driver["bus_id"])
    await approve(client, adm, s2, driver["bus_id"])
    await approve(client, adm, s4, other_driver["bus_id"])
    trip = await start_trip(driver)
    resp = await client.get(f"{API}/trips/{trip['id']}/roster", headers=driver["headers"])
    assert resp.status_code == 200, resp.text
    items = resp.json()["items"]
    assert [(i["name"], i["department"]) for i in items] == [("Student 1", "Physics"), ("Student 2", "History")]
    assert all(set(i) == {"student_id", "name", "department", "enrollment_no", "has_photo"} for i in items)
    assert {i["student_id"] for i in items} == {str(s1), str(s2)}
    assert "+91" not in resp.text and "@" not in resp.text
    other_trip = await start_trip(other_driver)
    resp = await client.get(f"{API}/trips/{trip['id']}/roster", headers=other_driver["headers"])
    assert resp.status_code == 403 and err(resp) == "NOT_YOUR_TRIP"
    assert (await client.get(f"{API}/trips/{uuid4()}/roster", headers=driver["headers"])).status_code == 404
    student_headers = (await register(5, route["id"]))[1]
    for headers in (student_headers, adm):
        resp = await client.get(f"{API}/trips/{other_trip['id']}/roster", headers=headers)
        assert resp.status_code == 403 and err(resp) == "FORBIDDEN_ROLE"
    # The waiting-students list is unchanged and still anonymous.
    resp = await client.get(f"{API}/trips/{trip['id']}/pickups", headers=driver["headers"])
    assert resp.status_code == 200 and resp.json() == {"items": []}


async def test_x5_deleting_the_account_deletes_the_registration(
        client, con, make_route, set_bus, register, delete_account):
    route = await make_route()
    uid, _ = await register(1, route["id"])
    assert await con.fetchval("select count(*) from public.student_profiles where user_id = $1", uid) == 1
    await delete_account(uid)
    assert await con.fetchval("select count(*) from public.student_profiles where user_id = $1", uid) == 0
    assert isinstance(con, asyncpg.Connection)
