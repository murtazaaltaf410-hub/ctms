# Server contract for P3–P6 (written by P2, commit 802a6b1)

Read this before adding server code. Look at the existing code under `server/app/` for the details.

## Routers
- Create `APIRouter(prefix=..., tags=[...])` in `app/modules/<x>/router.py`. Add `api_router.include_router(router)` under **your phase's marked comment** in `app/api/router.py`. Edit only that one line.
- `api_router` has a per-IP rate-limit dependency that takes a `Request`. So the **WebSocket** route goes on its own router or on the app (for example a `register(app)` call), **not** on `api_router`.

## DB
- In a request: `from app.db import Conn`, then `async def ep(con: Conn)`. Use asyncpg with `$n` placeholders. Wrap multi-step writes in `async with con.transaction():` (in tests this becomes a savepoint).
- Outside a request: `async with acquire(app) as con:` (from `app.db`).
- Unique violations on `trips_one_active_per_*` → 409 `TRIP_ALREADY_ACTIVE`.

## Auth / current user
- `from app.deps import AuthUser, CurrentUser, require_role`.
- Any signed-in user: `user: AuthUser`. Restricted: `user: Annotated[CurrentUser, Depends(require_role("admin"))]`.
- `CurrentUser` fields: `id, session_id, role, name, email, phone`. The user and session are re-read from the DB on every request.

## Settings / config
- Settings store: `request.app.state.settings_store` or `Depends(app.settings_store.get_settings_store)`.
  - `await store.get("alert_radius_m", con)` refreshes the cache if it is stale. `store.get_cached(key)` does no I/O.
  - The fallback is the `Settings` field with the same name.
  - After `PUT /admin/settings`, call `store.invalidate()`.
- Config: `request.app.state.config`.

## Audit / errors / rate limits
- Audit: `from app.audit import write_audit`, then `await write_audit(con, actor_id=, action=, target_type=, target_id=, meta={})`. **Meta never holds coordinates, tokens, emails or phones.**
- Errors: `from app.errors import NotFound, NotYourTrip, TripAlreadyActive, LastAdmin, InUse, PolylineFailed, RateLimited, ...`, then `raise NotFound("Bus not found")`.
- Rate limits: `dependencies=[rate_limit("locations", per="user", limit_key="rate_locations_per_user")]` from `app.ratelimit`. The limit comes from config `<limit_key>` and the window from `<limit_key>_window_s`.

## Lifecycle, events, jobs
- Hooks: `from app.live import on_startup, on_shutdown`, then decorate `async def fn(app)`. They run after the DB pool exists.
- Events: `from app.live import subscribe, publish, SESSIONS_REVOKED, USER_DELETED`. Handlers are `async def h(app, **payload)`, registered at import time.
  - `SESSIONS_REVOKED(user_id, reason, session_ids)`: published on driver replace, logout and refresh reuse. **P3 closes the WebSocket clients of those sessions.**
  - `USER_DELETED(user_id)`: **P4 drops in-memory alert state.**
- Jobs: `from app.jobs import register_job`, then `register_job("trip_auto_close", tick, interval_s=60 or lambda app: ...)`. `tick` is `async def tick(app)`; tests call it directly.
- There is no `app/clock.py` yet. P3 may add one (ADR-4). Until then use `app.schemas.utcnow`.

## Shared helpers
- `app/schemas.py`: `ApiModel`, `UtcDateTime` (serialises with `Z`), `utcnow`, `iso_utc`.
- From `app.modules.auth.service`:
  - `revoke_user_sessions(app, con, user_id, "deactivated", now=utcnow())` (U3)
  - `load_user_out(con, user_id)`
  - `is_admin_email(con, config, email)`
- Admins are rows in `admin_allowlist`. To remove one: delete the allow-list row, set `users.role='student'`, and revoke their sessions. `SEED_ADMIN_EMAIL` is always an admin and counts for `LAST_ADMIN`.
- `app/otp/firebase.py` `ensure_firebase_app(config)` is shared; P4's FCM sender reuses it.

## Tests (`server/tests/conftest.py` fixtures)
- Fixtures: `client, con, app, config, config_overrides` (parametrize), `create_user(role, name=, email=, phone=, active=)`, `create_bus(driver_id)`, `google_login(sub, email, name)`, `driver_login(phone)`, `bearer(token)`, `otp_codes`, `google`.
- Test DB: `docker compose -f docker-compose.dev.yml up -d`; `TEST_DATABASE_URL=postgresql://postgres:postgres@localhost:55432/ctms_test`. In Git Bash, `docker exec` needs `MSYS_NO_PATHCONV=1`.
- Run: `cd server && uv run ruff check . && uv run pytest -q`.

## Parallel-agent etiquette (P3/P4/P5 run concurrently)
- Touch only your owned paths. Shared files: one line each in `app/api/router.py`, and new keys in `app/config.py` (append in your own clearly commented block). Before committing a shared file, `git diff` it and stage only your hunk. If you can't, ask the orchestrator.
- The test DB is shared. Tests must use the per-test rollback fixture and never `TRUNCATE`.
