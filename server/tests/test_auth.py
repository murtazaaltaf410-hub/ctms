"""Auth: TC1, TC2 (uniform failure), TC3, TC4 (role), U1, U3, X4 (driver password login), tokens,
refresh rotation/reuse, logout."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import jwt
import pytest

from app.security import create_access_token, hash_password, verify_password
from tests.conftest import DEFAULT_DRIVER_PASSWORD, bearer

DRIVER_PHONE = "+919000000001"
PW = DEFAULT_DRIVER_PASSWORD
LOGIN = "/api/v1/auth/login"


def err(resp) -> str:
    return resp.json()["error"]["code"]


# --- Google sign-in (TC1, U1) ------------------------------------------------------


async def test_tc1_google_sign_in_university_and_personal_accounts(client, google_login, con):
    uni = await google_login("sub-uni", "Asha@UoK.edu.in", "Asha")
    personal = await google_login("sub-gmail", "asha.k@gmail.com", "Asha K")
    for tokens in (uni, personal):
        assert tokens["access_token"] and tokens["refresh_token"]
        assert tokens["user"]["role"] == "student"
        assert tokens["user"]["bus"] is None
        assert tokens["user"]["created_at"].endswith("Z")
    assert uni["user"]["email"] == "asha@uok.edu.in"  # stored lower-case
    again = await google_login("sub-uni", "asha@uok.edu.in")
    assert again["user"]["id"] == uni["user"]["id"]
    assert await con.fetchval("select count(*) from public.users where google_sub like 'sub-%'") == 2


async def test_google_invalid_or_unverified_token(client, google):
    resp = await client.post("/api/v1/auth/google", json={"id_token": "forged"})
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"
    tok = google.token("sub-x", "x@gmail.com", email_verified=False)
    resp = await client.post("/api/v1/auth/google", json={"id_token": tok})
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"


async def test_admin_from_allowlist_and_demotion_logged(client, google_login, con):
    await con.execute("insert into public.admin_allowlist (email) values ('boss@uok.edu.in')")
    tokens = await google_login("sub-boss", "boss@uok.edu.in")
    assert tokens["user"]["role"] == "admin"
    await con.execute("delete from public.admin_allowlist where email = 'boss@uok.edu.in'")
    tokens = await google_login("sub-boss", "boss@uok.edu.in")
    assert tokens["user"]["role"] == "student"
    meta = await con.fetchval(
        "select meta from public.audit_log where action = 'user.role_change' and target_id = $1", tokens["user"]["id"]
    )
    assert meta == {"from": "admin", "to": "student", "reason": "admin_allowlist"}


@pytest.mark.parametrize("config_overrides", [{"seed_admin_email": "First.Admin@UoK.edu.in"}])
async def test_seed_admin_email_is_admin(google_login):
    assert (await google_login("sub-first", "first.admin@uok.edu.in"))["user"]["role"] == "admin"


async def test_inactive_google_user_rejected(client, google, create_user):
    await create_user("student", email="gone@gmail.com", active=False)
    resp = await client.post("/api/v1/auth/google", json={"id_token": google.token("s", "gone@gmail.com")})
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"


# --- Firebase email/password sign-in -------------------------------------------------


async def test_firebase_email_creates_and_links_verified_student(client, firebase_login, google_login, con):
    first = await firebase_login("firebase-asha", "Asha@uok.edu.in", "Asha")
    assert first["user"]["role"] == "student"
    assert first["user"]["email"] == "asha@uok.edu.in"
    assert (
        await con.fetchval("select firebase_uid from public.users where id = $1", first["user"]["id"])
        == "firebase-asha"
    )

    # A verified Google identity for the same email links to the existing CTMS user.
    linked = await google_login("google-asha", "asha@uok.edu.in", "Asha")
    assert linked["user"]["id"] == first["user"]["id"]


async def test_firebase_email_rejects_unverified_and_driver_accounts(client, firebase, create_user):
    unverified = await client.post(
        "/api/v1/auth/firebase",
        json={"id_token": firebase.token("firebase-unverified", "nope@uok.edu.in", email_verified=False)},
    )
    assert unverified.status_code == 401 and err(unverified) == "TOKEN_INVALID"

    await create_user("driver", email="driver@uok.edu.in", phone=DRIVER_PHONE)
    driver = await client.post(
        "/api/v1/auth/firebase",
        json={"id_token": firebase.token("firebase-driver", "driver@uok.edu.in")},
    )
    assert driver.status_code == 403 and err(driver) == "FORBIDDEN_ROLE"


# --- Password login (X4; replaces phone OTP, ADR-10) -------------------------------------


async def login(client, identifier, password=PW):
    return await client.post(LOGIN, json={"identifier": identifier, "password": password})


def test_password_hash_roundtrip_and_format():
    h = hash_password("S3cret-pass")
    scheme, n, r, p, _salt, _digest = h.split("$")
    assert (scheme, int(n), int(r), int(p)) == ("scrypt", 2**14, 8, 1)
    assert "S3cret-pass" not in h and h != hash_password("S3cret-pass")  # salted
    assert verify_password("S3cret-pass", h) and not verify_password("s3cret-pass", h)
    # Missing / garbled hashes are simply "no match" (and cost one scrypt run, like a real check).
    assert not verify_password("x", None) and not verify_password("x", "plain") and not verify_password("x", "a$b")


async def test_driver_login_returns_tokens_bus_and_must_change(client, create_user, create_bus, con):
    driver_id = await create_user("driver", name="Ravi", phone=DRIVER_PHONE)
    bus_id = await create_bus(driver_id, label="Bus 7", plate="JK01AB1234")
    resp = await login(client, DRIVER_PHONE)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["access_token"] and body["refresh_token"] and body["must_change_password"] is True
    user = body["user"]
    assert user["role"] == "driver" and user["phone"] == DRIVER_PHONE
    assert user["bus"] == {"id": str(bus_id), "label": "Bus 7", "plate": "JK01AB1234", "default_route_id": None}
    assert (await client.get("/api/v1/me", headers=bearer(body["access_token"]))).status_code == 200
    meta = await con.fetchval("select meta from public.audit_log where action = 'auth.password.login'")
    assert meta == {"provider": "password"}


async def test_login_by_userid_email_and_phone_with_normalisation(client, create_user):
    driver_id = await create_user(
        "driver", name="Multi", phone=DRIVER_PHONE, email="multi@uok.edu.in", userid="multi.driver"
    )
    for ident in ("multi.driver", " Multi.Driver ", "MULTI@UoK.edu.in", DRIVER_PHONE, "+91 90000-00001"):
        resp = await login(client, ident)
        assert resp.status_code == 200, (ident, resp.text)
        assert resp.json()["user"]["id"] == str(driver_id)


async def test_tc2_failures_are_uniform(client, create_user):
    await create_user("driver", phone=DRIVER_PHONE, userid="active.one")
    await create_user("driver", phone="+919000000002", userid="gone.one", active=False)
    await create_user("student", email="stud@uok.edu.in")
    cases = [
        login(client, "active.one", "wrong-password"),  # wrong password
        login(client, "nobody.here"),  # unknown identifier
        login(client, "gone.one"),  # inactive driver, right password
        login(client, "stud@uok.edu.in"),  # a student is not a driver
        login(client, "+919999999999"),  # unknown phone
    ]
    seen = []
    for coro in cases:
        resp = await coro
        assert resp.status_code == 401 and err(resp) == "INVALID_CREDENTIALS"
        seen.append(resp.json())
    assert all(body == seen[0] for body in seen)


async def test_login_validation_is_400(client):
    for body in ({}, {"identifier": "x"}, {"identifier": "", "password": "p"}, {"identifier": "x", "password": ""}):
        resp = await client.post(LOGIN, json=body)
        assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"


async def test_driver_without_password_cannot_login(client, con, create_user):
    driver_id = await create_user("driver", phone=DRIVER_PHONE)
    await con.execute("update public.users set password_hash = null where id = $1", driver_id)
    resp = await login(client, DRIVER_PHONE, "")
    assert resp.status_code == 400  # empty password never reaches the check
    resp = await login(client, DRIVER_PHONE)
    assert resp.status_code == 401 and err(resp) == "INVALID_CREDENTIALS"


async def test_lockout_after_n_failures_then_unlock_after_expiry(client, create_user, con):
    driver_id = await create_user("driver", phone=DRIVER_PHONE)
    for _ in range(5):  # login_max_failures = 5 (seed)
        assert err(await login(client, DRIVER_PHONE, "bad-password")) == "INVALID_CREDENTIALS"
    row = await con.fetchrow("select failed_logins, locked_until from public.users where id = $1", driver_id)
    assert row["locked_until"] is not None and row["failed_logins"] == 0
    # Locked: even the right password is refused, with the usual error.
    resp = await login(client, DRIVER_PHONE)
    assert resp.status_code == 401 and err(resp) == "INVALID_CREDENTIALS"
    # The lock expires (login_lock_s = 900 s).
    await con.execute("update public.users set locked_until = now() - interval '1 second' where id = $1", driver_id)
    assert (await login(client, DRIVER_PHONE)).status_code == 200
    assert await con.fetchval("select locked_until from public.users where id = $1", driver_id) is None


async def test_success_resets_failure_counter(client, create_user, con):
    driver_id = await create_user("driver", phone=DRIVER_PHONE)
    for _ in range(3):
        await login(client, DRIVER_PHONE, "bad-password")
    assert await con.fetchval("select failed_logins from public.users where id = $1", driver_id) == 3
    assert (await login(client, DRIVER_PHONE)).status_code == 200
    assert await con.fetchval("select failed_logins from public.users where id = $1", driver_id) == 0


@pytest.mark.parametrize("config_overrides", [{"rate_login_per_ip": 3}])
async def test_login_per_ip_rate_limit(client):
    for _ in range(3):
        assert (await login(client, "nobody", "whatever")).status_code == 401
    resp = await login(client, "nobody", "whatever")
    assert resp.status_code == 429 and err(resp) == "RATE_LIMITED" and int(resp.headers["Retry-After"]) >= 1


async def test_u3_deactivated_driver_signed_out_and_number_reissued(client, create_user, driver_login, con):
    old_id = await create_user("driver", name="Old", phone=DRIVER_PHONE)
    old = await driver_login(DRIVER_PHONE)
    await con.execute("update public.users set active = false where id = $1", old_id)
    resp = await client.get("/api/v1/me", headers=bearer(old["access_token"]))
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"
    resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": old["refresh_token"]})
    assert resp.status_code == 401
    assert err(await login(client, DRIVER_PHONE)) == "INVALID_CREDENTIALS"  # the inactive one cannot sign in
    new_id = await create_user("driver", name="New", phone=DRIVER_PHONE)
    new = await driver_login(DRIVER_PHONE)
    assert new["user"]["id"] == str(new_id)


# --- Change password ------------------------------------------------------------------------


async def test_change_password_flow(client, create_user, driver_login, con):
    driver_id = await create_user("driver", phone=DRIVER_PHONE)
    tokens = await driver_login(DRIVER_PHONE)
    headers = bearer(tokens["access_token"])
    assert tokens["must_change_password"] is True

    path = "/api/v1/auth/change-password"
    bad = {"current_password": "nope-nope", "new_password": "Brand-new-1"}
    wrong = await client.post(path, json=bad, headers=headers)
    assert wrong.status_code == 401 and err(wrong) == "INVALID_CREDENTIALS"
    short = await client.post(path, json={"current_password": PW, "new_password": "short"}, headers=headers)
    assert short.status_code == 400 and err(short) == "VALIDATION_ERROR"
    same = await client.post(path, json={"current_password": PW, "new_password": PW}, headers=headers)
    assert same.status_code == 400 and err(same) == "VALIDATION_ERROR"

    # A second device signs in, which replaced the first; change the password from the second one.
    other = await driver_login(DRIVER_PHONE)
    other_headers = bearer(other["access_token"])
    resp = await client.post(path, json={"current_password": PW, "new_password": "Brand-new-1"}, headers=other_headers)
    assert resp.status_code == 204 and resp.content == b""
    assert (await client.get("/api/v1/me", headers=other_headers)).status_code == 200  # this session survives
    assert await con.fetchval("select must_change_password from public.users where id = $1", driver_id) is False
    assert await con.fetchval("select action from public.audit_log where action = 'auth.password.change'")

    assert err(await login(client, DRIVER_PHONE, PW)) == "INVALID_CREDENTIALS"
    new = await login(client, DRIVER_PHONE, "Brand-new-1")
    assert new.status_code == 200 and new.json()["must_change_password"] is False


async def test_change_password_requires_driver_token(client, google_login):
    body = {"current_password": PW, "new_password": "Brand-new-1"}
    assert (await client.post("/api/v1/auth/change-password", json=body)).status_code == 401
    student = await google_login()
    resp = await client.post("/api/v1/auth/change-password", json=body, headers=bearer(student["access_token"]))
    assert resp.status_code == 403 and err(resp) == "FORBIDDEN_ROLE"


async def test_change_password_revokes_other_live_sessions(client, create_user, con):
    driver_id = await create_user("driver", phone=DRIVER_PHONE)
    first = (await login(client, DRIVER_PHONE)).json()
    second = (await login(client, DRIVER_PHONE)).json()  # replaces the first
    # Force a still-live third session for the same driver (cannot happen via /auth/login alone).
    await con.execute(
        "insert into public.sessions (user_id, refresh_hash, expires_at) values ($1, 'x', now() + interval '1 day')",
        driver_id,
    )
    body = {"current_password": PW, "new_password": "Brand-new-1"}
    resp = await client.post("/api/v1/auth/change-password", json=body, headers=bearer(second["access_token"]))
    assert resp.status_code == 204
    reasons = sorted(r["revoked_reason"] or "-" for r in await con.fetch("select revoked_reason from public.sessions"))
    assert reasons == ["-", "password_changed", "replaced"]
    assert (await client.get("/api/v1/me", headers=bearer(first["access_token"]))).status_code == 401


# --- Responses never carry a password or hash -----------------------------------------------


async def test_hash_never_in_any_response(client, create_user, driver_login):
    await create_user("driver", phone=DRIVER_PHONE)
    tokens = await driver_login(DRIVER_PHONE)
    me = await client.get("/api/v1/me", headers=bearer(tokens["access_token"]))
    for text in (str(tokens), me.text):
        assert "scrypt" not in text and "password_hash" not in text and PW not in text


# --- Sessions (TC3 / T11) -----------------------------------------------------------


async def test_tc3_second_login_replaces_first_session(client, create_user, driver_login):
    await create_user("driver", phone=DRIVER_PHONE)
    first = await driver_login(DRIVER_PHONE)
    second = await driver_login(DRIVER_PHONE)
    resp = await client.get("/api/v1/me", headers=bearer(first["access_token"]))
    assert resp.status_code == 401 and err(resp) == "SESSION_REPLACED"
    resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": first["refresh_token"]})
    assert resp.status_code == 401 and err(resp) == "SESSION_REPLACED"
    assert (await client.get("/api/v1/me", headers=bearer(second["access_token"]))).status_code == 200


async def test_students_may_have_several_sessions(client, google_login):
    a = await google_login()
    b = await google_login()
    for tokens in (a, b):
        assert (await client.get("/api/v1/me", headers=bearer(tokens["access_token"]))).status_code == 200


# --- Access tokens: expired vs invalid ------------------------------------------------


async def test_missing_garbage_and_wrong_secret_are_token_invalid(client, google_login):
    tokens = await google_login()
    claims = jwt.decode(tokens["access_token"], options={"verify_signature": False})
    forged = jwt.encode({**claims, "exp": claims["exp"] + 60}, "another-secret-" + "x" * 30, algorithm="HS256")
    for headers in ({}, bearer("garbage"), bearer(forged), {"Authorization": "Basic abc"}):
        resp = await client.get("/api/v1/me", headers=headers)
        assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID", headers
        assert resp.headers["WWW-Authenticate"] == "Bearer"


async def test_expired_access_token_is_token_expired(client, google_login, config):
    tokens = await google_login()
    claims = jwt.decode(tokens["access_token"], options={"verify_signature": False})
    old = create_access_token(
        user_id=claims["sub"],
        session_id=claims["sid"],
        role="student",
        secret=config.jwt_secret,
        ttl_s=900,
        now=datetime.now(UTC) - timedelta(minutes=20),
    )
    resp = await client.get("/api/v1/me", headers=bearer(old))
    assert resp.status_code == 401 and err(resp) == "TOKEN_EXPIRED"


async def test_token_for_unknown_session_is_invalid(client, google_login, config):
    tokens = await google_login()
    tok = create_access_token(
        user_id=tokens["user"]["id"],
        session_id=uuid4(),
        role="student",
        secret=config.jwt_secret,
        ttl_s=900,
        now=datetime.now(UTC),
    )
    resp = await client.get("/api/v1/me", headers=bearer(tok))
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"


# --- Refresh rotation and reuse detection ---------------------------------------------


async def test_refresh_rotates_and_detects_reuse(client, google_login, con):
    tokens = await google_login()
    resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert resp.status_code == 200
    rotated = resp.json()
    assert set(rotated) == {"access_token", "refresh_token"}
    assert rotated["refresh_token"] != tokens["refresh_token"]
    assert (await client.get("/api/v1/me", headers=bearer(rotated["access_token"]))).status_code == 200

    replay = await client.post("/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert replay.status_code == 401 and err(replay) == "TOKEN_INVALID"
    # The whole session is now revoked: the thief's and the owner's tokens both stop working.
    resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": rotated["refresh_token"]})
    assert resp.status_code == 401
    resp = await client.get("/api/v1/me", headers=bearer(rotated["access_token"]))
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"
    assert await con.fetchval("select count(*) from public.audit_log where action = 'auth.refresh.reuse_detected'")


async def test_refresh_malformed_and_expired(client, google_login, con):
    for bad in ("nope", f"{uuid4()}.abc", "not-a-uuid.abc"):
        resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": bad})
        assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"
    tokens = await google_login()
    await con.execute("update public.sessions set expires_at = now() - interval '1 day'")
    resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert resp.status_code == 401 and err(resp) == "TOKEN_EXPIRED"


# --- Logout ------------------------------------------------------------------------------


async def test_logout_revokes_session_and_removes_push_token(client, google_login, con):
    tokens = await google_login()
    headers = bearer(tokens["access_token"])
    await client.put("/api/v1/me/push-token", json={"token": "fcm-1", "platform": "android"}, headers=headers)
    resp = await client.post("/api/v1/auth/logout", headers=headers)
    assert resp.status_code == 204 and resp.content == b""
    assert await con.fetchval("select count(*) from public.push_tokens") == 0
    assert (await client.get("/api/v1/me", headers=headers)).status_code == 401
    resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert resp.status_code == 401


async def test_logout_with_push_token_removes_only_that_one(client, google_login, con):
    a = await google_login()
    b = await google_login()
    await client.put(
        "/api/v1/me/push-token", json={"token": "fcm-a", "platform": "android"}, headers=bearer(a["access_token"])
    )
    await client.put(
        "/api/v1/me/push-token", json={"token": "fcm-b", "platform": "ios"}, headers=bearer(b["access_token"])
    )
    resp = await client.post("/api/v1/auth/logout", json={"push_token": "fcm-a"}, headers=bearer(a["access_token"]))
    assert resp.status_code == 204
    assert [r["token"] for r in await con.fetch("select token from public.push_tokens")] == ["fcm-b"]
