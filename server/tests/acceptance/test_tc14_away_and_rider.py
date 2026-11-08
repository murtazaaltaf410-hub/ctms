"""TC14 (EC-A3, EC-A1): a bus moving away from a student inside 500 m sends no alert, and a
student riding the bus gets no alert."""

from __future__ import annotations

from app.geo import haversine_m
from scripts.simulate import offset
from tests.acceptance.sim_support import alert_student, drain_alerts, plan, report_location


async def test_tc14_bus_moving_away_inside_radius_no_alert(client, live_app, push, sim_trip, google_login):
    route, _driver, _trip, player = await sim_trip()
    start = route.stop_point(0)
    s = await alert_student(client, google_login, 11, *offset(*start, north_m=-300))   # 300 m behind the start
    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=5, minutes=3)

    async def after(upload):
        await drain_alerts(live_app)

    await player.play(events, after=after)
    assert not [m for m in push.sent if m.token == s.push_token]


async def test_tc14_student_riding_the_bus_no_alert(client, live_app, push, sim_trip, google_login):
    """Idealised rider: the student's phone reports a position next to the bus before every upload."""
    route, _driver, _trip, player = await sim_trip()
    s = await alert_student(client, google_login, 12, *offset(*route.stop_point(0), east_m=5))
    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=5)

    async def after(upload):
        newest = upload.batch.fixes[-1]
        await report_location(client, s.headers, *offset(newest.lat, newest.lng, east_m=5))
        await drain_alerts(live_app)

    await player.play(events, after=after)
    assert not [m for m in push.sent if m.token == s.push_token]


async def test_tc14_rider_with_100m_move_reporting_no_alert(client, live_app, push, sim_trip, google_login):
    """Realistic rider: the phone reports only when it has moved 100 m (plan: student move-report 100 m),
    while the driver uploads every 5 s. The student boards at the first stop, so two near fixes there set
    the rider flag, which holds while the stored location lags the bus by up to 100 m."""
    route, _driver, _trip, player = await sim_trip()
    first = route.stop_point(0)
    s = await alert_student(client, google_login, 13, *first)
    last_report = {"at": first}
    _, events = plan(route.geom, player.start, speed_kmh=30, fix_every_s=3, interval_s=5)

    async def after(upload):
        await drain_alerts(live_app)          # the engine sees the bus fix first ...
        newest = upload.batch.fixes[-1]
        if haversine_m(*last_report["at"], newest.lat, newest.lng) >= 100:
            last_report["at"] = (newest.lat, newest.lng)          # ... then the riding phone reports
            await report_location(client, s.headers, newest.lat, newest.lng)

    await player.play(events, after=after)
    assert not [m for m in push.sent if m.token == s.push_token]
