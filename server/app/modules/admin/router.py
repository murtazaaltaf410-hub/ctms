"""Phase 5 routers in one place, so `app/api/router.py` needs a single include line.

Admin (role admin): buses, drivers, routes + stops, schedules, admins, trips/reports, settings.
Any signed-in user: GET /routes, GET /routes/{id}, GET /schedules.
"""

from __future__ import annotations

from fastapi import APIRouter

from app.modules.admin.admins import router as admins_router
from app.modules.admin.drivers import router as drivers_router
from app.modules.buses.router import router as buses_router
from app.modules.identity.deregistration import router as deregistration_router
from app.modules.reports.router import router as reports_router
from app.modules.routes.router import admin_router as admin_routes_router
from app.modules.routes.router import public_router as routes_router
from app.modules.schedules.router import admin_router as admin_schedules_router
from app.modules.schedules.router import public_router as schedules_router
from app.modules.settings.router import router as settings_router
from app.modules.students.admin import router as students_admin_router

router = APIRouter()
for sub in (routes_router, schedules_router, buses_router, drivers_router, admin_routes_router,
            admin_schedules_router, admins_router, reports_router, settings_router, students_admin_router,
            deregistration_router):
    router.include_router(sub)
