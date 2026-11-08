"""Auth: TC1, TC2, TC3, TC4 (role), U1, U3, U4, tokens, refresh rotation/reuse, logout."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import jwt
import pytest

from app.otp import FirebaseOtpProvider
from app.otp.firebase import TokenExpiredError
from app.security import create_access_token
from tests.conftest import bearer

DRIVER_PHONE = "+919000000001"


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
        "select meta from public.audit_log where action = 'user.role_change' and target_id = $1",
        tokens["user"]["id"])
    assert meta == {"from": "admin", "to": "student", "reason": "admin_allowlist"}


@pytest.mark.parametrize("config_overrides", [{"seed_admin_email": "First.Admin@UoK.edu.in"}])
async def test_seed_admin_email_is_admin(google_login):
    assert (await google_login("sub-first", "first.admin@uok.edu.in"))["user"]["role"] == "admin"


async def test_inactive_google_user_rejected(client, google, create_user):
    await create_user("student", email="gone@gmail.com", active=False)
    resp = await client.post("/api/v1/auth/google", json={"id_token": google.token("s", "gone@gmail.com")})
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"


# --- Phone OTP (TC2, U3, U4) --------------------------------------------------------

async def test_tc2_unregistered_phone_gets_identical_response(client, create_user, otp_codes):
    await create_user("driver", phone=DRIVER_PHONE)
    registered = await client.post("/api/v1/auth/phone/request", json={"phone": DRIVER_PHONE})
    unknown = await client.post("/api/v1/auth/phone/request", json={"phone": "+919111111111"})
    assert registered.status_code == unknown.status_code == 202
    assert registered.content == unknown.content == b""
    assert list(otp_codes) == [DRIVER_PHONE]  # no OTP "sent" to the unregistered number


async def test_driver_verify_returns_tokens_and_bus(client, create_user, create_bus, driver_login):
    driver_id = await create_user("driver", name="Ravi", phone=DRIVER_PHONE)
    bus_id = await create_bus(driver_id, label="Bus 7", plate="JK01AB1234")
    tokens = await driver_login(DRIVER_PHONE)
    user = tokens["user"]
    assert user["role"] == "driver" and user["phone"] == DRIVER_PHONE
    assert user["bus"] == {"id": str(bus_id), "label": "Bus 7", "plate": "JK01AB1234", "default_route_id": None}


async def test_phone_is_normalised(client, create_user, otp_codes):
    await create_user("driver", phone=DRIVER_PHONE)
    resp = await client.post("/api/v1/auth/phone/request", json={"phone": "+91 90000-00001"})
    assert resp.status_code == 202 and DRIVER_PHONE in otp_codes


async def test_wrong_code_then_attempt_limit(client, create_user, otp_codes):
    await create_user("driver", phone=DRIVER_PHONE)
    await client.post("/api/v1/auth/phone/request", json={"phone": DRIVER_PHONE})
    wrong = "000000" if otp_codes[DRIVER_PHONE] != "000000" else "111111"
    for _ in range(5):  # otp_max_attempts = 5 (seed)
        resp = await client.post("/api/v1/auth/phone/verify", json={"phone": DRIVER_PHONE, "otp": wrong})
        assert resp.status_code == 400 and err(resp) == "OTP_INVALID"
    resp = await client.post("/api/v1/auth/phone/verify",
                             json={"phone": DRIVER_PHONE, "otp": otp_codes[DRIVER_PHONE]})
    assert resp.status_code == 400 and err(resp) == "OTP_EXPIRED"


async def test_u4_code_expires_after_ttl(client, create_user, otp_codes, con):
    await create_user("driver", phone=DRIVER_PHONE)
    await client.post("/api/v1/auth/phone/request", json={"phone": DRIVER_PHONE})
    await con.execute("update public.phone_otp_requests set requested_at = requested_at - interval '6 minutes', "
                      "expires_at = expires_at - interval '6 minutes' where phone = $1", DRIVER_PHONE)
    resp = await client.post("/api/v1/auth/phone/verify",
                             json={"phone": DRIVER_PHONE, "otp": otp_codes[DRIVER_PHONE]})
    assert resp.status_code == 400 and err(resp) == "OTP_EXPIRED"


async def test_code_cannot_be_reused(client, create_user, otp_codes):
    await create_user("driver", phone=DRIVER_PHONE)
    await client.post("/api/v1/auth/phone/request", json={"phone": DRIVER_PHONE})
    body = {"phone": DRIVER_PHONE, "otp": otp_codes[DRIVER_PHONE]}
    assert (await client.post("/api/v1/auth/phone/verify", json=body)).status_code == 200
    resp = await client.post("/api/v1/auth/phone/verify", json=body)
    assert resp.status_code == 400 and err(resp) == "OTP_EXPIRED"


async def test_unregistered_phone_verify_is_otp_invalid(client):
    await client.post("/api/v1/auth/phone/request", json={"phone": "+919111111111"})
    resp = await client.post("/api/v1/auth/phone/verify", json={"phone": "+919111111111", "otp": "123456"})
    assert resp.status_code == 400 and err(resp) == "OTP_INVALID"
    resp = await client.post("/api/v1/auth/phone/verify", json={"phone": "+919222222222", "otp": "123456"})
    assert resp.status_code == 400 and err(resp) == "OTP_INVALID"


async def test_u4_resend_limit_per_phone(client, create_user, con):
    await create_user("driver", phone=DRIVER_PHONE)
    for phone in (DRIVER_PHONE, "+919111111111"):  # same limit for unknown numbers
        for _ in range(3):  # otp_max_sends_per_window = 3 (seed)
            assert (await client.post("/api/v1/auth/phone/request", json={"phone": phone})).status_code == 202
        resp = await client.post("/api/v1/auth/phone/request", json={"phone": phone})
        assert resp.status_code == 429 and err(resp) == "RATE_LIMITED"
        assert 1 <= int(resp.headers["Retry-After"]) <= 600
        assert "admin" in resp.json()["error"]["message"]
    rows = await con.fetchval("select count(*) from public.phone_otp_requests where provider = 'console'")
    assert rows == 6


@pytest.mark.parametrize("config_overrides", [{"rate_otp_request_per_ip": 2}])
async def test_otp_request_per_ip_limit(client):
    for n in range(2):
        assert (await client.post("/api/v1/auth/phone/request",
                                  json={"phone": f"+91911111111{n}"})).status_code == 202
    resp = await client.post("/api/v1/auth/phone/request", json={"phone": "+919111111119"})
    assert resp.status_code == 429 and "Retry-After" in resp.headers


async def test_u3_deactivated_driver_signed_out_and_number_reissued(client, create_user, driver_login, con):
    old_id = await create_user("driver", name="Old", phone=DRIVER_PHONE)
    old = await driver_login(DRIVER_PHONE)
    await con.execute("update public.users set active = false where id = $1", old_id)
    resp = await client.get("/api/v1/me", headers=bearer(old["access_token"]))
    assert resp.status_code == 401 and err(resp) == "TOKEN_INVALID"
    resp = await client.post("/api/v1/auth/refresh", json={"refresh_token": old["refresh_token"]})
    assert resp.status_code == 401
    new_id = await create_user("driver", name="New", phone=DRIVER_PHONE)
    new = await driver_login(DRIVER_PHONE)
    assert new["user"]["id"] == str(new_id)


# --- Sessions (TC3 / T11) -----------------------------------------------------------

async def test_tc3_second_phone_replaces_first_session(client, create_user, driver_login):
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
    old = create_access_token(user_id=claims["sub"], session_id=claims["sid"], role="student",
                              secret=config.jwt_secret, ttl_s=900,
                              now=datetime.now(UTC) - timedelta(minutes=20))
    resp = await client.get("/api/v1/me", headers=bearer(old))
    assert resp.status_code == 401 and err(resp) == "TOKEN_EXPIRED"


async def test_token_for_unknown_session_is_invalid(client, google_login, config):
    tokens = await google_login()
    tok = create_access_token(user_id=tokens["user"]["id"], session_id=uuid4(), role="student",
                              secret=config.jwt_secret, ttl_s=900, now=datetime.now(UTC))
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
    await client.put("/api/v1/me/push-token", json={"token": "fcm-a", "platform": "android"},
                     headers=bearer(a["access_token"]))
    await client.put("/api/v1/me/push-token", json={"token": "fcm-b", "platform": "ios"},
                     headers=bearer(b["access_token"]))
    resp = await client.post("/api/v1/auth/logout", json={"push_token": "fcm-a"}, headers=bearer(a["access_token"]))
    assert resp.status_code == 204
    assert [r["token"] for r in await con.fetch("select token from public.push_tokens")] == ["fcm-b"]


# --- Firebase provider (ADR-1 behind ADR-7) ------------------------------------------------

def firebase_app(app, claims_or_exc):
    async def verifier(token: str) -> dict:
        if isinstance(claims_or_exc, Exception):
            raise claims_or_exc
        return claims_or_exc

    app.state.otp_provider = FirebaseOtpProvider(verifier)


async def test_firebase_provider_paths(app, client, create_user, con):
    await create_user("driver", phone=DRIVER_PHONE)
    now = int(datetime.now(UTC).timestamp())
    body = {"phone": DRIVER_PHONE, "otp": "firebase-id-token"}

    firebase_app(app, {"phone_number": DRIVER_PHONE, "auth_time": now})
    resp = await client.post("/api/v1/auth/phone/verify", json=body)
    assert resp.status_code == 400 and err(resp) == "OTP_EXPIRED"  # no /request in the last 5 min

    assert (await client.post("/api/v1/auth/phone/request", json={"phone": DRIVER_PHONE})).status_code == 202
    row = await con.fetchrow("select provider, code_hash from public.phone_otp_requests where phone = $1",
                             DRIVER_PHONE)
    assert row["provider"] == "firebase" and row["code_hash"] is None
    resp = await client.post("/api/v1/auth/phone/verify", json=body)
    assert resp.status_code == 200 and resp.json()["user"]["role"] == "driver"

    cases = [
        ({"phone_number": "+919999999999", "auth_time": now}, "OTP_INVALID"),
        ({"phone_number": DRIVER_PHONE, "auth_time": now - 3600}, "OTP_EXPIRED"),
        (TokenExpiredError(), "OTP_EXPIRED"),
        (ValueError("bad signature"), "OTP_INVALID"),
    ]
    for claims, code in cases:
        firebase_app(app, claims)
        resp = await client.post("/api/v1/auth/phone/verify", json=body)
        assert resp.status_code == 400 and err(resp) == code, claims
