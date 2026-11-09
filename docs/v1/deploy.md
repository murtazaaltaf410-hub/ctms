# CTMS V1: deploying the server

The server is one Docker image (`server/Dockerfile`, built from the **repo root**) running on **Render** (free web service), with the database on **Supabase**. Config-as-code is `render.yaml` at the repo root. Each environment (staging, production) is its own Render service with its own variables, its own Supabase project, and its own Firebase/Google Cloud project (runbook p.1).

Credentials: [credentials-checklist.md](credentials-checklist.md). Operations: [runbook.md](runbook.md).

## Why Render

- **Free.** Railway no longer has a free tier. Render's free web service costs nothing and runs a Docker image from `server/Dockerfile`.
- WebSockets (`/api/v1/ws/live`) work on Render with no extra settings.
- `render.yaml` points at `server/Dockerfile` with the repo root as the Docker context, so the monorepo needs no root-directory tricks.
- **The catch: free instances sleep** after about 15 minutes without inbound traffic, and take 30–60 s to wake. A sleep wipes the in-process live state and drops WebSockets (PRD risk, TRD "sleeping servers"). The fix is an external pinger, see [Keep it awake](#keep-it-awake).
- Free limits to know: 512 MB RAM and a shared CPU (fine for 1–3 buses), about 750 instance-hours per month per workspace (one service running all month is 744 h; pinging only in service hours leaves headroom), no persistent disk (we don't need one), and the filesystem resets on every restart.
- If the pilot outgrows this, the Render *Starter* plan (about USD 7/month) never sleeps. Only `plan:` in `render.yaml` changes.

## How the container starts

`CMD` = `alembic upgrade head && exec uvicorn app.main:app --workers 1 --proxy-headers --forwarded-allow-ips '*' --no-access-log --port $PORT`

1. **Migrations first** (runbook step 3). Alembic runs `supabase/migrations/0001..0003.sql`. 0001 is skipped if the schema already exists, because you ran it in the SQL editor. 0002 and 0003 are idempotent. If a migration fails, the container exits, the health check never passes, and Render keeps the previous deploy serving.
2. **One worker, one instance.** Live bus state, the WebSocket hub, rate limits and jobs live in process memory (TRD: single instance). Never raise `numInstances` or `--workers`.
3. Render only routes traffic to the new deploy once `GET /health` returns 200, which checks the DB. (On the free plan there is no `preDeployCommand`, which is why migrations run in the container start.)

Migration rule (runbook): each new migration must keep the **previous** server version working (add columns or tables; never rename or drop in the same release). That keeps rollback safe.

## One-time setup on Render

1. Push `main` to GitHub, then sign up at <https://render.com> with GitHub.
2. Dashboard → **New** → **Blueprint** → pick the `ctms` repo → branch `main`. Render reads `render.yaml` and shows the `ctms-api` service (plan **Free**, region Singapore).
3. Render prompts for every `sync: false` variable. Fill them from the [table below](#environment-variables). Paste `FCM_CREDENTIALS` as one line of JSON. `JWT_SECRET` is generated for you.
4. Click **Apply**. The first build takes a few minutes. When it is live, the URL is `https://ctms-api-xxxx.onrender.com`. That is the app's API base: `https://…onrender.com/api/v1`.
5. Open `https://<url>/health`. You should see `{"status":"ok","db":"ok",...}`. (The first request after a cold start can take up to a minute.)
6. **Staging (optional):** to run both, duplicate the service block in `render.yaml` as `ctms-api-staging` with `APP_ENV: staging`, its own Supabase/Firebase values, and `branch: staging`. Note that two always-awake free services use up the monthly hours quota; run staging on demand, or only ping production.
7. Set up the pinger now: [Keep it awake](#keep-it-awake).
8. GitHub → Settings → Branches → protect `main` → require the **CI** checks `Server (ruff + pytest)` and `Docker build (server)`.

> Render re-applies `render.yaml` on every push for the fields it lists. Variables marked `sync: false` are not touched afterwards: change those in the dashboard (service → **Environment**).

## Keep it awake

Render free sleeps after about 15 minutes with no inbound request. Any HTTP request counts, so a pinger on `GET /health` every 5–10 minutes keeps it up. `/health` also queries the DB, which stops Supabase's free plan from pausing after 7 idle days.

Use **two** pingers, because each one alone can fail:

### 1. UptimeRobot (primary, 5-minute interval)

1. Sign up at <https://uptimerobot.com> (free plan: 50 monitors, 5-minute interval).
2. **Add New Monitor** → type **HTTP(s)** → name `CTMS API` → URL `https://<your-service>.onrender.com/health` → interval **5 minutes**.
3. Add your email as an alert contact. A down alert is your uptime alarm.
4. Optional: set a maintenance window outside service hours so it can sleep at night and save instance-hours. If you want it awake 24/7, leave it running (744 h of the ~750 h quota).

### 2. cron-job.org (second pinger, 1–10 minute interval)

1. Sign up at <https://cron-job.org> (free).
2. **Create cronjob** → URL `https://<your-service>.onrender.com/health` → schedule **every 5 minutes**.
3. Under *Advanced* set the timeout to **60 s** (a cold start is slow) and tick *Treat redirects as success* off. Enable failure notifications.
4. If you want to limit it to service hours, pick the hours (IST) and Mon–Sat in the schedule editor. cron-job.org supports a time zone setting: choose `Asia/Kolkata`.

### 3. GitHub Actions (kept as a third check)

`.github/workflows/keepalive.yml` pings every 10 minutes in service hours (`*/10 1-13 * * 1-6` UTC, which is 06:30–19:29 IST Mon–Sat). GitHub often starts scheduled runs late and disables schedules after 60 days with no commits, so do **not** depend on it alone. Set the repo variable `KEEPALIVE_URLS` = `https://<your-service>.onrender.com/health` (GitHub → Settings → Secrets and variables → Actions → **Variables**).

### Check that it works

- Wait 20 minutes without opening the app, then request `https://<url>/health`. It should answer in under a second (not 30–60 s). If it was slow, the pinger is not hitting it; check the monitor's log.
- Render dashboard → service → **Logs**: you should see a `/health` request line every few minutes.
- First request after a sleep is the **cold start**. If the app shows a spinner for up to a minute in the morning, that is why: start the pinger window earlier than the first bus.

## Environment variables

Names are exactly the `server/app/config.py` fields in upper case. Every threshold in `config.py` can also be overridden by env var, but the `settings` table (and the admin UI for `alert_radius_m`) is the normal place for those.

| Variable | Required on Render | Example / default | Notes |
|---|---|---|---|
| `APP_ENV` | yes | `staging` / `production` | Set in `render.yaml`. Outside dev/test, missing secrets stop the server at startup |
| `DATABASE_URL` | yes | `postgresql://postgres.<ref>:<pw>@aws-…pooler.supabase.com:5432/postgres` | Session pooler, port 5432, IPv4 (Render's outbound is IPv4; the direct connection is IPv6-only) |
| `JWT_SECRET` | yes | generated by Render | Different per environment. 32+ chars |
| `GOOGLE_OAUTH_CLIENT_IDS` | yes | `<web>.apps.googleusercontent.com[,<android>…]` | Must include the Web client ID used as `serverClientId` |
| `FCM_CREDENTIALS` | yes | `{"type":"service_account",…}` | Inline JSON (one line) or a file path; not base64 |
| `GOOGLE_DIRECTIONS_KEY` | yes | `AIza…` | Routes API key, server only (ADR-8). No Android restriction |
| `OTP_PROVIDER` | yes | `firebase` | Set in `render.yaml`. `console` is refused outside dev (ADR-7) |
| `SEED_ADMIN_EMAIL` | recommended | `you@gmail.com` | Always an admin |
| `PUSH_PROVIDER` | no | `fcm` | Set in `render.yaml`. `fake`/`log` are refused outside dev |
| `TRUST_PROXY` | no | `true` | Set in `render.yaml` and the image. Rate limits use the client IP from `X-Forwarded-For` |
| `ALERT_RADIUS_M` | no | `500` | Fallback. The `settings` table / admin setting wins |
| `MIN_APP_VERSION` | no | `1.0.0` | Served by `GET /api/v1/config`. A `min_app_version` row in `settings` wins |
| `APP_UPDATE_URL` | no | Play testing link / APK URL | Served by `GET /api/v1/config` |
| `LOG_LEVEL` | no | `INFO` | JSON logs outside dev |
| `DB_POOL_MAX_SIZE` | no | `5` | Keep it small: the Supabase free session pooler has a low client limit (check Database → Settings → Pool size) |
| `PORT` | no | set by Render (`10000`) | The container listens on `$PORT` (default 8000) |

Not used: `DB_STATEMENT_CACHE_SIZE` (only for the transaction pooler, which we don't use). Sentry is not installed (see the runbook).

## Point the app at the host

Build the app with the Render URL (it must end in `/api/v1`):

```bash
cd app
flutter build apk --flavor staging --release \
  --dart-define=API_BASE_URL=https://<your-service>.onrender.com/api/v1 \
  --dart-define=OTP_MODE=firebase \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>
```

Use `--debug` while testing. No `adb reverse` is needed once the app talks to the public URL. Add any other `--dart-define`s from the credentials checklist.

## Every deploy (runbook "Deployment steps")

1. **Merge to `main` only with green CI** (ruff, pytest against Postgres 16, Alembic on a fresh DB, Docker build).
2. Render builds the image and starts it (`autoDeployTrigger: commit`):
   - **Migrations run first**, inside the container start.
   - Then it waits for `GET /health` = 200.

   Watch the service → **Events** and **Logs**. You should see `Running upgrade …` lines (or nothing to do), then a JSON line `"CTMS server started (APP_ENV=production, OTP provider=firebase)"`.
3. **Smoke test:**

   ```bash
   BASE=https://<your-service>.onrender.com
   curl -fsS $BASE/health                   # {"status":"ok","db":"ok","env":"production",...}
   curl -fsS $BASE/api/v1/config            # min_app_version, thresholds
   # sign in: open the app and sign in with Google -> the map loads
   curl -fsS -H "Authorization: Bearer $ACCESS" $BASE/api/v1/buses/live
   # drive the simulator for one minute (needs a driver linked to a bus; see below)
   cd server && uv run python scripts/simulate.py --base-url $BASE --phone +91XXXXXXXXXX --minutes 1
   #   or, without OTP (OTP_PROVIDER=firebase): --token <driver access token>
   ```

   **Pass:** the simulated bus appears on `/buses/live` (or on a student's map) within 5 s, moves, then disappears or goes stale after the trip ends.
   - `--phone` sign-in works only where the server can complete an OTP: locally with the console provider, or with a Firebase test number once the app flow exists. On a deployed host, pass `--token`.
4. **Pinger:** check UptimeRobot shows the monitor **Up**, and run GitHub → Actions → *Keep-alive* → *Run workflow* once (runbook step 6).
5. Note the deployed commit in the release notes (Render keeps the deploy history).

## Rollback

- **Server:** Render → service → **Events** (or **Deploys**) → pick the last good deploy → **Rollback**. The previous image starts. Wait for `/health`, then rerun the smoke test.
- **Never roll back a migration** (runbook). Migrations are forward-only, and Alembic `downgrade` raises on purpose. The previous server version must work with the new schema; that is the migration rule above. Only if data is corrupted: restore from the latest `pg_dump` (runbook, Backups) into a **new** Supabase project, then point `DATABASE_URL` at it.
- **App:** keep serving the old APK. Raise `MIN_APP_VERSION` only after a fixed build is available.
- Rehearse one rollback on staging before launch (launch gate).

## Local equivalent

```bash
docker compose -f docker-compose.dev.yml up -d
docker build -f server/Dockerfile -t ctms-server .
docker run --rm -p 8000:8000 -e APP_ENV=dev \
  -e DATABASE_URL=postgresql://postgres:postgres@host.docker.internal:55432/ctms ctms-server
curl localhost:8000/health && curl localhost:8000/api/v1/config
```
