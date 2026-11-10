"""Test harness: real Postgres (ctms_test from docker-compose.dev.yml), one connection
per test inside a transaction that is rolled back afterwards (ADR-2). App code
calling `con.transaction()` gets a SAVEPOINT.

    docker compose -f docker-compose.dev.yml up -d     # from the repo root
    cd server && uv run pytest -q

Google and Firebase are faked through `app.state` (see `FakeGoogle`, `FakeFirebase`).
Drivers made with `create_user('driver', ...)` get the password DEFAULT_DRIVER_PASSWORD, so
`driver_login(identifier)` works without further set-up.

Students (ADR-10): `create_user('student', ...)` and `google_login(...)` also create an APPROVED
`student_profiles` row, so existing tests keep working. Pass `profile='pending'|'rejected'` for another
status or `profile=None` for a student with no registration. The default profile takes the first route that
exists in the test (or none); route-creating test helpers call `adopt_unrouted_students` so a default
student ends up on the test's route. That "adoption" is TEST-ONLY: production approval always requires a
route and a bus on that route, and a profile without a route sees nothing.
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
from app.security import hash_password

DEFAULT_DRIVER_PASSWORD = "Driver#1234"
_DEFAULT_HASH: list[str] = []


def default_driver_hash() -> str:
    """scrypt is deliberately slow: hash the shared test password once per run."""
    if not _DEFAULT_HASH:
        _DEFAULT_HASH.append(hash_password(DEFAULT_DRIVER_PASSWORD))
    return _DEFAULT_HASH[0]


async def add_student_profile(
    con: asyncpg.Connection,
    user_id: UUID,
    *,
    name: str = "Test Student",
    status: str = "approved",
    route_id: UUID | None = None,
    bus_id: UUID | None = None,
    department: str | None = "Test Dept",
    phone: str | None = None,
) -> None:
    """Insert a student_profiles row. Without `route_id` an approved student gets the first existing route."""
    if route_id is None:
        route_id = await con.fetchval("select id from public.routes order by ctid limit 1")
    await con.execute(
        """insert into public.student_profiles (user_id, full_name, phone, department, route_id, status, bus_id)
           values ($1, $2, $3, $4, $5, $6, $7) on conflict (user_id) do nothing""",
        user_id, name or "Test Student", phone, department, route_id, status, bus_id if status == "approved" else None,
    )


async def adopt_unrouted_students(con: asyncpg.Connection, route_id: UUID) -> None:
    """TEST-ONLY. Put default test students that have no route yet on the route a test just created."""
    await con.execute(
        "update public.student_profiles set route_id = $1 where route_id is null and status = 'approved'", route_id)


TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL", "postgresql://postgres:postgres@localhost:55432/ctms_test")


def make_config(**overrides) -> Settings:
    values = {
        "app_env": "test",
        "database_url": TEST_DATABASE_URL,
        "google_oauth_client_ids": ["test-client-id"],
    }
    values.update(overrides)
    return Settings(_env_file=None, **values)


class FakeGoogle:
    """Google verifier fake: `token(sub, email, ...)` registers a token and returns it."""

    def __init__(self) -> None:
        self.tokens: dict[str, dict] = {}

    def token(self, sub: str, email: str, name: str = "Test User", email_verified: bool = True) -> str:
        tok = f"google-token-{sub}-{len(self.tokens)}"
        self.tokens[tok] = {
            "sub": sub,
            "email": email,
            "name": name,
            "email_verified": email_verified,
            "iss": "https://accounts.google.com",
        }
        return tok

    async def __call__(self, token: str) -> dict:
        if token not in self.tokens:
            raise TokenInvalid("Google ID token rejected")
        return self.tokens[token]


class FakeFirebase:
    """Firebase Admin verifier fake for verified email/password ID tokens."""

    def __init__(self) -> None:
        self.tokens: dict[str, dict] = {}

    def token(self, uid: str, email: str, name: str = "Test User", email_verified: bool = True) -> str:
        tok = f"firebase-token-{uid}-{len(self.tokens)}"
        self.tokens[tok] = {"uid": uid, "email": email, "name": name, "email_verified": email_verified}
        return tok

    async def __call__(self, token: str) -> dict:
        if token not in self.tokens:
            raise TokenInvalid("Firebase ID token rejected")
        return self.tokens[token]


@pytest.fixture
async def con() -> AsyncIterator[asyncpg.Connection]:
    try:
        connection = await asyncpg.connect(TEST_DATABASE_URL)
    except (OSError, asyncpg.PostgresError) as exc:
        pytest.fail(
            f"test database unreachable at {TEST_DATABASE_URL} ({exc}); run "
            "`docker compose -f docker-compose.dev.yml up -d` from the repo root"
        )
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
def google() -> FakeGoogle:
    return FakeGoogle()


@pytest.fixture
def firebase() -> FakeFirebase:
    return FakeFirebase()


@pytest.fixture
def app(config: Settings, con: asyncpg.Connection, google: FakeGoogle, firebase: FakeFirebase):
    application = create_app(config)

    async def test_conn() -> AsyncIterator[asyncpg.Connection]:
        yield con

    application.dependency_overrides[get_conn] = test_conn
    application.state.google_verifier = google
    application.state.firebase_token_verifier = firebase
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
    async def make(
        role: str = "student",
        *,
        name: str = "User",
        email: str | None = None,
        phone: str | None = None,
        active: bool = True,
        userid: str | None = None,
        password: str | None = None,
        profile: str | None = "approved",
        route_id: UUID | None = None,
        bus_id: UUID | None = None,
    ) -> UUID:
        """Drivers get `password` (default DEFAULT_DRIVER_PASSWORD); other roles have no password.
        Students get a student_profiles row with status `profile` (None = no registration)."""
        password_hash = None
        if role == "driver":
            password_hash = hash_password(password) if password else default_driver_hash()
        user_id = await con.fetchval(
            """insert into public.users (role, name, email, phone, active, userid, password_hash)
               values ($1, $2, $3, $4, $5, $6, $7) returning id""",
            role,
            name,
            email,
            phone,
            active,
            userid,
            password_hash,
        )
        if role == "student" and profile:
            await add_student_profile(con, user_id, name=name, status=profile, route_id=route_id, bus_id=bus_id)
        return user_id

    return make


@pytest.fixture
def delete_account(app, con: asyncpg.Connection) -> Callable:
    """Students cannot call DELETE /me (V1.3): tests delete an account the way an approved deregistration does."""
    from app.modules.me.accounts import delete_user_account

    async def go(user_id: UUID | str) -> None:
        await delete_user_account(app, con, UUID(str(user_id)), actor_id=None)

    return go


@pytest.fixture
def create_bus(con: asyncpg.Connection) -> Callable:
    async def make(driver_id: UUID | None = None, *, label: str = "Bus T", plate: str = "JK01TEST01") -> UUID:
        return await con.fetchval(
            "insert into public.buses (label, plate, driver_id) values ($1, $2, $3) returning id",
            label,
            plate,
            driver_id,
        )

    return make


@pytest.fixture
def google_login(client: httpx.AsyncClient, google: FakeGoogle, con: asyncpg.Connection) -> Callable:
    async def login(sub: str = "sub-1", email: str = "student@uok.edu.in", name: str = "Student",
                    profile: str | None = "approved") -> dict:
        """Students signing in get an approved registration unless `profile` says otherwise (None = none)."""
        resp = await client.post("/api/v1/auth/google", json={"id_token": google.token(sub, email, name)})
        assert resp.status_code == 200, resp.text
        body = resp.json()
        if body["user"]["role"] == "student" and profile:
            await add_student_profile(con, UUID(body["user"]["id"]), name=name, status=profile)
        return body

    return login


@pytest.fixture
def firebase_login(client: httpx.AsyncClient, firebase: FakeFirebase) -> Callable:
    async def login(uid: str = "firebase-1", email: str = "student@uok.edu.in", name: str = "Student") -> dict:
        resp = await client.post("/api/v1/auth/firebase", json={"id_token": firebase.token(uid, email, name)})
        assert resp.status_code == 200, resp.text
        return resp.json()

    return login


@pytest.fixture
def driver_login(client: httpx.AsyncClient) -> Callable:
    async def login(identifier: str, password: str = DEFAULT_DRIVER_PASSWORD) -> dict:
        resp = await client.post("/api/v1/auth/login", json={"identifier": identifier, "password": password})
        assert resp.status_code == 200, resp.text
        return resp.json()

    return login
