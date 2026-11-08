"""TC1 (U1): a student signs in with a university Google account and with a non-university
one; both succeed and both get the student role."""

from __future__ import annotations

from tests.conftest import bearer


async def test_tc1_university_and_personal_google_accounts_are_students(client, google, con):
    for sub, email in (("tc1-uni", "tc1.student@uok.edu.in"), ("tc1-gmail", "tc1.someone@gmail.com")):
        resp = await client.post("/api/v1/auth/google", json={"id_token": google.token(sub, email, "TC1")})
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert set(body) >= {"access_token", "refresh_token", "user"}
        assert body["user"]["role"] == "student" and body["user"]["email"] == email
        me = await client.get("/api/v1/me", headers=bearer(body["access_token"]))
        assert me.status_code == 200 and me.json()["role"] == "student"
        # Signing in again reuses the account (created on first sign-in only).
        again = await client.post("/api/v1/auth/google", json={"id_token": google.token(sub, email, "TC1")})
        assert again.json()["user"]["id"] == body["user"]["id"]
    assert await con.fetchval("select count(*) from public.users where email like 'tc1.%'") == 2


async def test_tc1_rejected_google_token_is_401(client):
    resp = await client.post("/api/v1/auth/google", json={"id_token": "not-a-google-token"})
    assert resp.status_code == 401 and resp.json()["error"]["code"] == "TOKEN_INVALID"
