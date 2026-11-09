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
- `app/integrations/firebase.py` `ensure_firebase_app(config)` is shared; P4's FCM sender reuses it (moved from `app/otp/` in ADR-10, which removed the OTP package).

## Tests (`server/tests/conftest.py` fixtures)
- Fixtures: `client, con, app, config, config_overrides` (parametrize), `create_user(role, name=, email=, phone=, active=, userid=, password=)` (drivers get `DEFAULT_DRIVER_PASSWORD` `Driver#1234` unless `password=` is given), `create_bus(driver_id)`, `google_login(sub, email, name)`, `driver_login(identifier, password=DEFAULT_DRIVER_PASSWORD)`, `bearer(token)`, `google`. Drivers created through `POST /admin/drivers` have a random password: use the `temporary_password` from the create response.
- Test DB: `docker compose -f docker-compose.dev.yml up -d`; `TEST_DATABASE_URL=postgresql://postgres:postgres@localhost:55432/ctms_test`. In Git Bash, `docker exec` needs `MSYS_NO_PATHCONV=1`.
- Run: `cd server && uv run ruff check . && uv run pytest -q`.

## Parallel-agent etiquette (P3/P4/P5 run concurrently)
- Touch only your owned paths. Shared files: one line each in `app/api/router.py`, and new keys in `app/config.py` (append in your own clearly commented block). Before committing a shared file, `git diff` it and stage only your hunk. If you can't, ask the orchestrator.
- The test DB is shared. Tests must use the per-test rollback fixture and never `TRUNCATE`.

## Extension endpoints (ADR-10)

Driver auth moved from phone OTP to admin-managed accounts. `docs/v1/api-spec.txt` is a text extract of the
PDF and is not edited; this section is the contract for the extension. Errors keep the usual envelope.

| Endpoint | Auth | Notes |
|---|---|---|
| `POST /auth/login` `{identifier, password}` | none; per-IP `rate_login_per_ip` (429 + `Retry-After`) | `identifier` is a userid, an email (both lower-cased) or an E.164 phone (must start with `+`). Only an ACTIVE `role='driver'` matches. Response is the `TokensOut` shape plus `must_change_password` (bool). Signs out the driver's older session (`SESSION_REPLACED`, T11), audits `auth.password.login`. |
| `POST /auth/change-password` `{current_password, new_password}` (min 8 chars) | driver | 204. Wrong current password: 401 `INVALID_CREDENTIALS`. Clears `must_change_password`, revokes the driver's OTHER sessions (`password_changed`), audits `auth.password.change`. |
| `POST /admin/drivers` | admin | Body: `name`, `phone`/`email`/`userid` (at least one), `bus_id`, `active`, profile fields `employee_id, licence_no, licence_expiry, address, emergency_name, emergency_phone, notes`. 201 returns `DriverOut` + `temporary_password`, shown once. |
| `PATCH /admin/drivers/{id}` | admin | Same fields (all optional). At least one identifier must remain. Deactivation or a changed identifier revokes sessions (`deactivated` / `identifier_changed`). |
| `GET /admin/drivers` | admin | `DriverOut` adds `userid, email, must_change_password, locked` and the profile fields. Never the hash or a password. |
| `POST /admin/drivers/{id}/reset-password` | admin | 200 `{temporary_password}` (once). Sets `must_change_password=true`, clears the lockout, revokes sessions (`password_reset`), audits `driver.reset_password`. |

- **Uniform failure.** An unknown identifier, a wrong password, an inactive driver, a student/admin identifier and a locked
  account all return the same 401 `INVALID_CREDENTIALS`, after one scrypt run each (a dummy hash is checked when no
  hash exists). A locked account refuses even the right password until `locked_until` passes or an admin resets it.
- **Lockout.** `login_max_failures` (seed 5) consecutive wrong passwords set `locked_until = now + login_lock_s`
  (seed 900 s) and reset `failed_logins`; a successful login resets it. Both are `settings` keys (ADR-6).
- **Hashing.** `app/security.py`: `hashlib.scrypt`, n=2**14, r=8, p=1, 16-byte random salt, stored as
  `scrypt$n$r$p$salt_b64$hash_b64`, compared with `hmac.compare_digest`. Hashing runs in a worker thread.
  Passwords, temporary passwords and hashes are never logged (`logging_mw` redacts `password`, `*_password`, `password_hash`)
  and never put in audit `meta`.
- **Removed.** `POST /auth/phone/request`, `POST /auth/phone/verify` (now 404), `app/otp/` (console provider, OtpProvider),
  the `OTP_PROVIDER` setting and its production check, the OTP rate/threshold settings, and the retention purge of
  `phone_otp_requests`. The table stays in the database (no migration). Error codes `OTP_INVALID` and `OTP_EXPIRED`
  are gone; `INVALID_CREDENTIALS` (401) is new.
