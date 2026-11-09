# CTMS V1 — Architecture decisions (Phase 0)

Short ADRs. Each one names the docs it was decided against. Later phases follow these. To change one, add a new ADR that supersedes it.

---

## ADR-1 — Driver phone OTP: Firebase Phone Auth on device; server verifies the Firebase ID token behind the spec endpoints

> **Superseded by ADR-10** (2026-11-09): drivers now sign in with an admin-issued password, not a phone OTP.

> **Superseded by ADR-10** (2026-11-09): drivers now sign in with an admin-issued password, not a phone OTP.

**Status:** accepted (2026-11-08)

**Context.**
- API spec p.2 has `POST /auth/phone/request {phone}` → 202 (sent only if the number is a registered driver; same response otherwise) and `POST /auth/phone/verify {phone, otp}` → tokens + user, or 400 `OTP_INVALID` / `OTP_EXPIRED`.
- Edge case U4: OTP expires after 5 min; resends limited (start: 3 per 10 min); tell the driver to contact an admin.
- TRD p.4: the server accepts only numbers an admin registered and linked to a bus.
- TRD p.5 free-tier table lists **"Firebase (FCM, phone auth) — Free SMS quota for OTP"**, and PRD risks say "Phone OTP SMS has limited free quota… only 1–3 drivers".
- The runbook env-var list has **no SMS-provider secret**, only `FCM_CREDENTIALS`.
- So the docs assume Firebase delivers the SMS. No SMS provider exists in the design, and Indian commercial SMS needs TRAI DLT registration.

**Options.**
- (a) Server generates and hashes the OTP and sends it through an `SmsSender` interface (Twilio/MSG91).
  - Matches the spec 1:1, including "no OTP sent" for unregistered numbers.
  - Needs a paid SMS provider + DLT templates + a secret not in the runbook.
- (b) Firebase Phone Auth on device; the server verifies the resulting Firebase ID token.
  - No SMS provider; uses only the Firebase project the user is already creating.

**Decision: (b)**, keeping the spec endpoints, codes and limits:

| Spec step | Client (Flutter) | Server |
|---|---|---|
| `POST /auth/phone/request {phone}` | Normalise to E.164 and call this **first**. Ignore the body; any 202 continues | Validate format. Rate-limit **per phone 3 / 10 min** and per IP; on excess return 429 `RATE_LIMITED` + `Retry-After` (U4). Insert `phone_otp_requests(phone_e164, ip, created_at)` for every request, registered or not. **Always 202, empty body**, so no enumeration (TC2) |
| Send SMS | `FirebaseAuth.instance.verifyPhoneNumber(phoneNumber, codeSent: …, forceResendingToken: …)` | — |
| User types code | `PhoneAuthProvider.credential(verificationId, smsCode)` → `signInWithCredential` → `user.getIdToken()`. Firebase errors `invalid-verification-code` → show OTP_INVALID; `session-expired` → OTP_EXPIRED | — |
| `POST /auth/phone/verify {phone, otp}` | Send `otp` = **the Firebase ID token** (the field name is kept for spec fidelity; document it in OpenAPI `description`) | `firebase_admin.auth.verify_id_token(otp)` via `to_thread`, then the checks below |

Server checks in `/auth/phone/verify`:
1. Token invalid, or its project/audience wrong → 400 `OTP_INVALID`.
2. `auth.ExpiredIdTokenError`, **or** `auth_time` older than `otp_ttl_s` (300 s), **or** no `phone_otp_requests` row for this phone in the last 300 s → 400 `OTP_EXPIRED`. This enforces the 5-minute window server-side.
3. `claims["phone_number"] != normalised phone` → 400 `OTP_INVALID`.
4. The phone is not an **active driver** (`users.role='driver' and active`) → 400 `OTP_INVALID`. Same code as a wrong code, so there is no enumeration.
5. On success: revoke all other sessions of this driver with `revoked_reason='replaced'`, so the old device gets `SESSION_REPLACED` (T11/TC3). Issue tokens. Audit `auth.phone.verify`.
6. Sign out of Firebase on the device after the exchange (`FirebaseAuth.instance.signOut()`). Our JWT is the only session.

**Consequences / accepted deviations.**
- TC2 "no OTP sent" holds at the **API level**: the server never sends anything and the 202 is uniform.
- The app still calls Firebase for any number entered, so Firebase may text an unregistered number. Mitigations:
  - Firebase's own abuse controls (Play Integrity / reCAPTCHA, SMS region policy restricted to India in the console).
  - Our per-phone/IP limit on `/request`.
- The app's flow requires `/request` before Firebase, but a modified client could skip it. Firebase's quotas still apply.
- The OTP resend limit (3/10 min) is enforced on `/auth/phone/request`. Firebase also throttles independently.
- Phase 1 schema: table `phone_otp_requests(id, phone_e164, ip inet, created_at)` with an index on `(phone_e164, created_at)`. No `code_hash` column. Purge rows > 1 day in the retention job.
- **Verify before launch (user):**
  - Whether the Firebase plan in use allows Phone Auth SMS for free. Recent Firebase policy may require the Blaze (billing-enabled) plan for SMS. Check the console's pricing page.
  - Configure **test phone numbers** in Firebase for dev/CI.
- **Fallback:** if Firebase SMS is unavailable for the pilot, switch to (a) by implementing `SmsSender` behind the same two endpoints. The client then sends the 6-digit code instead of the ID token. The DB adds `code_hash`, `attempts`. No other API change is needed.

---

## ADR-2 — DB access: plain **asyncpg** (no ORM); Alembic only as a runner for the SQL files

**Context.** Phase 1 delivers hand-written SQL files (`supabase/migrations/*.sql`) as the schema source of truth that the user runs in Supabase. The API is query-shaped:
- batched inserts with `ON CONFLICT (fix_id) DO NOTHING`
- partial unique indexes
- cursor pagination
- report aggregates

Tests need per-test rollback, and production must work through Supabase's pooler.

**Decision.** Use `asyncpg` directly.
- One `asyncpg.Pool` is created in lifespan (`max_size` 5).
- A `get_conn` dependency yields a pooled connection.
- Repositories are plain async functions with `$n` SQL.
- `init=` registers a jsonb codec.

**Why not SQLAlchemy 2 async + asyncpg:**
- It would duplicate the schema as ORM models that drift from the SQL files.
- Its asyncpg dialect prepares every statement, which hits the same pooler caveat anyway.
- For about 30 tables of straightforward SQL it adds weight without benefit.

**Tests:**
- A per-test connection is put in an outer transaction and injected by overriding `get_conn`.
- App-level `con.transaction()` becomes a SAVEPOINT (asyncpg docs, nested transactions).
- Teardown rolls back.
- Background writer and jobs take the connection provider as an injected callable, so tests drive them directly.

**Supabase:**
- Use the **Shared pooler, session mode, port 5432**, which is IPv4 and supports prepared statements.
- A direct connection is IPv6-only on free.
- Do **not** use the transaction pooler (6543). If it is ever forced, set `statement_cache_size=0`.

**Alembic:**
- Needed only because the runbook requires "migrations first (Alembic)".
- Uses a sync `postgresql+psycopg` URL.
- Each revision runs `op.get_bind().exec_driver_sql(<file text>)`. Avoid `op.execute(str)`, because `text()` treats `:x` as a bind param.
- Phase 1 must verify that psycopg3 accepts the multi-statement files. If not, split them by statement in the revision.

---

## ADR-3 — Rate limiting: small custom in-memory limiter (not slowapi)

**Context.**
- TRD p.4: limits per user and per IP, tighter for OTP requests and location uploads.
- API spec p.1: 429 + `Retry-After` in the spec error envelope (`RATE_LIMITED`).
- Single server instance (TRD), so in-memory state is acceptable.

**Decision.**
- `app/ratelimit.py`: a sliding-window counter keyed by `(bucket, key)` with an `asyncio.Lock`.
- It is exposed as a dependency factory: `Depends(rate_limit("otp_request", per="phone|ip|user", limit_setting="..."))`.
- It raises `RateLimited(retry_after=s)`, which the global AppError handler renders as `{"error":{"code":"RATE_LIMITED",...}}` with the `Retry-After` header.
- The client IP comes from the **left-most `X-Forwarded-For`** when `TRUST_PROXY=true` (Render), else `request.client.host`.
- Limits are settings, never literals. Defaults:
  - `/auth/phone/request` 3 per phone / 10 min and 20 per IP / 10 min
  - `/trips/{id}/locations` 60 per user / min
  - general 120 per user / min, 300 per IP / min

**Why not slowapi** (ctx7 `/laurents/slowapi`):
- Its default 429 body is not the spec envelope.
- Its decorator requires a `request` param on every endpoint.
- `get_remote_address` ignores `X-Forwarded-For`.
- Per-user keys need the authenticated user, which a decorator evaluated before dependencies does not have cleanly.
- About 60 lines of our own code is simpler to test, including `Retry-After`.

---

## ADR-4 — Background jobs: plain asyncio tasks started in lifespan (no APScheduler)

**Jobs:**
- DB batch writer (every 10 s, bounded queue — N5)
- live-state sweeper (live → stale 30 s → offline 120 s; emits WS state)
- trip auto-close (15 min silence → `closed_by='auto'`, T2)
- retention (daily: locations > 90 days, `student_locations` > 5 min, expired sessions, `phone_otp_requests` > 1 day)
- optional keep-alive is external (runbook: uptime pinger hits `/health`)

**Decision.**
- Each job is `async def run_forever(stop: asyncio.Event, interval_s, tick)`, started with `asyncio.create_task` in lifespan and cancelled on shutdown.
- `tick()` is a plain coroutine that tests call directly with a fake clock (`app/clock.py` `now()` injectable), so TC8 and T2 are time-mocked without sleeping.

**Why not APScheduler:**
- Single process, fixed intervals, no cron expressions, no persistence needed.
- APScheduler 3 vs 4 API churn is a risk with no benefit.
- Stdlib asyncio is confirmed (ctx7 `/python/cpython`).

---

## ADR-5 — Driver background location: `flutter_foreground_task` + `geolocator`

**Context.**
- PRD D2 and the risk table: a foreground service with an ongoing notification, so battery savers don't kill tracking.
- T7: battery optimisation onboarding.
- Cadence 3–5 s moving / 15 s stopped (TRD p.2).
- Fixes are buffered in sqflite (D5/T6).

**Decision.**
- `flutter_foreground_task` hosts the service: notification, `ForegroundTaskEventAction.repeat(ms)` tick, `updateService` to switch cadence, `requestIgnoreBatteryOptimization`, two-way data with the UI isolate.
- Inside the `TaskHandler`, `geolocator.getPositionStream(AndroidSettings(...))` produces fixes, which go to sqflite with a client `fix_id` (uuid v4).
- The repeat tick uploads ≤20 unsent fixes in `recorded_at` order and deletes them after any 200.

**Why not `flutter_background_service`:**
- `flutter_foreground_task` documents the notification/permission/battery helpers we need (ctx7 `/dev-hwang/flutter_foreground_task`, 426 snippets, benchmark 84).
- `flutter_background_service` adds a long-running isolate without those helpers.

**Fallback:** if plugin calls inside the task isolate fail on a target device, use geolocator's own `ForegroundNotificationConfig` (it starts its own Android foreground service) with the upload timer in the UI isolate.

**Open:** confirm the `startService(serviceTypes: [location])` signature and the Android 14 `FOREGROUND_SERVICE_LOCATION` manifest entries in P8 (marked UNCONFIRMED in allowed-apis.md).

---

## ADR-6 — Thresholds the docs imply but the plan's list omitted (add to settings)

These come from the edge-case catalogue and must also be config, not literals:

| Setting | Default | Source |
|---|---|---|
| `alert_rider_suppress_m` | 50 m (consecutive updates) | Edge A1 |
| `alert_combine_window_s` | 60 s | Edge A4 |
| `clock_skew_flag_s` | 30 s (docs give no number; flag only) | Edge T13 |
| `stopped_speed_mps` | 0.5 m/s ("speed near zero") | Edge T14 |
| `history_downsample_s` | 0 (off). TRD p.6 suggests 10 s to bound DB growth | TRD p.6 |
| `eta_display_cap_s` | 1800 → "30+ min" | Edge A9 |
| `otp_request_per_phone` / window | 3 / 600 s | Edge U4 |
| `otp_ttl_s` | 300 | Edge U4 |

## ADR-7 — User override of ADR-1: pluggable OTP provider, dev mode first (2026-11-08)

> **Superseded by ADR-10** (2026-11-09): the OTP providers and `/auth/phone/*` are being removed.

> **Superseded by ADR-10** (2026-11-09): the OTP providers and `/auth/phone/*` are being removed.

The user chose **"dev mode for now, decide later"**. Keep the spec endpoints `POST /auth/phone/request` (always 202, 3 sends per phone per 10 min plus a per-IP limit) and `POST /auth/phone/verify` (`OTP_INVALID` / `OTP_EXPIRED`). Put an `OtpProvider` interface behind them:
- `ConsoleOtpProvider` is the default when `APP_ENV=dev` or `OTP_PROVIDER=console`. The server generates a 6-digit code, stores only its hash with a 5-minute expiry and an attempt counter, and logs the code to the server console. Never return it in the response.
- `FirebaseOtpProvider` follows ADR-1 (the device runs Firebase Phone Auth and `otp` carries the Firebase ID token). It is implemented but selected only with `OTP_PROVIDER=firebase`.
- An SMS-provider implementation (e.g. Twilio/MSG91) can be added later behind the same interface.

The provider must be picked before launch. Production config fails fast if `OTP_PROVIDER=console`.
**DB impact:** the OTP request table needs nullable `code_hash`, `expires_at` and `attempts` columns so the console and SMS providers work.
**App impact (P7):** the driver login screen asks for the phone, calls `/request`, then asks for the 6-digit code. Only in Firebase mode does the app run `verifyPhoneNumber` and send the ID token.

## ADR-8 — Route polylines: Google **Routes API** (`computeRoutes`), not the legacy Directions API (2026-11-08)

The user chose the Routes API because new Cloud projects may not be able to enable the legacy Directions API.
- **P5:** call `POST https://routes.googleapis.com/directions/v2:computeRoutes` with headers `X-Goog-Api-Key` and `X-Goog-FieldMask: routes.polyline.encodedPolyline,routes.distanceMeters`. Use the stops as origin, intermediates and destination, with `travelMode: DRIVE`. Check the exact request shape with context7 or the official docs before coding.
- Call it once whenever a route's stops change. If it fails, the route becomes a draft with `POLYLINE_FAILED`.
- The env var keeps the runbook name `GOOGLE_DIRECTIONS_KEY`; the key must have the Routes API enabled and be restricted to the server.

## ADR-9 — Trip direction, student pickup pins and driver alerts (V1.1 extension, 2026-11-09)

Added after the Render pilot started. These go beyond the V1 PRD; no PRD non-goal forbids them.
- **Direction.** A trip has `direction` = `to_campus` (home → campus) or `from_campus` (campus → home); schedule slots have one too, and a trip only matches slots of its own direction. A route stays **one** polyline and one stop list. The stored order is the `to_campus` order. A `from_campus` trip reads the same route in reverse: `RouteGeom.reversed()` flips the points and recomputes cumulative distances, and stops are snapped in reverse sequence order (`trips/service.py`). Everything downstream (live position, ETA, alerts) works on that frozen reversed geometry unchanged.
- **Assumption:** the return leg follows the same road as the outbound leg. If a real one-way system breaks that, model that leg as its own route.
- **DB:** migration `0005_trip_direction.sql` adds `trips.direction` and `schedules.direction` (default `to_campus`, additive, so rollback is safe).
- **Student pickup pins and driver alerts** (migration 0006): students place a temporary pickup pin per leg (`POST /pickups`, one waiting pin per student, within `pickup_max_route_distance_m` of the route line, expiring after `pickup_request_ttl_s`). It is not an admin stop and never changes a route. The driver reads `GET /trips/{id}/pickups` (location, label and distance only, no student identity).
- **Alerts from pins** reuse the alert engine's per-fix hook: when the bus is within `driver_alert_radius_m` of a waiting pin on its route and leg and getting closer, the driver gets a `pickup_nearby` push and the student a nearby-bus push (skipped if their GPS alert already fired for the trip), once per (pin, trip) via `pickup_alert_log`. A pin is marked `picked_up` when the bus passes within `pickup_pass_m`. Pins are not expired when a trip ends (another bus may still come); they expire by TTL.
- All new thresholds are config fields (env-overridable, ADR-6): `pickup_request_ttl_s`, `pickup_max_route_distance_m`, `pickup_pass_m`, `driver_alert_radius_m`, `pickup_retention_s`.


## ADR-10 — Admin-managed driver accounts, student registration with seats, Start Journey and arrival (V1.2 extension, 2026-11-09)

**Status:** accepted by the user (2026-11-09). **Supersedes ADR-1 and ADR-7.** Overrides PRD D1/A1 (driver phone OTP, drivers identified by phone), the PRD non-goal "seat booking or attendance" (prd.txt:28-33), the PRD student role "any university student" (prd.txt:45-47), U1/TC1 (any Google account may sign in) and "students see every active bus" (prd.txt:20-21).

- **Driver accounts.** Only an admin creates a driver. The admin records name, a unique lowercase `userid`, optional email and phone, and profile details (employee id, licence number and expiry, address, emergency contact, notes in `driver_profiles`). The server generates a temporary password and returns it once; `must_change_password` forces a change at first login. A driver signs in with `POST /auth/login {identifier, password}`; the identifier is a userid, email or phone.
- **Password storage.** Postgres `users.password_hash`, hashed with the Python standard library `hashlib.scrypt` (random per-user salt) and compared with `hmac.compare_digest`. No new dependency. No OTP, no SMS, no Firebase for drivers. The hash is never returned or logged. Failure is always the same `INVALID_CREDENTIALS` 401 for an unknown identifier and a wrong password. Per-IP rate limit (`rate_login_per_ip`) and an account lock after `login_max_failures` failures for `login_lock_s` seconds (`users.failed_logins`, `users.locked_until`). One active session per driver stays (`SESSION_REPLACED`). `otp/firebase.py` stays because `/auth/firebase` and FCM use it.
- **Student registration.** A student must register before using the app: full name, phone, department, route, requested bus label and whether they are registered with campus transport. The registration is `pending` until an admin approves it and assigns a bus (`approved`) or rejects it with a note. Approval runs in one transaction that locks the bus row, requires the bus to run the student's route and requires a free seat, else 409 `NO_SEAT`. Until approved, live buses, ETAs, pickups and alerts are refused (403 `REGISTRATION_REQUIRED`); an approved student sees only buses on their route.
- **Seats.** `buses.capacity` (null = not set). The admin sees counts per status, route and bus (capacity, assigned, seats left) and the roster. **No attendance tracking is built or stored**: the numbers are registrations and assignments, not who boarded. A driver sees a roster of the approved students on their bus with name and department only, never a phone number.
- **Start Journey push.** The driver's Start Trip becomes **Start Journey**. On trip start the server pushes "Bus started its journey" (tag `journey_started`) to the approved students assigned to that bus.
- **Arrival.** A trip records `moved_at` (first speed above `moved_speed_mps`), `arrived_at` and `closed_by = 'arrival'`. Both directions end **automatically by geofence and by the driver button**. A `to_campus` trip ends inside `campus_radius_m` of the campus point (`campus_lat`, `campus_lng`). A `from_campus` trip ends inside `last_stop_radius_m` of the route's last stop. Neither closes before `arrival_min_trip_s` has passed and the bus has moved. If the campus point is unset, the campus geofence is off and only the button ends a `to_campus` trip. The 15-minute silence auto-close is unchanged.
- **DB:** migrations `0007_driver_accounts.sql`, `0008_students.sql`, `0009_journey.sql`. The `users_login_identifier` check becomes "a driver has at least one of phone, email or userid; everyone else has an email". `trips_closed_by_check` gains `arrival`.
- **Config (ADR-6):** `campus_lat`, `campus_lng` (None = not set), `campus_radius_m` 150, `last_stop_radius_m` 150, `moved_speed_mps` 1.5, `arrival_min_trip_s` 120, `login_max_failures` 5, `login_lock_s` 900, `rate_login_per_ip` 20 per `rate_login_per_ip_window_s` 600.
- **Existing data.** Drivers keep their phone; an admin sets each one's userid and password. Existing student accounts, including the owner's, register once after this ships. `phone_otp_requests` is not dropped yet.


