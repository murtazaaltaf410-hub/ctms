"""ETA to a stop (TRD p.3):

    ETA = (d_stop - d_bus) / max(v_smooth, v_min)

d_bus is the bus's forward-snapped cumulative distance on the trip's frozen route
polyline, d_stop the stop's `dist_along_m` (or the stop snapped onto the same
polyline if that is missing). v_smooth is the EMA speed. A stop more than
`eta_passed_tolerance_m` behind the bus is `passed`; ETAs above
`eta_display_cap_s` are returned as the cap with `capped: true` ("30+ min", A9).
"""

from __future__ import annotations

from dataclasses import dataclass

from app.geo.snap import snap_forward
from app.live.state import BusLive


@dataclass(frozen=True)
class Eta:
    passed: bool
    distance_m: float | None
    eta_seconds: int | None
    capped: bool


def stop_along_m(bus: BusLive, stop_lat: float, stop_lng: float, dist_along_m: float | None,
                 tie_tolerance_m: float) -> float | None:
    if dist_along_m is not None:
        return float(dist_along_m)
    if not bus.route.usable:
        return None
    return snap_forward(bus.route.points, bus.route.cum, stop_lat, stop_lng, 0, tie_tolerance_m).along_m


def compute_eta(d_stop: float, d_bus: float, v_smooth_mps: float | None, *, v_min_mps: float, cap_s: float,
                passed_tolerance_m: float) -> Eta:
    remaining = d_stop - d_bus
    if remaining < -passed_tolerance_m:
        return Eta(True, None, None, False)
    remaining = max(0.0, remaining)
    seconds = remaining / max(v_smooth_mps or 0.0, v_min_mps)
    capped = seconds > cap_s
    return Eta(False, round(remaining, 1), round(min(seconds, cap_s)), capped)
