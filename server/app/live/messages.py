"""WS message builders (API spec p.6). Flat objects, UUIDs as strings, UTC ISO times."""

from __future__ import annotations

from uuid import UUID

from app.live.state import BusLive
from app.schemas import iso_utc


def _speed(bus: BusLive) -> float | None:
    return None if bus.ema_speed_mps is None else round(bus.ema_speed_mps, 2)


def bus_position(bus: BusLive) -> dict:
    return {
        "type": "bus_position", "bus_id": str(bus.bus_id), "trip_id": str(bus.trip_id),
        "lat": bus.lat, "lng": bus.lng, "heading": bus.heading, "speed": _speed(bus),
        "recorded_at": iso_utc(bus.recorded_at) if bus.recorded_at else None,
    }


def bus_status(bus: BusLive) -> dict:
    return {"type": "bus_status", "bus_id": str(bus.bus_id), "trip_id": str(bus.trip_id),
            "status": bus.status, "note": bus.note}


def trip_started(bus_id: UUID, trip_id: UUID) -> dict:
    return {"type": "trip_started", "bus_id": str(bus_id), "trip_id": str(trip_id)}


def trip_ended(bus_id: UUID, trip_id: UUID) -> dict:
    return {"type": "trip_ended", "bus_id": str(bus_id), "trip_id": str(trip_id)}
