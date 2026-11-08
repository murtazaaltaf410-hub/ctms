"""All /api/v1 routes. Phases 3-5 each add their `include_router` lines in their block.

Every route gets the per-IP general rate limit; signed-in routes also get the
per-user limit (inside `get_current_user`).
"""

from __future__ import annotations

from fastapi import APIRouter

from app.modules.auth.router import router as auth_router
from app.modules.me.router import router as me_router
from app.ratelimit import rate_limit

API_PREFIX = "/api/v1"

api_router = APIRouter(prefix=API_PREFIX,
                       dependencies=[rate_limit("general_ip", per="ip", limit_key="rate_general_per_ip")])

# --- Phase 2: auth, me -----------------------------------------------------------
api_router.include_router(auth_router)
api_router.include_router(me_router)

# --- Phase 3: trips, tracking, live, ETA (add include_router lines here) ---------

# --- Phase 4: alerts, announcements (add include_router lines here) ---------------

# --- Phase 5: admin, buses, routes, schedules, reports, settings (add here) -------
