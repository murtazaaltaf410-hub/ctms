"""Test harness: real Postgres (ctms_test from docker-compose.dev.yml), one connection
per test inside a transaction that is rolled back afterwards (ADR-2). App code
calling `con.transaction()` gets a SAVEPOINT.

    docker compose -f docker-compose.dev.yml up -d     # from the repo root
    cd server && uv run pytest -q

Google and OTP are faked through `app.state` (see `FakeGoogle`, `otp_codes`).
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator, Callable
from uuid import UUID

import asyncpg
import httpx
import pytest

from app.config import Settings
from app.db import get_conn, init_conn
from app.errors import TokenInvalid
from app.main import create_app
from app.otp import ConsoleOtpProvider

TEST_DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL", "postgresql://postgres:postgres@localhost:55432/ctms_test"
)


def make_config(**overrides) -> Settings:
    values = {"app_env": "test", "database_url": TEST_DATABASE_URL,
              "google_oauth_client_ids": ["test-client-id"], "otp_provider": "console"}
    values.update(overrides)
    return Settings(_env_file=None, **values)


class FakeGoogle:
    """Google verifier fake: `token(sub, email, ...)` registers a token and returns it."""

    def __init__(self) -> None:
        self.tokens: dict[str, dict] = {}

    def token(self, sub: str, email: str, name: str = "Test User", email_verified: bool = True) -> str:
        tok = f"google-token-{sub}-{len(self.tokens)}"
        self.tokens[tok] = {"sub": sub, "email": email, "name": name, "email_verified": email_verified,
                            "iss": "https://accounts.google.com"}
        return tok

    async def __call__(self, token: str) -> dict:
        if token not in self.tokens:
            raise TokenInvalid("Google ID token rejected")
        return self.tokens[token]


@pytest.fixture
async def con() -> AsyncIterator[asyncpg.Connection]:
    try:
        connection = await asyncpg.connect(TEST_DATABASE_URL)
    except (OSError, asyncpg.PostgresError) as exc:
        pytest.fail(f"test database unreachable at {TEST_DATABASE_URL} ({exc}); run "
                    "`docker compose -f docker-compose.dev.yml up -d` from the repo root")
    await init_conn(connection)
    tr = connection.transaction()
    await tr.start()
    try:
        yield connection
    finally:
        await tr.rollback()
        await connection.close()


@pytest.fixture
def config_overrides() -> dict:
    """Override per test module/test to change config (e.g. rate limits)."""
    return {}


@pytest.fixture
def config(config_overrides: dict) -> Settings:
    return make_config(**config_overrides)


@pytest.fixture
def otp_codes() -> dict[str, str]:
    """phone -> last code the console provider 'sent' (only for active drivers)."""
    return {}


@pytest.fixture
def google() -> FakeGoogle:
    return FakeGoogle()


@pytest.fixture
def app(config: Settings, con: asyncpg.Connection, otp_codes: dict[str, str], google: FakeGoogle):
    application = create_app(config)

    async def test_conn() -> AsyncIterator[asyncpg.Connection]:
        yield con

    application.dependency_overrides[get_conn] = test_conn
    application.state.google_verifier = google
    application.state.otp_provider = ConsoleOtpProvider(config.jwt_secret, sink=otp_codes.__setitem__)
    yield application
    application.dependency_overrides.clear()


@pytest.fixture
async def client(app) -> AsyncIterator[httpx.AsyncClient]:
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def create_user(con: asyncpg.Connection) -> Callable:
    async def make(role: str = "student", *, name: str = "User", email: str | None = None,
                   phone: str | None = None, active: bool = True) -> UUID:
        return await con.fetchval(
            "insert into public.users (role, name, email, phone, active) values ($1, $2, $3, $4, $5) "
            "returning id",
            role, name, email, phone, active,
        )

    return make


@pytest.fixture
def create_bus(con: asyncpg.Connection) -> Callable:
    async def make(driver_id: UUID | None = None, *, label: str = "Bus T", plate: str = "JK01TEST01") -> UUID:
        return await con.fetchval(
            "insert into public.buses (label, plate, driver_id) values ($1, $2, $3) returning id",
            label, plate, driver_id,
        )

    return make


@pytest.fixture
def google_login(client: httpx.AsyncClient, google: FakeGoogle) -> Callable:
    async def login(sub: str = "sub-1", email: str = "student@uok.edu.in", name: str = "Student") -> dict:
        resp = await client.post("/api/v1/auth/google", json={"id_token": google.token(sub, email, name)})
        assert resp.status_code == 200, resp.text
        return resp.json()

    return login


@pytest.fixture
def driver_login(client: httpx.AsyncClient, otp_codes: dict[str, str]) -> Callable:
    async def login(phone: str) -> dict:
        resp = await client.post("/api/v1/auth/phone/request", json={"phone": phone})
        assert resp.status_code == 202, resp.text
        resp = await client.post("/api/v1/auth/phone/verify", json={"phone": phone, "otp": otp_codes[phone]})
        assert resp.status_code == 200, resp.text
        return resp.json()

    return login
