"""TC2: an unregistered phone number requesting an OTP gets the same response as a
registered driver's number, and no code is sent to it."""

from __future__ import annotations


async def test_tc2_unregistered_phone_same_response_no_otp_sent(client, create_user, otp_codes):
    registered, unknown = "+919811100001", "+919811100002"
    await create_user("driver", name="TC2 Driver", phone=registered)
    a = await client.post("/api/v1/auth/phone/request", json={"phone": registered})
    b = await client.post("/api/v1/auth/phone/request", json={"phone": unknown})
    assert a.status_code == b.status_code == 202
    assert a.content == b.content
    assert {k for k in a.headers if k.lower() not in ("date", "content-length")} == {
        k for k in b.headers if k.lower() not in ("date", "content-length")
    }
    assert registered in otp_codes and unknown not in otp_codes

    # Verifying fails the same way for both: a wrong code and an unknown number look alike.
    wrong = await client.post("/api/v1/auth/phone/verify", json={"phone": registered, "otp": "000000"})
    nobody = await client.post("/api/v1/auth/phone/verify", json={"phone": unknown, "otp": "000000"})
    if otp_codes[registered] == "000000":  # pragma: no cover - 1 in a million
        return
    assert wrong.status_code == nobody.status_code == 400
    assert wrong.json() == nobody.json()
    assert wrong.json()["error"]["code"] == "OTP_INVALID"


async def test_tc2_student_or_inactive_driver_phone_gets_no_code(client, create_user, otp_codes):
    await create_user("driver", name="Gone", phone="+919811100003", active=False)
    resp = await client.post("/api/v1/auth/phone/request", json={"phone": "+919811100003"})
    assert resp.status_code == 202 and "+919811100003" not in otp_codes
