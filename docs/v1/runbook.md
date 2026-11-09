# CTMS V1: operations runbook (server)

This is the working runbook for the pilot. It maps the spec runbook (`runbook.txt`) to what the code actually does. For deploys, rollback and environment variables, see [deploy.md](deploy.md). For accounts and keys, see [credentials-checklist.md](credentials-checklist.md).

## Daily checks during the pilot

The runbook asks you to watch six numbers daily. This is where each one comes from today:

| Metric (runbook) | Where to look | Healthy |
|---|---|---|
| **Active buses** | `GET /api/v1/buses/live` (any signed-in user): the number of items. Admin app live monitor (P8). SQL: `select count(*) from trips where ended_at is null;` | Matches the buses that should be running |
| **Age of each bus's last fix** | `GET /api/v1/buses/live`: `last_fix_at`, `state` (`live` / `stopped` / `stale` > 30 s / `offline` > 120 s) and `clock_skew_s` | `live`/`stopped`. Pilot target: 80 % of trip time with a fix under 10 s old |
| **Rejected fixes per hour** | SQL (Supabase SQL editor): `select date_trunc('hour', received_at) h, reason, count(*) from rejected_fixes where received_at > now() - interval '1 day' group by 1,2 order by 1 desc;` | Mostly `ACCURACY_TOO_LOW`, low single digits per bus-hour |
| **Push failures** | Render logs, logger `ctms.push`: `"push … failed for N token(s) after one retry"`, `"deleted N invalid push token(s)"`, `"fcm send_each failed"` | Rare; invalid tokens are cleaned up automatically (N9) |
| **Sign-in failures** | Render logs, logger `ctms.request`: `path` starting `/api/v1/auth/` with `status` 401/429. Successful sign-ins are in `audit_log` (`auth.google.sign_in`, `auth.phone.verify`) | Few 401s; a spike of 401 on `/auth/google` = client ID mismatch |
| **Google Maps usage vs quota** | Google Cloud console → APIs & Services → Maps SDK for Android / Routes API → Metrics & Quotas; Billing → Budgets | Well under quota; budget alert not triggered |

Also: the **uptime check** is the Keep-alive workflow (GitHub → Actions). A red run means `/health` failed, and GitHub emails the repo admins.

Reports for the pilot-success metrics: `GET /api/v1/admin/reports/summary` and the CSV `GET /api/v1/admin/reports/trips.csv`.

## Logs

- **Format.** Outside dev, the server writes **one JSON object per line**: `ts`, `level`, `logger`, `msg`, plus fields. Render → service → *Logs* lets you search and filter (for example `@logger:ctms.request @status:500`, or plain text search). Render free keeps logs only for a short time (check the current limit). The runbook wants them searchable for 7 days, so add a log drain.
- **Request lines** (logger `ctms.request`):
  - Fields: `method`, `path` (**never the query string**), `status`, `duration_ms`, `request_id`.
  - Every response carries `X-Request-ID`. A client may send its own (letters, digits, `.`, `_`, `-`, max 64), which ties app reports to server lines.
  - `/health` is logged at DEBUG only.
- **Redaction** (`server/app/logging_mw.py`). Every formatted line, including tracebacks, passes through `redact()` before output, which removes:
  - coordinates (`lat`/`lng`/`latitude`/`longitude` key-values, and bare `34.1234, 74.8123` pairs)
  - bearer tokens, JWTs and refresh tokens
  - `token`/`push_token`/`id_token` values, `otp` values, passwords/secrets/API keys

  Uvicorn's own access log is turned off (`--no-access-log`) because it prints raw query strings. Code must still never log coordinates on purpose. `write_audit` meta never holds coordinates, tokens, emails or phones (server contract).
- **OTP codes.** The dev `ConsoleOtpProvider` prints driver codes to the log by design (ADR-7). `config.py` refuses `OTP_PROVIDER=console` whenever `APP_ENV` is `staging` or `production`, so codes cannot reach production logs. This is covered by `tests/test_logging_mw.py::test_console_otp_refused_outside_dev`.
- **Error tracking (Sentry): optional, not installed.** To add it later:
  1. `uv add sentry-sdk`
  2. In `create_app`, `sentry_sdk.init(dsn=..., environment=config.app_env, send_default_pii=False, traces_sample_rate=0)`, with a `before_send` hook that applies `redact()` to the message and breadcrumbs.
  3. Set `SENTRY_DSN` on Render.
  4. Use a separate DSN per environment.

  The Flutter app would use `sentry_flutter` (P7). Until then, unhandled errors are logged as `"unhandled error on <METHOD> <path>"` with a redacted traceback.

## Keep-alive

`.github/workflows/keepalive.yml` pings `GET /health` on every URL in the repo variable `KEEPALIVE_URLS`, every 10 minutes:

- **Cron (UTC):** `*/10 1-13 * * 1-6`, which is **06:30–19:29 IST, Monday–Saturday** (IST = UTC + 5:30).
- **Service hours are an assumption.** The PRD says they are "set with the university". When the university confirms them, convert to UTC and edit the cron. For example, 07:00–18:00 IST → `*/10 1-12 * * 1-6`. Cron hours are whole hours, so round outward.
- GitHub may delay scheduled runs by several minutes. It also **disables schedules after 60 days with no commits**: re-enable in Actions if that happens.
- On Render free the service sleeps after ~15 minutes idle, so the **external pinger** (UptimeRobot / cron-job.org, see deploy.md "Keep it awake") is what keeps it awake; this GitHub workflow is only a backup check.

## Backups

The runbook says to export weekly with `pg_dump` to storage the team controls, and to test one restore before launch. Assume the Supabase free plan gives you **no restorable backup**.

**Weekly (for example every Monday morning):**

```bash
# needs pg_dump >= the Supabase server version (check: Supabase → Settings → Infrastructure)
DATABASE_URL='<production session-pooler URL>' server/scripts/backup.sh ~/ctms-backups
# no local pg_dump? the script's header has a one-line Docker alternative
```

- The script writes `ctms-<UTC>.dump` (custom format, `public` schema only) plus a `.sha256`, and checks that the archive lists at least 19 tables. It keeps the newest 8 dumps locally (`BACKUP_KEEP`).
- **Copy the dump to the team's storage**: a private Google Drive folder owned by the project account, shared only with the server owner and one backup person.
  - The dump contains **personal data** (names, emails, phones, 90 days of bus trips).
  - Never put it in git, chat or a public link.
  - Delete copies older than the agreed retention (suggested: 8 weeks).

**Test restore (do once before launch, then every few months):**

1. Create a throwaway database. Either a new free Supabase project (`ctms-restore-test`), or the local dev Postgres: `docker exec ctms-dev-db-1 psql -U postgres -c "create database ctms_restore"`.
2. Restore:
   ```bash
   pg_restore --no-owner --no-privileges --exit-on-error --clean --if-exists \
     --dbname='<throwaway DB URL>' ctms-<stamp>.dump
   ```
3. Verify:
   ```sql
   select count(*) from information_schema.tables where table_schema = 'public';  -- 19 (+ alembic_version)
   select count(*) from public.settings;                                         -- 30+
   select count(*) from public.trips;                                            -- matches production
   select relname from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity;  -- no rows
   ```
4. Optionally, point a local server at it (`DATABASE_URL=… uv run uvicorn app.main:app`) and open `/health`.
5. Delete the throwaway database, and write the date and result in the release notes.

This procedure was rehearsed locally on 2026-11-08: `backup.sh` dumped 20 tables, the dump restored with exit 0, and the checks above passed.

## Privacy: retention jobs that run in the server

These are implemented in `server/app/jobs/retention.py` (P3). They run every `retention_interval_s` (60 s), and the values come from the `settings` table:

| Data | Kept | Setting key |
|---|---|---|
| Bus locations (`locations`) and `rejected_fixes` | 90 days | `location_retention_days` |
| Student location (`student_locations`, latest value only) | 5 minutes | `student_location_ttl_s` |
| Expired sessions | Until `expires_at` | (session TTL, `refresh_token_ttl_days`) |
| Driver OTP requests (`phone_otp_requests`) | 1 day | `otp_request_retention_s` |

The other privacy jobs and behaviour:

- **Trips are auto-closed** after 15 minutes without a fix (`trip_auto_close_s`, `server/app/jobs/trips.py`). Location sharing stops when a trip ends.
- **Account deletion.** `DELETE /me` (students) cascades sessions, push tokens, student location, alert settings, the alert log and consents, and scrubs audit metadata.
- **Push tokens** are removed on sign-out and when FCM reports them invalid.
- **No coordinates in logs** (see Logs).
- The retention period is an open item for the university. Change `location_retention_days` in the `settings` table; no deploy is needed.

## Incidents

First steps for the symptoms in the runbook's table, with the concrete checks:

| Symptom | Check first |
|---|---|
| A running bus is missing on students' maps | `GET /buses/live`: is the bus there, and what is its `state`? `select * from trips where ended_at is null;` to see whether a trip was started. Call the driver (T1, T5, T7) |
| Positions arrive late | `/health` latency. Render metrics (CPU/RAM). Keep-alive runs green? `clock_skew_s` on `/buses/live`. Logs: `"live writer flush failed"` means the DB is slow or down (N5; live tracking continues from memory) |
| No alerts arriving | The student's alert setting and push token; `ctms.push` log lines; FCM credentials valid (A5–A7, N9) |
| Students cannot sign in | `/health`, then `GOOGLE_OAUTH_CLIENT_IDS` contains the app's Web client ID for that environment. Look for 401s on `/api/v1/auth/google` |
| Driver cannot sign in | The driver record is active and has the right phone (admin app); OTP limits (3 sends per 10 min, `RATE_LIMITED` 429); the `OTP_PROVIDER` setup |
| Map is blank | Maps key restrictions (package + SHA-1) and quota in Google Cloud (N8) |
| Wrong ETAs | Compare the route polyline with the road (admin route editor; `PATCH /admin/routes/{id} {"regenerate": true}` refetches from the Routes API). Review `eta_v_min_kmh` |
| Server won't start after a deploy | Deploy logs: a config error lists every missing variable (`Invalid configuration for APP_ENV=…`), or an Alembic error. The previous deployment keeps serving, so fix the variables or roll back (deploy.md) |
| DB unreachable (`/health` 503 `DB_UNAVAILABLE`) | The Supabase status page and project (paused? free projects are paused after about a week of inactivity; the keep-alive's `/health` runs a DB query, which should count as activity, but check the dashboard after quiet weeks); `DATABASE_URL` uses the session pooler on 5432 |

For any incident longer than 15 minutes:

1. Post an announcement through the admin app so students know.
2. Afterwards, write a short note: what happened, how long it lasted, and what changed.

If personal data may have been exposed:

1. Rotate `JWT_SECRET` (this signs everyone out), the database password and the service-account key.
2. Record what happened.
3. Tell the university contact the same day.
