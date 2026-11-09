"""POST /me/location, PUT /me/alert-settings (API spec p.4) and two student-only extensions:
GET /me/alert-settings and GET /me/alerts (in-app copy of sent alerts, N9).

Importing this module registers the alert engine's fix/trip listeners and the push worker.
"""

from __future__ import annotations

from datetime import timedelta
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request, Response, status
from pydantic import AwareDatetime, Field

from app import clock
from app.db import Conn
from app.deps import CurrentUser, require_role
from app.errors import ValidationFailed
from app.modules.alerts import engine as _engine  # noqa: F401  (registers listeners)
from app.modules.students.service import ApprovedStudent
from app.schemas import ApiModel, UtcDateTime

router = APIRouter(prefix="/me", tags=["alerts"])

Student = Annotated[CurrentUser, Depends(require_role("student"))]


class LocationIn(ApiModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    accuracy: float = Field(ge=0, description="Horizontal accuracy in metres")
    recorded_at: AwareDatetime


class AlertSettingsIn(ApiModel):
    enabled: bool


class AlertSettingsOut(ApiModel):
    enabled: bool


class SentAlertOut(ApiModel):
    trip_id: UUID
    bus_id: UUID
    bus_label: str
    route_name: str
    sent_at: UtcDateTime


class SentAlertsOut(ApiModel):
    items: list[SentAlertOut]


@router.post("/location", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def post_location(body: LocationIn, request: Request, user: ApprovedStudent, con: Conn) -> Response:
    """Store the student's latest location (only the newest is kept; used solely for nearby alerts).
    Rejects fixes with accuracy of `student_fix_max_accuracy_m` or worse, or older than
    `student_fix_max_age_s`; a timestamp in the future is clamped to server time."""
    store = request.app.state.settings_store
    max_accuracy = float(await store.get("student_fix_max_accuracy_m", con))
    max_age = float(store.get_cached("student_fix_max_age_s"))
    now = clock.now()
    if body.accuracy >= max_accuracy:
        raise ValidationFailed(f"accuracy: must be under {max_accuracy:g} m")
    if body.recorded_at < now - timedelta(seconds=max_age):
        raise ValidationFailed(f"recorded_at: older than {max_age:g} s")
    recorded_at = min(body.recorded_at, now)
    await con.execute(
        """insert into public.student_locations (user_id, lat, lng, accuracy_m, recorded_at)
           values ($1, $2, $3, $4, $5)
           on conflict (user_id) do update
             set lat = excluded.lat, lng = excluded.lng, accuracy_m = excluded.accuracy_m,
                 recorded_at = excluded.recorded_at
             where excluded.recorded_at >= public.student_locations.recorded_at""",
        user.id, body.lat, body.lng, body.accuracy, recorded_at,
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.put("/alert-settings", response_model=AlertSettingsOut)
async def put_alert_settings(body: AlertSettingsIn, user: ApprovedStudent, con: Conn) -> AlertSettingsOut:
    """Turn alert mode on or off. Enabling requires a registered push token (`PUT /me/push-token`).
    Turning it off also deletes the stored location, which is then no longer needed."""
    async with con.transaction():
        if body.enabled:
            has_token = await con.fetchval(
                "select exists(select 1 from public.push_tokens where user_id = $1)", user.id)
            if not has_token:
                raise ValidationFailed("enabled: register a push token (PUT /me/push-token) before enabling alerts")
        else:
            await con.execute("delete from public.student_locations where user_id = $1", user.id)
        enabled = await con.fetchval(
            """insert into public.alert_settings (user_id, enabled) values ($1, $2)
               on conflict (user_id) do update set enabled = excluded.enabled
               returning enabled""",
            user.id, body.enabled,
        )
    return AlertSettingsOut(enabled=enabled)


@router.get("/alert-settings", response_model=AlertSettingsOut,
            summary="Current alert mode (extension, not in the API spec)")
async def get_alert_settings(user: Student, con: Conn) -> AlertSettingsOut:
    enabled = await con.fetchval("select enabled from public.alert_settings where user_id = $1", user.id)
    return AlertSettingsOut(enabled=bool(enabled))


@router.get("/alerts", response_model=SentAlertsOut,
            summary="Recent nearby alerts sent to me (extension, not in the API spec)")
async def get_sent_alerts(user: Student, con: Conn,
                          limit: Annotated[int, Query(ge=1, le=50)] = 20) -> SentAlertsOut:
    """Edge case N9: the app shows recent alerts in-app, in case the push was not delivered."""
    rows = await con.fetch(
        """select l.trip_id, t.bus_id, b.label as bus_label, r.name as route_name, l.sent_at
           from public.alert_log l
           join public.trips t on t.id = l.trip_id
           join public.buses b on b.id = t.bus_id
           join public.routes r on r.id = t.route_id
           where l.student_id = $1
           order by l.sent_at desc, l.trip_id desc
           limit $2""",
        user.id, limit,
    )
    return SentAlertsOut(items=[SentAlertOut(**dict(row)) for row in rows])
