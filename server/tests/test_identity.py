"""V1.3 identity: registration photo/enrollment/address, route lock, bus auto-assign, deregistration,
the digital bus card, my bus + driver card, driver profile (docs/v1/v13-spec.md decisions 1-6, 11, 12)."""
# ruff: noqa: F811  (pytest fixtures imported from the helper modules)

from __future__ import annotations

import logging
from uuid import UUID, uuid4

import pytest

from app.modules.buscard import service as card
from app.modules.students.autoassign import Candidate, choose_bus
from app.modules.students.photos import check_image, sniff_image
from tests.admin_helpers import admin, err, insert_route  # noqa: F401
from tests.conftest import bearer
from tests.test_students import API, JPEG, PHONE, approve, body, new_student, register, set_bus  # noqa: F401
from tests.tracking_support import fake_clock  # noqa: F401

pytest_plugins = ["tests.tracking_support"]

PNG = bytes.fromhex("89504e470d0a1a0a") + b"png-data" * 8
JPEG_HEADERS = {"Content-Type": "image/jpeg"}


@pytest.fixture
def config_overrides() -> dict:
    return {"rate_bus_verify_per_ip": 8}


async def put_photo(client, headers, data=JPEG, content_type="image/jpeg"):
    return await client.put(f"{API}/me/registration/photo", content=data,
                            headers={**headers, "Content-Type": content_type})


@pytest.fixture
def driver_on_bus(con, create_user, driver_login):
    """A driver linked to `bus_id`; returns (driver_id, headers)."""

    async def make(bus_id, *, name="Dan Driver", phone="+919800000001"):
        driver_id = await create_user("driver", name=name, phone=phone)
        await con.execute("update public.buses set driver_id = $2 where id = $1", bus_id, driver_id)
        tokens = await driver_login(phone)
        return driver_id, bearer(tokens["access_token"])

    return make


# --- pure rules ---------------------------------------------------------------------------------------
def _c(label, plate, capacity, assigned, n=0):
    return Candidate(UUID(int=n + 1), label, plate, capacity, assigned)


def test_choose_bus_prefers_the_requested_label_or_plate_case_insensitively():
    a, b = _c("Bus 1", "JK01AA0001", 10, 0, 1), _c("Bus 2", "JK01BB0002", 10, 8, 2)
    assert choose_bus([a, b], "bus 2") == b
    assert choose_bus([a, b], "  jk01bb0002 ") == b


def test_choose_bus_falls_back_to_most_free_seats_when_the_request_is_full_or_unknown():
    a, b = _c("Bus 1", "P1", 10, 2, 1), _c("Bus 2", "P2", 10, 10, 2)
    assert choose_bus([a, b], "Bus 2") == a  # requested bus is full
    assert choose_bus([a, b], "Nope") == a
    assert choose_bus([a, b], None) == a
    c = _c("Bus 3", "P3", 10, 1, 3)
    assert choose_bus([a, b, c], None) == c


def test_choose_bus_ties_are_deterministic_and_no_capacity_means_no_seat():
    a, b = _c("Bus A", "P1", 5, 0, 1), _c("Bus B", "P2", 5, 0, 2)
    assert choose_bus([b, a], None) == a
    assert choose_bus([_c("Bus", "P", None, 0), _c("Full", "Q", 3, 3, 2)], None) is None
    assert choose_bus([], "Bus") is None


def test_image_sniffing_checks_the_bytes_not_just_the_header():
    assert sniff_image(JPEG) == "image/jpeg" and sniff_image(PNG) == "image/png" and sniff_image(b"GIF89a") is None
    assert check_image(PNG, "image/png; charset=binary", 1000) == "image/png"
    for data, ctype in ((JPEG, "image/png"), (b"not an image", "image/jpeg"), (b"", "image/jpeg"),
                        (JPEG, "text/plain"), (JPEG, None)):
        with pytest.raises(Exception, match=r"Content-Type|body"):
            check_image(data, ctype, 1000)
    with pytest.raises(Exception, match="larger"):
        check_image(JPEG * 100, "image/jpeg", 50)


def test_card_tokens_reject_tampering():
    key = card.derive_key("secret-a")
    payload = {"v": 1, "sub": "x", "until": "2030-07-31"}
    _, token = card.sign(key, payload)
    assert card.open_token(key, token) == payload
    assert card.open_token(card.derive_key("secret-b"), token) is None
    body_part, sig = token.split(".")
    flipped = body_part[:-2] + ("AA" if not body_part.endswith("AA") else "BB")
    for bad in (f"{flipped}.{sig}", f"{body_part}.{sig[:-2]}AA", body_part, "", "a.b.c", "!!.!!"):
        assert card.open_token(key, bad) is None
    assert card.default_valid_until(__import__("datetime").date(2026, 8, 1)).isoformat() == "2027-07-31"
    assert card.default_valid_until(__import__("datetime").date(2026, 7, 31)).isoformat() == "2026-07-31"


# --- registration: enrollment, address, photo --------------------------------------------------------
async def test_registration_needs_enrollment_address_and_photo_to_be_complete(client, make_route, new_student):
    route = await make_route()
    _, headers = await new_student()
    resp = await client.put(f"{API}/me/registration", json={k: v for k, v in body(route["id"]).items()
                                                            if k != "enrollment_no"}, headers=headers)
    assert resp.status_code == 400
    resp = await client.put(f"{API}/me/registration", json=body(route["id"]), headers=headers)
    reg = resp.json()
    assert reg["enrollment_no"] == "UOK-2024-001" and reg["home_address"].startswith("12 Lake")
    assert reg["has_photo"] is False and reg["complete"] is False
    resp = await put_photo(client, headers)
    assert resp.status_code == 200 and resp.json()["has_photo"] is True and resp.json()["complete"] is True
    assert "photo" not in resp.json()


async def test_photo_upload_validation(client, make_route, new_student):
    route = await make_route()
    _, headers = await new_student()
    assert (await put_photo(client, headers)).status_code == 404  # no registration yet
    await client.put(f"{API}/me/registration", json=body(route["id"]), headers=headers)
    for data, ctype in ((b"x" * 400_000, "image/jpeg"), (b"", "image/jpeg"), (b"GIF89a..", "image/jpeg"),
                        (JPEG, "image/png"), (JPEG, "application/octet-stream")):
        resp = await put_photo(client, headers, data, ctype)
        assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR", (ctype, len(data))
    big = JPEG + b"0" * 307_200  # one byte over the limit once the header is counted
    assert (await put_photo(client, headers, big)).status_code == 400
    assert (await put_photo(client, headers, PNG, "image/png")).status_code == 200
    assert (await client.put(f"{API}/me/registration/photo", content=JPEG)).status_code == 401


async def test_photo_visibility_by_role(client, con, admin, make_route, set_bus, register, new_student,
                                        driver_on_bus, create_user, driver_login):
    route = await make_route()
    bus = await set_bus(route["id"])
    uid, headers = await register(1, route["id"])
    other_id, other = await register(2, route["id"])
    _, adm = await admin()
    url = f"{API}/students/{uid}/photo"
    # Before approval only the student and an admin can see it.
    assert (await client.get(url, headers=headers)).content == JPEG
    resp = await client.get(url, headers=adm)
    assert resp.status_code == 200 and resp.headers["content-type"] == "image/jpeg"
    assert resp.headers["cache-control"] == "private, no-store"
    assert (await client.get(url, headers=other)).status_code == 403
    assert (await client.get(url)).status_code == 401
    _, driver = await driver_on_bus(bus)
    assert (await client.get(url, headers=driver)).status_code == 403
    await approve(client, adm, uid, bus)
    assert (await client.get(url, headers=driver)).content == JPEG
    await create_user("driver", name="Other", phone="+919800000002")
    stranger = bearer((await driver_login("+919800000002"))["access_token"])
    assert (await client.get(url, headers=stranger)).status_code == 403
    assert (await client.get(f"{API}/students/{uuid4()}/photo", headers=adm)).status_code == 404
    # An approved student cannot swap the photo the admin reviewed.
    assert (await put_photo(client, headers)).status_code == 409
    # Lists and detail never carry the bytes.
    listing = (await client.get(f"{API}/admin/students", headers=adm)).json()["items"]
    assert all("photo" not in row and "home_address" not in row for row in listing)
    assert {r["id"]: r["has_photo"] for r in listing}[str(other_id)] is True


async def test_approval_refuses_a_registration_without_photo(client, con, admin, make_route, set_bus, new_student):
    route = await make_route()
    uid, headers = await new_student()
    await client.put(f"{API}/me/registration", json=body(route["id"]), headers=headers)
    _, adm = await admin()
    resp = await approve(client, adm, uid, await set_bus(route["id"]), expect=400)
    assert "incomplete" in resp.json()["error"]["message"]
    row = next(r for r in (await client.get(f"{API}/admin/students", headers=adm)).json()["items"]
               if r["id"] == str(uid))
    assert row["registration_state"] == "incomplete" and "photo" in row["approval_diagnostic"]
    await put_photo(client, headers)
    await approve(client, adm, uid, await set_bus(route["id"], label="Other bus"))


# --- route lock ---------------------------------------------------------------------------------------
async def test_route_is_locked_after_first_submission_unless_rejected(client, admin, make_route, set_bus, register):
    route, other = await make_route(), await make_route("Other")
    uid, headers = await register(1, route["id"])
    resp = await client.put(f"{API}/me/registration", json=body(other["id"]), headers=headers)
    assert resp.status_code == 409 and err(resp) == "IN_USE"
    resp = await client.put(f"{API}/me/registration", json=body(route["id"], department="Chem"), headers=headers)
    assert resp.status_code == 200 and resp.json()["department"] == "Chem"
    _, adm = await admin()
    await client.post(f"{API}/admin/students/{uid}/reject", json={"note": "wrong route"}, headers=adm)
    resp = await client.put(f"{API}/me/registration", json=body(other["id"]), headers=headers)
    assert resp.status_code == 200 and resp.json()["route_id"] == str(other["id"])
    # The admin can still reassign an approved student to a bus on the same route; the route itself is theirs to fix.
    bus = await set_bus(other["id"])
    await approve(client, adm, uid, bus)
    resp = await client.put(f"{API}/me/registration", json=body(other["id"], enrollment_no="CHANGED"), headers=headers)
    assert resp.status_code == 409


# --- approval auto-assign -----------------------------------------------------------------------------
async def test_approve_without_bus_assigns_the_requested_bus_else_the_emptiest(client, admin, make_route, set_bus,
                                                                              register):
    route = await make_route()
    bus1 = await set_bus(route["id"], capacity=2, label="Bus 1")
    bus2 = await set_bus(route["id"], capacity=5, label="Bus 2")
    _, adm = await admin()
    first, _ = await register(1, route["id"], requested_bus_label="bus 1")
    resp = await client.post(f"{API}/admin/students/{first}/approve", headers=adm)
    assert resp.status_code == 200 and resp.json()["bus_id"] == str(bus1)
    second, _ = await register(2, route["id"], requested_bus_label="BUS 1")
    resp = await client.post(f"{API}/admin/students/{second}/approve", json={}, headers=adm)
    assert resp.json()["bus_id"] == str(bus1)
    third, _ = await register(3, route["id"], requested_bus_label="Bus 1")  # Bus 1 is full now
    resp = await client.post(f"{API}/admin/students/{third}/approve", json={}, headers=adm)
    assert resp.json()["bus_id"] == str(bus2)
    fourth, _ = await register(4, route["id"], requested_bus_label=None)
    resp = await client.post(f"{API}/admin/students/{fourth}/approve", headers=adm)
    assert resp.json()["bus_id"] == str(bus2)


async def test_approve_without_bus_and_no_seat_is_409_but_manual_approve_is_unchanged(client, admin, make_route,
                                                                                    set_bus, register):
    route = await make_route()
    full = await set_bus(route["id"], capacity=0)
    uid, _ = await register(1, route["id"])
    _, adm = await admin()
    resp = await client.post(f"{API}/admin/students/{uid}/approve", headers=adm)
    assert resp.status_code == 409 and err(resp) == "NO_SEAT"
    assert (await client.post(f"{API}/admin/students/{uid}/approve", json={"bus_id": str(full)},
                              headers=adm)).status_code == 409
    roomy = await set_bus(route["id"], capacity=3)
    assert (await client.post(f"{API}/admin/students/{uid}/approve", json={"bus_id": str(roomy)},
                              headers=adm)).status_code == 200


# --- deregistration -----------------------------------------------------------------------------------
async def test_students_cannot_delete_themselves_and_deregistration_is_deduplicated(client, admin, make_route,
                                                                                    register):
    route = await make_route()
    uid, headers = await register(1, route["id"])
    resp = await client.delete(f"{API}/me", headers=headers)
    assert resp.status_code == 403 and err(resp) == "FORBIDDEN_ROLE"
    assert (await client.get(f"{API}/me/deregistration-request", headers=headers)).json() is None
    resp = await client.post(f"{API}/me/deregistration-request", json={"reason": "Moved away"}, headers=headers)
    assert resp.status_code == 201 and resp.json()["status"] == "pending" and resp.json()["reason"] == "Moved away"
    again = await client.post(f"{API}/me/deregistration-request", json={}, headers=headers)
    assert again.status_code == 200 and again.json()["id"] == resp.json()["id"]
    assert (await client.get(f"{API}/me/deregistration-request", headers=headers)).json()["id"] == resp.json()["id"]
    _, adm = await admin()
    detail = (await client.get(f"{API}/admin/students/{uid}", headers=adm)).json()
    assert detail["deregistration"]["status"] == "pending" and detail["home_address"].startswith("12 Lake")
    assert (await client.post(f"{API}/me/deregistration-request", json={}, headers=adm)).status_code == 403


async def test_admin_rejects_then_approves_deregistration(client, con, admin, make_route, register, new_student):
    route = await make_route()
    uid, headers = await register(1, route["id"])
    _, adm = await admin()
    req = (await client.post(f"{API}/me/deregistration-request", json={"reason": "x"}, headers=headers)).json()
    listing = (await client.get(f"{API}/admin/deregistrations?status=pending", headers=adm)).json()
    assert [i["id"] for i in listing["items"]] == [req["id"]]
    assert listing["items"][0]["name"] == "Student 1" and listing["items"][0]["enrollment_no"] == "UOK-2024-001"
    assert "home_address" not in listing["items"][0]
    resp = await client.post(f"{API}/admin/deregistrations/{req['id']}/reject", json={"note": ""}, headers=adm)
    assert resp.status_code == 400
    resp = await client.post(f"{API}/admin/deregistrations/{req['id']}/reject", json={"note": "Not yet"},
                             headers=adm)
    assert resp.status_code == 200 and resp.json()["status"] == "rejected" and resp.json()["admin_note"] == "Not yet"
    assert (await client.post(f"{API}/admin/deregistrations/{req['id']}/approve", headers=adm)).status_code == 409
    assert (await client.get(f"{API}/me/registration", headers=headers)).status_code == 200  # still here
    # The student may ask again; this time the admin approves and everything is deleted.
    second = (await client.post(f"{API}/me/deregistration-request", json={}, headers=headers)).json()
    assert second["id"] != req["id"]
    resp = await client.post(f"{API}/admin/deregistrations/{second['id']}/approve", headers=adm)
    assert resp.status_code == 200 and resp.json()["status"] == "approved"
    for table, col in (("users", "id"), ("student_profiles", "user_id"), ("sessions", "user_id"),
                       ("deregistration_requests", "user_id")):
        assert await con.fetchval(f"select count(*) from public.{table} where {col} = $1", uid) == 0, table
    assert (await client.get(f"{API}/me", headers=headers)).status_code == 401
    audit = await con.fetch("select actor_id, meta from public.audit_log where action = 'deregistration.approve'")
    assert len(audit) == 1 and audit[0]["meta"] == {}
    assert (await client.post(f"{API}/admin/deregistrations/{uuid4()}/approve", headers=adm)).status_code == 404
    _, bystander = await new_student(5)
    assert (await client.get(f"{API}/admin/deregistrations", headers=bystander)).status_code == 403


# --- bus card -----------------------------------------------------------------------------------------
async def card_for(client, con, admin, make_route, set_bus, register):
    route = await make_route()
    bus = await set_bus(route["id"], label="Bus 9")
    uid, headers = await register(1, route["id"])
    _, adm = await admin()
    await approve(client, adm, uid, bus)
    return uid, headers, adm, bus


async def test_bus_card_is_signed_and_verifiable(client, con, admin, make_route, set_bus, register):
    uid, headers, adm, bus = await card_for(client, con, admin, make_route, set_bus, register)
    resp = await client.get(f"{API}/me/bus-card", headers=headers)
    assert resp.status_code == 200, resp.text
    c = resp.json()
    assert c["name"] == "Student 1" and c["enrollment_no"] == "UOK-2024-001" and c["department"] == "Physics"
    assert c["bus_label"] == "Bus 9" and c["route_name"] == "Test Route" and c["has_photo"] is True
    assert c["card_no"].startswith("UOK-") and c["issued_at"].endswith("Z") and c["valid_until"].endswith("-07-31")
    assert c["qr_payload"].endswith("." + c["signature"])
    ok = (await client.get(f"{API}/bus-card/verify", params={"token": c["qr_payload"]})).json()
    assert ok == {"valid": True, "name": "Student 1", "bus_label": "Bus 9", "valid_until": c["valid_until"]}
    # Tampering with the payload or the signature is "not valid" and reveals nothing.
    head, sig = c["qr_payload"].split(".")
    for bad in (f"{head[:-3]}AAA.{sig}", f"{head}.{sig[:-3]}AAA", head, "garbage"):
        assert (await client.get(f"{API}/bus-card/verify", params={"token": bad})).json() == {
            "valid": False, "name": None, "bus_label": None, "valid_until": None}
    # A card whose student was un-approved is no longer valid; the live bus label is what verify reports.
    await con.execute("update public.buses set label = 'Bus 10' where id = $1", bus)
    live = (await client.get(f"{API}/bus-card/verify", params={"token": c["qr_payload"]})).json()
    assert live["bus_label"] == "Bus 10"
    await client.post(f"{API}/admin/students/{uid}/reject", json={"note": "x"}, headers=adm)
    assert (await client.get(f"{API}/bus-card/verify", params={"token": c["qr_payload"]})).json()["valid"] is False
    assert (await client.get(f"{API}/me/bus-card", headers=headers)).status_code == 403  # REGISTRATION_REQUIRED


async def test_bus_card_expires_and_validity_is_a_setting(client, con, app, admin, make_route, set_bus, register):
    _, headers, _, _ = await card_for(client, con, admin, make_route, set_bus, register)
    await con.execute("update public.settings set value = '\"2020-07-31\"' where key = 'bus_card_valid_until'")
    app.state.settings_store.invalidate()
    c = (await client.get(f"{API}/me/bus-card", headers=headers)).json()
    assert c["valid_until"] == "2020-07-31"
    expired = (await client.get(f"{API}/bus-card/verify", params={"token": c["qr_payload"]})).json()
    assert expired == {"valid": False, "name": "Student 1", "bus_label": "Bus 9", "valid_until": "2020-07-31"}
    await con.execute("update public.settings set value = '\"2999-07-31\"' where key = 'bus_card_valid_until'")
    app.state.settings_store.invalidate()
    c = (await client.get(f"{API}/me/bus-card", headers=headers)).json()
    assert (await client.get(f"{API}/bus-card/verify", params={"token": c["qr_payload"]})).json()["valid"] is True


async def test_bus_card_rules_and_verify_is_public_and_rate_limited(client, con, admin, make_route, new_student,
                                                                    create_user, driver_login):
    route = await make_route()
    _, pending = await new_student()
    await client.put(f"{API}/me/registration", json=body(route["id"]), headers=pending)
    assert (await client.get(f"{API}/me/bus-card", headers=pending)).status_code == 403
    assert (await client.get(f"{API}/me/bus-card")).status_code == 401
    assert (await client.get(f"{API}/bus-card/verify")).status_code == 400  # token is required (counts as 1 of 8)
    for _ in range(7):
        assert (await client.get(f"{API}/bus-card/verify", params={"token": "x"})).status_code == 200
    resp = await client.get(f"{API}/bus-card/verify", params={"token": "x"})
    assert resp.status_code == 429 and err(resp) == "RATE_LIMITED" and "retry-after" in resp.headers


# --- my bus, driver card, driver profile ----------------------------------------------------------------
async def test_student_sees_their_bus_and_driver_and_the_driver_photo(client, con, admin, make_route, set_bus,
                                                                      register, driver_on_bus, create_user,
                                                                      driver_login):
    route = await make_route()
    bus = await set_bus(route["id"], label="Bus 3", capacity=7)
    uid, headers = await register(1, route["id"])
    _, adm = await admin()
    assert (await client.get(f"{API}/me/bus", headers=headers)).status_code == 403  # not approved yet
    await approve(client, adm, uid, bus)
    assert (await client.get(f"{API}/me/bus", headers=headers)).json()["driver"] is None
    driver_id, driver = await driver_on_bus(bus, name="Dan Driver", phone="+919800000001")
    out = (await client.get(f"{API}/me/bus", headers=headers)).json()
    assert out["label"] == "Bus 3" and out["capacity"] == 7 and out["bus_id"] == str(bus)
    assert out["driver"] == {"id": str(driver_id), "name": "Dan Driver", "phone": "+919800000001",
                             "has_photo": False}
    url = f"{API}/drivers/{driver_id}/photo"
    assert (await client.get(url, headers=headers)).status_code == 404  # no photo yet
    # Admin uploads it; validation is the same as the student's.
    assert (await client.put(f"{API}/admin/drivers/{driver_id}/photo", content=b"nope", headers={
        **adm, **JPEG_HEADERS})).status_code == 400
    resp = await client.put(f"{API}/admin/drivers/{driver_id}/photo", content=PNG,
                            headers={**adm, "Content-Type": "image/png"})
    assert resp.status_code == 200 and resp.json()["has_photo"] is True
    assert (await client.get(f"{API}/admin/drivers/{driver_id}", headers=adm)).json()["has_photo"] is True
    assert (await client.get(f"{API}/admin/drivers", headers=adm)).json()["items"][0]["has_photo"] is True
    got = await client.get(url, headers=headers)
    assert got.status_code == 200 and got.content == PNG and got.headers["content-type"] == "image/png"
    assert (await client.get(url, headers=driver)).content == PNG  # the driver sees their own
    assert (await client.get(url, headers=adm)).status_code == 200
    assert (await client.get(f"{API}/me/bus", headers=headers)).json()["driver"]["has_photo"] is True
    # A student on another bus, or a different driver, may not.
    other_bus = await set_bus(route["id"], label="Bus 4")
    other, other_headers = await register(2, route["id"])
    await approve(client, adm, other, other_bus)
    assert (await client.get(url, headers=other_headers)).status_code == 403
    await create_user("driver", name="Eve", phone="+919800000009")
    eve = bearer((await driver_login("+919800000009"))["access_token"])
    assert (await client.get(url, headers=eve)).status_code == 403
    assert (await client.put(f"{API}/admin/drivers/{uuid4()}/photo", content=JPEG, headers={
        **adm, **JPEG_HEADERS})).status_code == 404
    assert (await client.put(f"{API}/admin/drivers/{driver_id}/photo", content=JPEG, headers={
        **headers, **JPEG_HEADERS})).status_code == 403


async def test_driver_profile_is_the_drivers_own(client, con, admin, make_route, set_bus, driver_on_bus):
    route = await make_route()
    bus = await set_bus(route["id"], label="Bus 5")
    driver_id, driver = await driver_on_bus(bus)
    _, adm = await admin()
    await client.patch(f"{API}/admin/drivers/{driver_id}", headers=adm, json={
        "employee_id": "E-17", "licence_no": "JK-123", "licence_expiry": "2030-01-31", "address": "Nowshera"})
    out = (await client.get(f"{API}/me/driver-profile", headers=driver)).json()
    assert out["name"] == "Dan Driver" and out["phone"] == "+919800000001"
    assert (out["employee_id"], out["licence_no"], out["licence_expiry"], out["address"]) == (
        "E-17", "JK-123", "2030-01-31", "Nowshera")
    assert out["has_photo"] is False and out["bus"]["label"] == "Bus 5"
    assert (await client.get(f"{API}/me/driver-profile", headers=adm)).status_code == 403


# --- admin student table + detail ---------------------------------------------------------------------
async def test_admin_student_rows_and_detail_have_enrollment_and_search(client, admin, make_route, set_bus,
                                                                         register):
    route = await make_route()
    bus = await set_bus(route["id"], label="Bus 6")
    a, _ = await register(1, route["id"], enrollment_no="ENR-AAA")
    b, _ = await register(2, route["id"], enrollment_no="ENR-BBB")
    _, adm = await admin()
    await approve(client, adm, a, bus)
    rows = (await client.get(f"{API}/admin/students?q=enr-bb", headers=adm)).json()["items"]
    assert [r["id"] for r in rows] == [str(b)] and rows[0]["enrollment_no"] == "ENR-BBB"
    detail = (await client.get(f"{API}/admin/students/{a}", headers=adm)).json()
    assert detail["enrollment_no"] == "ENR-AAA" and detail["home_address"] == "12 Lake Road, Srinagar"
    assert detail["phone"] == PHONE and detail["department"] == "Physics" and detail["route_name"] == "Test Route"
    assert detail["bus_label"] == "Bus 6" and detail["has_photo"] is True and detail["deregistration"] is None
    assert detail["status"] == "approved"


# --- privacy ------------------------------------------------------------------------------------------
async def test_no_address_or_photo_in_audit_meta_or_logs(client, con, caplog, admin, make_route, set_bus, register):
    from app.logging_mw import redact

    route = await make_route()
    bus = await set_bus(route["id"])
    with caplog.at_level(logging.DEBUG):
        uid, _ = await register(1, route["id"])
        _, adm = await admin()
        await approve(client, adm, uid, bus)
    rows = await con.fetch("select meta::text as m from public.audit_log")
    assert rows and all("Lake Road" not in r["m"] and "photo" not in r["m"].lower() for r in rows)
    assert "Lake Road" not in caplog.text
    assert "[redacted]" in redact("home_address=12 Lake Road photo=abc123")
    assert "Lake" not in redact('{"home_address": "12 Lake Road"}')
