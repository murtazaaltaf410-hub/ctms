# Campus Transport Management System (CTMS) V1

Real-time bus tracking for the **University of Kashmir, North Campus**. This is a pilot with 1–3 buses on 1–2 routes, on free-tier hosting.

- **Students** see buses live on Google Maps, get ETAs to stops, nearby-bus push alerts and announcements.
- **Drivers** start/stop trips and stream GPS from a foreground service.
- **Admins** manage the fleet, routes, stops, schedules, announcements and reports inside the same app.

---

## Stack

| Layer | Tech |
|---|---|
| App | Flutter (one app for all three roles; flavors `staging` / `prod`), Google Maps, Firebase Auth + FCM |
| Server | FastAPI on Python 3.12 (uv), plain asyncpg, WebSocket live feed, asyncio background jobs |
| Database | Supabase Postgres (SQL files in `supabase/migrations/`, run by Alembic) |
| Hosting | Render free web service (Docker) + an external uptime pinger |

## Repository layout

```
server/              FastAPI app: app/{main,config,db,errors,deps}.py, app/modules/<domain>/, app/live/, app/jobs/; tests/
supabase/migrations/ 0001_schema.sql 0002_rls.sql 0003_seed.sql
app/                 Flutter app
docs/v1/             specs, decisions, runbook, deploy guide (source of truth)
render.yaml          Render Blueprint for the API
legacy/              the earlier React/Express/MySQL implementation: reference only, do not edit
```

## Documentation

Read `docs/v1/` before changing behaviour:

| File | What |
|---|---|
| [`deploy.md`](docs/v1/deploy.md) | Deploying to Render, keeping it awake, env vars, rollback |
| [`credentials-checklist.md`](docs/v1/credentials-checklist.md) | Every key and secret, where it goes |
| [`supabase-setup.md`](docs/v1/supabase-setup.md) | Creating the database |
| [`runbook.md`](docs/v1/runbook.md) | Operations, monitoring, backups |
| [`decisions.md`](docs/v1/decisions.md) | ADRs |
| [`server-contract.md`](docs/v1/server-contract.md) | The API contract |
| [`requirements-matrix.md`](docs/v1/requirements-matrix.md), [`test-matrix.md`](docs/v1/test-matrix.md) | Requirements and test coverage |

## Run it locally

```bash
# Postgres 16 on :55432 (ctms + ctms_test)
docker compose -f docker-compose.dev.yml up -d

cd server
cp ../.env.example .env          # then fill in the values
uv sync
uv run ruff check .
uv run pytest -q
uv run uvicorn app.main:app --reload --port 8000    # /docs, /health, /api/v1/...
```

In dev the console OTP provider prints driver codes in the server log (`DEV OTP for +91...: 123456`). The demo driver from the seed is `+910000000001`.

The app (needs a Google Maps key in `app/android/local.properties`, see the credentials checklist):

```bash
cd app
flutter pub get
adb reverse tcp:8000 tcp:8000    # physical Android device talking to the local server
flutter run --flavor staging
```

Simulate a driver: `cd server && uv run python scripts/simulate.py --help`.

## Deploy

The API runs on **Render** (free) from `render.yaml`; the database is on Supabase. Free instances sleep after about 15 minutes idle, so an external pinger (UptimeRobot / cron-job.org) must call `GET /health` every 5–10 minutes. Step-by-step instructions: [`docs/v1/deploy.md`](docs/v1/deploy.md).

```bash
docker build -f server/Dockerfile -t ctms-server .    # the build context is the REPO ROOT
```

## Conventions

- Everything is under `/api/v1`; the WebSocket is `/api/v1/ws/live` (first message `{"type":"auth","token":...}` within 5 s).
- JSON is snake_case; times are UTC ISO-8601 with `Z`; distances in metres, speeds in m/s, ETAs in `eta_seconds`; IDs are UUIDs.
- Errors use `{"error":{"code","message"}}`; validation errors are **400** `VALIDATION_ERROR`; 429s carry `Retry-After`.
- The role is loaded from the DB on every request. Thresholds are config, never literals.
- The server is **single instance** by design (live state, WebSocket hub and rate limits are in memory). Never add replicas or workers.
- Never commit secrets. Keys go in the Render dashboard (server) or gitignored files (app).
