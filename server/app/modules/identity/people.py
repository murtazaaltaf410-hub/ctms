"""Who is on my bus (v13-spec decisions 5, 10, 11).

GET /me/bus              approved student: my bus and its driver (name, phone, has_photo)
GET /drivers/{id}/photo  the driver, an admin, or an approved student assigned to that driver's bus
GET /me/driver-profile   driver: my own details and bus
"""

from __future__ import annotations

from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Response

from app.db import Conn
from app.deps import AuthUser, CurrentUser, require_role
from app.errors import ForbiddenRole, NotFound
from app.modules.students.service import ApprovedStudent
from app.schemas import ApiModel

router = APIRouter(tags=["identity"])
Driver = Annotated[CurrentUser, Depends(require_role("driver"))]


class DriverCard(ApiModel):
    id: UUID
    name: str
    phone: str | None
    has_photo: bool


class MyBusOut(ApiModel):
    bus_id: UUID
    label: str
    plate: str
    capacity: int | None
    driver: DriverCard | None


class DriverBus(ApiModel):
    id: UUID
    label: str
    plate: str
    default_route_id: UUID | None


class DriverSelfOut(ApiModel):
    id: UUID
    name: str
    phone: str | None
    email: str | None
    userid: str | None
    employee_id: str | None
    licence_no: str | None
    licence_expiry: date | None
    address: str | None
    has_photo: bool
    bus: DriverBus | None


@router.get("/me/bus", response_model=MyBusOut | None)
async def my_bus(user: ApprovedStudent, con: Conn) -> MyBusOut | None:
    """The bus the admin assigned, or null while none is. The driver's phone is shared with the riders so
    they can call; the driver's address and licence never are."""
    row = await con.fetchrow(
        """select b.id as bus_id, b.label, b.plate, b.capacity, d.id as driver_id, d.name as driver_name,
                  d.phone as driver_phone, coalesce(dp.photo is not null, false) as driver_has_photo
             from public.student_profiles sp
             join public.buses b on b.id = sp.bus_id
             left join public.users d on d.id = b.driver_id and d.active
             left join public.driver_profiles dp on dp.user_id = d.id
            where sp.user_id = $1""", user.id)
    if row is None:
        return None
    driver = None if row["driver_id"] is None else DriverCard(
        id=row["driver_id"], name=row["driver_name"], phone=row["driver_phone"], has_photo=row["driver_has_photo"])
    return MyBusOut(bus_id=row["bus_id"], label=row["label"], plate=row["plate"], capacity=row["capacity"],
                    driver=driver)


@router.get("/drivers/{driver_id}/photo", response_class=Response,
            responses={200: {"content": {"image/jpeg": {}, "image/png": {}}}})
async def get_driver_photo(driver_id: UUID, user: AuthUser, con: Conn) -> Response:
    allowed = user.role == "admin" or user.id == driver_id
    if not allowed and user.role == "student":
        allowed = bool(await con.fetchval(
            """select exists(select 1 from public.student_profiles sp
                               join public.buses b on b.id = sp.bus_id
                              where sp.user_id = $1 and sp.status = 'approved' and b.driver_id = $2)""",
            user.id, driver_id))
    if not allowed:
        raise ForbiddenRole("You may not view this photo")
    row = await con.fetchrow(
        "select photo, photo_mime from public.driver_profiles where user_id = $1 and photo is not null", driver_id)
    if row is None:
        raise NotFound("No photo")
    return Response(content=bytes(row["photo"]), media_type=row["photo_mime"],
                    headers={"Cache-Control": "private, no-store"})


@router.get("/me/driver-profile", response_model=DriverSelfOut)
async def my_driver_profile(user: Driver, con: Conn) -> DriverSelfOut:
    row = await con.fetchrow(
        """select u.id, u.name, u.phone, u.email, u.userid, p.employee_id, p.licence_no, p.licence_expiry,
                  p.address, coalesce(p.photo is not null, false) as has_photo
             from public.users u left join public.driver_profiles p on p.user_id = u.id where u.id = $1""",
        user.id)
    bus = await con.fetchrow(
        "select id, label, plate, default_route_id from public.buses where driver_id = $1 and active", user.id)
    return DriverSelfOut(**dict(row), bus=None if bus is None else DriverBus(**dict(bus)))
