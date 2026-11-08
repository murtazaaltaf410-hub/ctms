# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Campus Transport Management System (CTMS) V1 does real-time bus tracking for the University of Kashmir, North Campus. It is a pilot with 1–3 buses on 1–2 routes, using free-tier hosting.
- **Students** see buses live on Google Maps, get ETAs to stops, nearby-bus push alerts and announcements.
- **Drivers** start/stop trips and stream GPS from a foreground service.
- **Admins** manage fleet/routes/stops/schedules/announcements/reports inside the same app.

The repo is mid-rewrite: an earlier React/Express/MySQL implementation is being replaced by the documented stack.

## Source of truth

`docs/v1/` is authoritative. Read the relevant files before changing behaviour:
- `prd.txt`, `trd.txt`, `api-spec.txt`, `edge-cases.txt`, `test-plan.txt`, `runbook.txt` are text extracts of the six root PDFs. `*.raw.txt` variants read tables better.
- `allowed-apis.md`: the only library APIs to use, each with its doc citation. Look up anything new with context7 and add it there first.
- `decisions.md`: ADRs (driver OTP via Firebase Phone Auth, plain asyncpg, custom rate limiter, asyncio jobs, flutter_foreground_task, extra thresholds).
- `requirements-matrix.md`: every PRD/TRD/edge-case/test/endpoint ID → owning phase. Phase 10 fills in the evidence.

The rewrite plan (phases P0–P10) lives at `~/.claude/plans/i-have-added-the-adaptive-island.md`.

## Layout

```
server/            FastAPI app (uv, Python 3.12): app/{main,config,db,errors,deps}.py, app/modules/<domain>/, app/live/, app/jobs/; tests/ (pytest)
supabase/migrations/  0001_schema.sql 0002_rls.sql 0003_seed.sql  (user runs in the Supabase SQL editor; Alembic in server/migrations runs the same files)
app/               Flutter app, one app for all three roles, flavors staging/prod
docs/v1/           specs + decisions (see above)
legacy/            old backend/ frontend/ database/ nginx/ docker-compose.yml: REFERENCE ONLY, never edit or import; deleted after the launch gate
```

`server/`, `supabase/` and `app/` are created by phases P1/P2/P7. Until then, they may not exist.

## Non-negotiable conventions (from the API spec)

- Everything is under `/api/v1`. The WebSocket is `/api/v1/ws/live`; the first message is `{"type":"auth","token":...}` within 5 s. The bearer token is never sent in the URL.
- Response format:
  - JSON fields are snake_case.
  - Times are UTC ISO-8601, with `Z`.
  - Distances are in metres, speeds in m/s, ETAs in `eta_seconds`.
  - IDs are UUIDs.
  - Lists use `?limit` (default 50, max 200) and `?cursor`, and return `next_cursor`.
- Errors use the envelope `{"error":{"code","message"}}` with only the spec codes. Validation errors are **400** `VALIDATION_ERROR`, not FastAPI's default 422. 429s carry `Retry-After`.
- The role is loaded from the DB on every request, never trusted from the JWT alone. The refresh token goes in the request body, not a cookie. Drivers get one active session (`SESSION_REPLACED`).
- Every threshold is config (pydantic-settings / `settings` table), never a literal. See the plan and `decisions.md` ADR-6.
- Drivers post fixes over REST (`POST /trips/{id}/locations`, ≤20, client `fix_id`). The WebSocket only fans out to students and admins.

## Commits

- Author Technolity only. Do **not** add `Co-Authored-By` or "Generated with" lines.
- Agents share one index, so commit with a pathspec in one step: `git commit -m "..." -- <paths>`. Never use `--amend`.

## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `python3 -c "from graphify.watch import _rebuild_code; from pathlib import Path; _rebuild_code(Path('.'))"` to keep the graph current

Note: the current graph was built from the legacy code. Rebuild it once `server/` and `app/` exist.
