# CTMS V1: deploying the server

The server is one Docker image (`server/Dockerfile`, built from the **repo root**) running on **Railway**, with the database on **Supabase**. Staging and production are two Railway environments of the same service. Each environment has its own variables, its own Supabase project, and its own Firebase/Google Cloud project (runbook p.1).

Credentials: [credentials-checklist.md](credentials-checklist.md). Operations: [runbook.md](runbook.md).

## Why Railway

- The team already deployed CTMS on Railway (see `legacy/`).
- Railway services do **not sleep** unless serverless mode is turned on. Render's free web services sleep after 15 minutes idle and take about 30–60 s to wake. That would drop WebSockets and delay positions (PRD risk, TRD "sleeping servers").
- WebSockets (`/api/v1/ws/live`) work through Railway's edge with no extra settings.
- Config-as-code (`railway.toml`) points at `server/Dockerfile`, so the monorepo needs no root-directory tricks.
- **Cost:** Railway has no permanent free tier. New accounts get trial credit, then the Hobby plan (about USD 5/month including usage) applies. One small service with about 150 MB RAM fits inside that. If it must be strictly free, Render's free tier also works with `server/Dockerfile`. Set the health check path to `/health` and rely on the keep-alive workflow, accepting the cold starts.

## How the container starts

`CMD` = `alembic upgrade head && exec uvicorn app.main:app --workers 1 --proxy-headers --forwarded-allow-ips '*' --no-access-log --port $PORT`

1. **Migrations first** (runbook step 3). Alembic runs `supabase/migrations/0001..0003.sql`. 0001 is skipped if the schema already exists, because you ran it in the SQL editor. 0002 and 0003 are idempotent. If a migration fails, the container exits, the health check never passes, and Railway keeps the previous deployment serving.
2. **One worker, one replica.** Live bus state, the WebSocket hub, rate limits and jobs live in process memory (TRD: single instance). Never raise `numReplicas` or `--workers`.
3. Railway only routes traffic to the new deployment once `GET /health` returns 200, which checks the DB. The `railway.toml` health check timeout is 120 s.

Migration rule (runbook): each new migration must keep the **previous** server version working (add columns or tables; never rename or drop in the same release). That keeps rollback safe.

## One-time setup on Railway

1. <https://railway.com> → **New Project** → **Deploy from GitHub repo** → `murtazaaltaf410-hub/ctms`.
2. Railway finds `railway.toml` at the repo root:
   - builder `DOCKERFILE`, `server/Dockerfile`
   - health check `/health`
   - 1 replica
   - rebuilds only when `server/**`, `supabase/migrations/**` or `railway.toml` change

   Leave **Root Directory** empty: the build context must be the repo root.
3. **Environments:** the project starts with `production`. Add **staging**: Project → Settings → Environments → *New environment* (an empty one, or a duplicate with the variables replaced).
   - Set **staging** to deploy from `main`.
   - Set **production** to deploy from `main` as well with **automatic deploys off**, so you promote a known-good commit manually. Alternatively, use a `production` branch.
4. **Variables** (service → Variables), per environment. See the [table below](#environment-variables). Use **Raw editor** to paste several at once. Paste `FCM_CREDENTIALS` as one line of JSON.
5. **Networking** → *Generate domain* for each environment. This gives `ctms-staging.up.railway.app` or similar. That URL is the app's API base URL (`https://…/api/v1`).
6. **Region:** pick the one closest to the Supabase region (Mumbai). Railway currently offers Singapore (`asia-southeast1`) as the nearest.
7. Settings → Deploy → *Teardown/overlap*: leave the defaults. During a deploy the old and new containers overlap briefly. The new one rebuilds live state from the next fix (TC19), and the jobs are idempotent.
8. GitHub → repo → Settings → Secrets and variables → Actions → **Variables** → `KEEPALIVE_URLS` = `https://<prod-domain>/health https://<staging-domain>/health`.
9. GitHub → Settings → Branches → protect `main` → require the **CI** checks `Server (ruff + pytest)` and `Docker build (server)`.

## Environment variables

Names are exactly the `server/app/config.py` fields in upper case. Every threshold in `config.py` can also be overridden by env var, but the `settings` table (and the admin UI for `alert_radius_m`) is the normal place for those.

| Variable | Required on Railway | Example / default | Notes |
|---|---|---|---|
| `APP_ENV` | yes | `staging` / `production` | The image defaults to `production`. Outside dev/test, missing secrets stop the server at startup |
| `DATABASE_URL` | yes | `postgresql://postgres.<ref>:<pw>@aws-…pooler.supabase.com:5432/postgres` | Session pooler, port 5432 |
| `JWT_SECRET` | yes | 48+ random chars | Different per environment |
| `GOOGLE_OAUTH_CLIENT_IDS` | yes | `<web>.apps.googleusercontent.com[,<android>…]` | Must include the Web client ID used as `serverClientId` |
| `FCM_CREDENTIALS` | yes | `{"type":"service_account",…}` | Inline JSON (one line) or a file path; not base64 |
| `GOOGLE_DIRECTIONS_KEY` | yes | `AIza…` | Routes API key, server only (ADR-8) |
| `OTP_PROVIDER` | yes | `firebase` | `console` is refused outside dev (ADR-7) |
| `SEED_ADMIN_EMAIL` | recommended | `you@gmail.com` | Always an admin |
| `PUSH_PROVIDER` | no | `fcm` | Defaults to `fcm` outside dev. `fake`/`log` are refused outside dev |
| `TRUST_PROXY` | no | `true` (set in the image) | Rate limits use the client IP from `X-Forwarded-For` |
| `ALERT_RADIUS_M` | no | `500` | Fallback. The `settings` table / admin setting wins |
| `MIN_APP_VERSION` | no | `1.0.0` | Served by `GET /api/v1/config`. A `min_app_version` row in `settings` wins |
| `APP_UPDATE_URL` | no | Play testing link / APK URL | Served by `GET /api/v1/config` |
| `LOG_LEVEL` | no | `INFO` | JSON logs outside dev |
| `DB_POOL_MAX_SIZE` | no | `5` | Keep it small: the Supabase free session pooler has a low client limit (check Database → Settings → Pool size) |
| `PORT` | no | set by Railway | The container listens on `$PORT` (default 8000) |

Not used: `DB_STATEMENT_CACHE_SIZE` (only for the transaction pooler, which we don't use). Sentry is not installed (see the runbook).

## Every deploy (runbook "Deployment steps")

1. **Merge to `main` only with green CI** (ruff, pytest against Postgres 16, Alembic on a fresh DB, Docker build).
2. Railway builds the image and starts it:
   - **Migrations run first**, inside the container start.
   - Then it waits for `GET /health` = 200.

   Watch Deployments → *View logs*. You should see `Running upgrade …` lines (or nothing to do), then a JSON line `"CTMS server started (APP_ENV=staging, OTP provider=firebase)"`.
3. **Smoke test** (staging first, then production after promoting):

   ```bash
   BASE=https://<domain>
   curl -fsS $BASE/health                   # {"status":"ok","db":"ok","env":"staging",...}
   curl -fsS $BASE/api/v1/config            # min_app_version, thresholds
   # sign in: open the app (staging flavour) and sign in with Google -> the map loads
   curl -fsS -H "Authorization: Bearer $ACCESS" $BASE/api/v1/buses/live
   # drive the simulator for one minute (needs a driver linked to a bus; see below)
   cd server && uv run python scripts/simulate.py --base-url $BASE --phone +91XXXXXXXXXX --minutes 1
   #   or, without OTP (OTP_PROVIDER=firebase on Railway): --token <driver access token>
   ```

   **Pass:** the simulated bus appears on `/buses/live` (or on a student's map) within 5 s, moves, then disappears or goes stale after the trip ends.
   - `--phone` sign-in works only where the server can complete an OTP: locally with the console provider, or with a Firebase test number once the app flow exists. On staging today, pass `--token`.
4. **Keep-alive:** GitHub → Actions → *Keep-alive* → *Run workflow* once, and check it is green (runbook step 6).
5. Note the deployed commit and image in the release notes (Railway keeps the deploy history).

## Rollback

- **Server:** Railway → service → **Deployments** → pick the last good deployment → **Redeploy** (or *Rollback*). The previous image starts. Wait for `/health`, then rerun the smoke test.
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
