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
# ADR-10: student registration. Before the routes router, so /routes/nearest is not a route id.
from app.modules.students.router import router as students_router  # noqa: E402

api_router.include_router(students_router)

# --- Phase 3: trips, tracking, live, ETA (add include_router lines here) ---------
from app.modules.tracking.router import router as tracking_router  # noqa: E402  (trips, locations, live, ETA)

api_router.include_router(tracking_router)

# --- Phase 4: alerts, announcements (add include_router lines here) ---------------
from app.modules.alerts.router import router as alerts_router  # noqa: E402
from app.modules.announcements.router import router as announcements_router  # noqa: E402

api_router.include_router(alerts_router)
api_router.include_router(announcements_router)

# --- Phase 5: admin, buses, routes, schedules, reports, settings (add here) -------
from app.modules.admin.router import router as admin_router  # noqa: E402

api_router.include_router(admin_router)

# --- V1.1 (ADR-9): student pickup pins, driver waiting list --------------------------
from app.modules.pickups.router import router as pickups_router  # noqa: E402

api_router.include_router(pickups_router)

# --- Phase 9: public app config (min supported app version) -----------------------
from app.modules.appconfig.router import router as appconfig_router  # noqa: E402

api_router.include_router(appconfig_router)
