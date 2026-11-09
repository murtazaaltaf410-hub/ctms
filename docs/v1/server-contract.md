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
- Fixtures: `client, con, app, config, config_overrides` (parametrize), `create_user(role, name=, email=, phone=, active=, userid=, password=)` (drivers get `DEFAULT_DRIVER_PASSWORD` `Driver#1234` unless `password=` is given), `create_bus(driver_id)`, `google_login(sub, email, name, profile='approved')`, `driver_login(identifier, password=DEFAULT_DRIVER_PASSWORD)`, `bearer(token)`, `google`. Drivers created through `POST /admin/drivers` have a random password: use the `temporary_password` from the create response.
- **Student fixtures (ADR-10).** `create_user('student', ..., profile='approved', route_id=None, bus_id=None)` and `google_login(..., profile='approved')` also insert an APPROVED `student_profiles` row, so older tests that use students keep working. `profile='pending'|'rejected'` makes another status, `profile=None` a student with no registration (use this to test registration through the API). A default profile takes the first route that exists when it is created; the route-creating helpers (`make_route`, `insert_route`, `world`, `insert_sim_route`) call `adopt_unrouted_students(con, route_id)` so a default student lands on the test's route. That adoption is TEST-ONLY: production approval always sets a route and a bus on that route, and an approved profile with no route matches no bus. `world(label, route_name, route_id=None)` accepts `route_id` to put a second bus on the same route (a student sees one route). `add_student_profile(con, user_id, ...)` is the direct insert.
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

### Student registration, seats and gating (ADR-10, phase 4)

| Endpoint | Auth | Notes |
|---|---|---|
| `GET /me/registration` | student | `null` before the first submit, else the profile: `status` (`pending`/`approved`/`rejected`), `route_id/route_name`, `bus_id/bus_label` (the assigned bus), `admin_note`, `reviewed_at`. |
| `PUT /me/registration` `{full_name, phone, department, route_id, requested_bus_label?, claims_registered}` | student | Phone goes through `normalise_phone` (E.164). The route must be `active` and `status='active'` (400 otherwise). Creates or updates; while `pending` or `rejected` a submit sets `pending` and clears `bus_id`, `admin_note`, `reviewed_*`. An `approved` student may change name, phone and department only; a different `route_id` or `requested_bus_label` is 409 `IN_USE` (the existing 409 style; ask an admin to reassign). Audit `student.register`. |
| `GET /routes/nearest?lat&lng` | student | `{route_id, route_name, offset_m}` of the active route whose line is closest (`snap_forward`), or `null` when farther than `nearest_route_max_m` (config, 2000). Included before `/routes/{id}`. |
| `GET /trips/{id}/roster` | driver (own active trip) | `{items:[{name, department}]}` of APPROVED students whose `bus_id` is the trip's bus. Never phone, e-mail or id. `GET /trips/{id}/pickups` is unchanged. |
| `GET /admin/students` | admin | Filters `status`, `route_id`, `bus_id`, `q` (case-insensitive substring of name, e-mail, phone, department; `%` and `_` are literal); `limit`/`cursor` ordered by `(created_at, user_id)`. Items include `id` (the user id), `email`, `phone`, `claims_registered`, route and bus. |
| `GET /admin/students/summary` | admin | `{totals:{pending,approved,rejected,total}, buses:[{bus_id,label,route_id,route_ids,capacity,assigned,seats_left}] (active buses; `route_ids` = the bus's own route plus every route its driver is assigned to, and approval accepts any of them; one seat pool per bus), routes:[{route_id,route_name,pending,approved,rejected}]}`. Counts only, no attendance. |
| `GET /admin/students/{id}` | admin | One registration (404 `NOT_FOUND` if the student has none). |
| `POST /admin/students/{id}/approve` `{bus_id}`, `POST .../reassign` `{bus_id}` | admin | ONE transaction: lock the profile, then `select ... for update` the bus. The bus must exist (404), be active and have `default_route_id` equal to the student's `route_id` (else 400 `VALIDATION_ERROR` naming the route mismatch). `capacity` null or `assigned >= capacity` (approved profiles on the bus, excluding this student) is 409 `NO_SEAT` (null capacity counts as no seats). Sets `approved`, `bus_id`, `reviewed_by/at`, clears the note, audits `student.approve` / `student.reassign` (meta holds bus ids only). Re-approving a student on their own full bus works. `reassign` needs an already approved student (400 otherwise). |
| `POST /admin/students/{id}/reject` `{note}` | admin | Note required (1-500 chars). Sets `rejected`, clears `bus_id`, frees the seat, audits `student.reject`. |
| `POST/PATCH /admin/buses` | admin | Both accept `capacity` (0-500 or `null` = not set); `BusAdminOut.capacity`. |

- **New error codes** (`app/errors.py`, also in the OpenAPI table): 403 `REGISTRATION_REQUIRED`, 409 `NO_SEAT`.
- **Gate.** `app/modules/students/service.py`: `ApprovedStudent` (dependency) and `student_scope(con, user)`. A student without an approved profile gets 403 `REGISTRATION_REQUIRED` on `GET /buses/live`, `GET /stops/{id}/eta`, `PUT /me/alert-settings`, `POST /me/location`, `POST /pickups`, `GET /me/pickup`. Open to every student: `GET/PUT /me/registration`, `/routes/nearest`, `DELETE /me`, `PUT /me/consents`, `PUT /me/push-token`, `GET /me`, `GET /me/alert-settings`, `GET /me/alerts`, `GET /routes`, `GET /routes/{id}`, `GET /schedules`, `GET /announcements`, `DELETE /pickups/{id}`. The route is always read from the stored profile, never from the request.
- **Route filter.** An approved student sees in `GET /buses/live` only buses whose trip `route_id` equals the profile's `route_id`; `GET /stops/{id}/eta` for a stop of another route is 404 for them; `POST /pickups` must name the profile's route (else 400). Admins and drivers are unchanged. Alerts: `CANDIDATES_SQL` joins `student_profiles` (status `approved`) and the trip's route (`trips.route_id = profile.route_id`), so only approved students on the trip's route are candidates.
- **WebSocket.** The hub filters per student. `Hub.add(..., student=True, route_id=...)` stores a route scope for students at connect time (`live_ws` reads the approved profile's route; none = no route messages). `broadcast(app, message, route_id=...)` skips students whose scope differs; `bus_position`, `bus_status`, `trip_started`, `trip_ended` pass the trip's route; announcements pass no route and reach everyone. Admin approve / reassign / reject call `Hub.set_student_route`, so an open socket is re-scoped at once. Limitation: a profile changed by anything other than those admin endpoints (direct SQL) is picked up at the next connect only.
- Deleting the account deletes the registration (`student_profiles.user_id ... on delete cascade`), covered by the TC20 test.

### Start Journey, moved and arrived (ADR-10, phase 6)

- **Trip fields.** `TripOut` / `TripSummary` (driver endpoints) and the admin trip report gain `moved_at` and `arrived_at` (UTC `Z`, nullable); `closed_by` is `driver | auto | arrival`; `direction` was already present and is now also in `GET /admin/trips` and the CSV.
- **Push.** `POST /trips/start` pushes `{title: "Bus started its journey", body: "<bus label> (<route name>) has started its journey to campus|from campus", tag: "journey_started", data: {type, trip_id, bus_id, direction}}` to the approved students whose `student_profiles.bus_id` is the trip's bus. No recipient, no push; a push failure never fails the start.
- **moved_at.** First accepted fix with speed (fix or smoothed) above `moved_speed_mps`. `started_at` stays the button press.
- **Arrival rules.** On each accepted newer fix, if `moved_at` is set, the fix is at least `arrival_min_trip_s` after `started_at` and the bus is inside the target, the server ends the trip with `closed_by='arrival'`, `ended_at = arrived_at = fix time`, broadcasts `trip_ended` and stops tracking (later fixes are 404). Target: `to_campus` = the campus point within `campus_radius_m`; `from_campus` (the evening rule) = the travel-order last stop, i.e. the active stop with the lowest `sequence`, within `last_stop_radius_m`. **If `campus_lat`/`campus_lng` are unset the `to_campus` geofence is off**: only `POST /trips/{id}/end` ("Reached campus") or the silence auto-close ends it.
- **Button.** `POST /trips/{id}/end` is unchanged (`closed_by='driver'`, safe retry) and also sets `arrived_at` when the live position is inside the same geofence. The silence auto-close (`closed_by='auto'`) is unchanged and never sets `arrived_at`.
- **Reports.** `GET /admin/trips` items add `direction, moved_at, arrived_at`; `trips.csv` columns are now `trip_id, started_at, ended_at, bus_label, driver_name, route_name, type, direction, status, moved_at, arrived_at, closed_by, distance_m, duration_s, avg_speed_mps, avg_speed_kmh`.
- **Settings.** `GET/PUT /admin/settings` (partial PUT) with `alert_radius_m, campus_lat, campus_lng, campus_radius_m, last_stop_radius_m`; see ADR-10 implementation notes for ranges. `GET /config` also returns `campus_lat, campus_lng, campus_radius_m`.
