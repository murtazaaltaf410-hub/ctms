# CTMS V1 API server image.
#
# Build context is the REPO ROOT (the Alembic revisions execute
# supabase/migrations/*.sql, which live outside server/):
#
#   docker build -f server/Dockerfile -t ctms-server .
#   docker run --rm -p 8000:8000 --env-file server/.env ctms-server
#
# On start the container runs `alembic upgrade head` (migrations first, runbook
# step 3) and then ONE uvicorn worker: live bus state, the WebSocket hub, the
# rate limiter and the background jobs are in-process (TRD: single instance).
# Render injects $PORT; it defaults to 8000.

FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.11 /uv /usr/local/bin/uv

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    PATH="/app/.venv/bin:$PATH" \
    CTMS_SQL_DIR=/app/sql \
    APP_ENV=production \
    TRUST_PROXY=true \
    PORT=8000

WORKDIR /app

# Dependencies first (cached layer): exactly what uv.lock pins, no dev group.
COPY server/pyproject.toml server/uv.lock ./
RUN uv sync --locked --no-dev --no-install-project

# Application code, Alembic runner and the SQL it executes.
COPY server/alembic.ini ./
COPY server/migrations ./migrations
COPY server/app ./app
COPY supabase/migrations ./sql

RUN useradd --uid 10001 --no-create-home --home-dir /app --shell /usr/sbin/nologin ctms \
    && chown -R ctms:ctms /app
USER ctms

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/health' % os.environ.get('PORT','8000'), timeout=4)" || exit 1

# --proxy-headers + --forwarded-allow-ips: the host's edge proxy sets X-Forwarded-*.
# --no-access-log: app.logging_mw writes redacted request lines instead (uvicorn's
# access log would print raw query strings).
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port \"${PORT:-8000}\" --workers 1 --proxy-headers --forwarded-allow-ips '*' --no-access-log"]
