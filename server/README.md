# CTMS V1 server (FastAPI)

Python 3.12, managed with [uv](https://docs.astral.sh/uv/). Plain asyncpg (ADR-2), no ORM.

```bash
docker compose -f docker-compose.dev.yml up -d   # from the repo root: Postgres 16 on :55432 (ctms + ctms_test)
cd server
uv sync
uv run ruff check .
uv run pytest -q                                 # uses TEST_DATABASE_URL (default ctms_test on :55432)
uv run uvicorn app.main:app --reload --port 8000 # /docs, /health, /api/v1/...
DATABASE_URL=postgresql://... uv run alembic upgrade head   # deploy: runs supabase/migrations/*.sql
```

Configuration: see the root `.env.example` (copy to `server/.env`). Outside `APP_ENV=dev|test` the
app refuses to start with missing secrets.

Drivers sign in with `POST /api/v1/auth/login` (userid, email or phone + password, ADR-10). An admin creates
the account in the admin app and gets a one-time temporary password; the seeded demo driver
(`+910000000001`) has no password until an admin resets it (`POST /api/v1/admin/drivers/{id}/reset-password`).

## Layout

| Path | What |
|---|---|
| `app/main.py` | `create_app(config)` + lifespan (pool, settings, startup hooks, jobs); `/health`, `/docs` |
| `app/config.py` | pydantic-settings; every threshold as a field named like its `settings` key |
| `app/settings_store.py` | `settings` table values with config fallback (cached, `invalidate()`) |
| `app/db.py` | pool, `Conn` dependency, `acquire(app)` for jobs |
| `app/errors.py` | error envelope + every spec error code as an `AppError` subclass |
| `app/deps.py` | `get_current_user` (user + session loaded from DB each request), `require_role` |
| `app/ratelimit.py` | in-memory sliding-window limiter (ADR-3) |
| `app/audit.py` | `write_audit`, `scrub_user_audit` |
| `app/otp/` | pluggable driver OTP providers (ADR-7): console, firebase |
| `app/live/__init__.py` | lifecycle + domain-event hook registry (P3 fills `app/live/`) |
| `app/jobs/__init__.py` | background job registry (ADR-4) |
| `app/api/router.py` | `/api/v1` router; P3–P5 add `include_router` lines in their block |
| `app/modules/{auth,me}/` | auth and account endpoints |

## Adding a module (P3–P5)

```python
# app/modules/buses/router.py
from typing import Annotated
from fastapi import APIRouter, Depends
from app.db import Conn
from app.deps import CurrentUser, require_role
from app.errors import NotFound, InUse

router = APIRouter(prefix="/admin/buses", tags=["admin"])
Admin = Annotated[CurrentUser, Depends(require_role("admin"))]

@router.get("")
async def list_buses(user: Admin, con: Conn): ...
```

Then add `api_router.include_router(router)` in your phase's block of `app/api/router.py`.
Tests: use the fixtures in `tests/conftest.py` (`client`, `con`, `create_user`, `google_login`, `driver_login`).
