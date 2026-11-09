"""TC2 (reworked for ADR-10): sign-in failures never reveal whether an account exists.

The phone-OTP version of this case (an unregistered number gets the same 202 as a registered one)
is gone with /auth/phone/*; its intent now applies to POST /auth/login: an unknown identifier, a
wrong password, an inactive driver and a locked account all look the same.
"""

from __future__ import annotations

import time

from tests.conftest import DEFAULT_DRIVER_PASSWORD

LOGIN = "/api/v1/auth/login"


async def attempt(client, identifier, password=DEFAULT_DRIVER_PASSWORD):
    return await client.post(LOGIN, json={"identifier": identifier, "password": password})


def comparable(resp):
    return resp.status_code, resp.json(), {k for k in resp.headers if k.lower() not in ("date", "content-length")}


async def test_tc2_unknown_wrong_inactive_and_locked_look_alike(client, create_user, con):
    await create_user("driver", name="TC2 Driver", phone="+919811100001", userid="tc2.driver")
    await create_user("driver", name="Gone", phone="+919811100003", userid="tc2.gone", active=False)
    locked_id = await create_user("driver", name="Locked", phone="+919811100004", userid="tc2.locked")
    await con.execute("update public.users set locked_until = now() + interval '10 minutes' where id = $1", locked_id)

    responses = [
        await attempt(client, "tc2.driver", "wrong-password"),
        await attempt(client, "tc2.unknown"),
        await attempt(client, "+919811100009"),
        await attempt(client, "tc2.gone"),
        await attempt(client, "tc2.locked"),
    ]
    assert comparable(responses[0])[0] == 401
    assert responses[0].json()["error"]["code"] == "INVALID_CREDENTIALS"
    assert all(comparable(r) == comparable(responses[0]) for r in responses)


async def test_tc2_unknown_user_costs_about_the_same_as_wrong_password(client, create_user):
    """Not a strict timing test (CI is noisy): the unknown-user path must still run a full scrypt."""
    await create_user("driver", phone="+919811100005", userid="tc2.timing")
    t0 = time.perf_counter()
    await attempt(client, "tc2.nobody")
    unknown = time.perf_counter() - t0
    t0 = time.perf_counter()
    await attempt(client, "tc2.timing", "wrong-password")
    wrong = time.perf_counter() - t0
    assert unknown > 0.005 and wrong > 0.005  # both pay for scrypt
