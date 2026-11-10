"""Digital bus card (v13-spec decision 6).

GET /me/bus-card           approved student: the card, with the signed QR payload
GET /bus-card/verify?token public, rate-limited: {valid, name, bus_label, valid_until} and nothing else
"""

from __future__ import annotations

from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Query, Request

from app import clock
from app.db import Conn
from app.errors import NotFound
from app.modules.buscard import service
from app.modules.students.service import ApprovedStudent
from app.ratelimit import rate_limit
from app.schemas import ApiModel, UtcDateTime, iso_utc

router = APIRouter(tags=["bus card"])

_CARD_SQL = """
select sp.full_name, sp.enrollment_no, sp.department, sp.reviewed_at, sp.photo is not null as has_photo,
       r.name as route_name, b.label as bus_label, b.plate
  from public.student_profiles sp
  left join public.routes r on r.id = sp.route_id
  left join public.buses b on b.id = sp.bus_id
 where sp.user_id = $1 and sp.status = 'approved'
"""


class BusCardOut(ApiModel):
    card_no: str
    name: str
    enrollment_no: str | None
    department: str | None
    route_name: str | None
    bus_label: str | None
    plate: str | None
    has_photo: bool = False
    issued_at: UtcDateTime
    valid_until: date
    signature: str
    qr_payload: str


class VerifyOut(ApiModel):
    valid: bool
    name: str | None = None
    bus_label: str | None = None
    valid_until: date | None = None


@router.get("/me/bus-card", response_model=BusCardOut)
async def my_bus_card(request: Request, user: ApprovedStudent, con: Conn) -> BusCardOut:
    row = await con.fetchrow(_CARD_SQL, user.id)
    if row is None:
        raise NotFound("No bus card")
    config, store = request.app.state.config, request.app.state.settings_store
    now = clock.now()
    issued_at = row["reviewed_at"] or now
    until = service.valid_until(await store.get("bus_card_valid_until", con),
                                service.local_today(now, str(store.get_cached("timezone"))))
    number = service.card_no(user.id, issued_at)
    payload = {"v": service.PAYLOAD_VERSION, "sub": str(user.id), "card_no": number, "name": row["full_name"],
               "bus": row["bus_label"], "iat": iso_utc(issued_at), "until": until.isoformat()}
    signature, qr_payload = service.sign(service.derive_key(config.jwt_secret), payload)
    return BusCardOut(card_no=number, name=row["full_name"], enrollment_no=row["enrollment_no"],
                      department=row["department"], route_name=row["route_name"], bus_label=row["bus_label"],
                      plate=row["plate"], has_photo=row["has_photo"], issued_at=issued_at, valid_until=until,
                      signature=signature, qr_payload=qr_payload)


@router.get("/bus-card/verify", response_model=VerifyOut,
            dependencies=[rate_limit("bus_verify", per="ip", limit_key="rate_bus_verify_per_ip")])
async def verify_bus_card(request: Request, con: Conn,
                          token: Annotated[str, Query(min_length=1, max_length=2048)]) -> VerifyOut:
    """Anyone can scan a card. Tampered, unknown or no-longer-approved cards are `valid: false` with no details;
    an authentic but expired card is `valid: false` with the name and bus so the checker can see why."""
    payload = service.open_token(service.derive_key(request.app.state.config.jwt_secret), token)
    if payload is None:
        return VerifyOut(valid=False)
    try:
        student_id = UUID(str(payload["sub"]))
        until = date.fromisoformat(str(payload["until"]))
    except (KeyError, ValueError):
        return VerifyOut(valid=False)
    row = await con.fetchrow(
        """select sp.full_name, b.label as bus_label from public.student_profiles sp
             left join public.buses b on b.id = sp.bus_id
            where sp.user_id = $1 and sp.status = 'approved'""", student_id)
    if row is None:
        return VerifyOut(valid=False)
    today = service.local_today(clock.now(), str(request.app.state.settings_store.get_cached("timezone")))
    return VerifyOut(valid=today <= until, name=row["full_name"], bus_label=row["bus_label"], valid_until=until)
