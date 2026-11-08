"""TC13 (EC-A3, alert log): a simulated bus approaches a student; exactly one alert is sent
near 500 m and it is never repeated on that trip."""

from __future__ import annotations

import re

from scripts.simulate import offset
from tests.acceptance.sim_support import alert_student, drain_alerts, plan, report_location


def alerted_distance(body: str) -> int:
    match = re.search(r"is about (\d+) m away", body)
    assert match, body
    return int(match.group(1))


async def test_tc13_600_500_400_gives_one_alert(client, con, live_app, push, sim_trip, sim_route, google_login):
    """The literal test plan case: fixes at 600, 500 and 400 m from the student, then onwards."""
    straight = await sim_route([(34.1200, 74.8300), (34.1380, 74.8300)], [0.0, 1000.0, None])  # ~2 km north
    route, driver, trip, player = await sim_trip(route=straight)
    s = await alert_student(client, google_login, 1, *route.stop_point(1))  # standing at the 1000 m stop
    # 60 km/h with a fix and an upload every 6 s: one fix per 100 m, so the bus reports at 600, 500, 400 m ...
    _fixes, events = plan(route.geom, player.start, speed_kmh=60, fix_every_s=6, interval_s=6)
    distances, alerts_after = [], []

    async def after(upload):
        await drain_alerts(live_app)
        distances.append(round(1000 - upload.batch.fixes[-1].along_m, 3))
        alerts_after.append(len(push.sent))

    await player.play(events, after=after)
    i600, i500, i400 = (distances.index(d) for d in (600, 500, 400))
    assert alerts_after[i600] == alerts_after[i500] == 0  # 500 m is not "within" 500 m
    assert alerts_after[i400] == 1  # first fix inside the radius, getting closer
    assert alerts_after[-1] == 1  # ... and never again on this trip
    [msg] = push.sent
    assert msg.token == s.push_token and msg.title == "Bus nearby"
    assert alerted_distance(msg.body) == 400 and msg.body.startswith(driver.get("label", "Bus"))
    assert await con.fetchval("select count(*) from public.alert_log where student_id = $1", s.id) == 1
    inapp = (await client.get("/api/v1/me/alerts", headers=s.headers)).json()["items"]
    assert [a["trip_id"] for a in inapp] == [trip["id"]]


async def test_tc13_realistic_approach_on_a_road_alerts_once_near_500m(
    client, con, live_app, push, sim_trip, google_login
):
    route, _driver, _trip, player = await sim_trip()
    stop = route.stop_point(3)  # 2250 m along, on the east leg
    waiting = await alert_student(client, google_login, 2, *stop)
    far = await alert_student(client, google_login, 3, *offset(*stop, north_m=2500))
    off = await alert_student(client, google_login, 4, *stop, enabled=False)
    _fixes, events = plan(route.geom, player.start, speed_kmh=30, fix_every_s=3, interval_s=10)

    async def after(upload):
        await drain_alerts(live_app)

    await player.play(events, after=after)
    await player.end()
    sent = [m for m in push.sent if m.token == waiting.push_token]
    assert len(sent) == 1
    # Steps are ~83 m (30 km/h, 10 s uploads), so the alert lands in the last step before 500 m.
    assert 400 <= alerted_distance(sent[0].body) <= 500
    assert not [m for m in push.sent if m.token in (far.push_token, off.push_token)]
    counts = {
        r["student_id"]: r["n"]
        for r in await con.fetch("select student_id, count(*) as n from public.alert_log group by student_id")
    }
    assert counts.get(waiting.id) == 1 and far.id not in counts and off.id not in counts


async def test_tc13_new_trip_alerts_again(client, live_app, push, sim_trip, sim_route, google_login, start_trip):
    """One alert per bus per trip: the same bus on its next trip alerts the student again."""
    route, driver, trip, player = await sim_trip()
    s = await alert_student(client, google_login, 5, *route.stop_point(2))

    async def after(upload):
        await drain_alerts(live_app)

    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=10)
    await player.play(events, after=after)
    end_t = events[-1].t
    await player.end(end_t + 60)
    # The app re-reports at least every few minutes (TRD p.3); the first report is older than 5 min now.
    await report_location(client, s.headers, *route.stop_point(2))
    trip2 = await start_trip(driver)
    from tests.acceptance.sim_support import SimPlayer

    player2 = SimPlayer(client, player.fake_clock, driver["headers"], trip2["id"], player.fake_clock.current)
    _, events2 = plan(route.geom, player2.start, speed_kmh=30, interval_s=10)
    await player2.play(events2, after=after)
    assert [m.data["trip_id"] for m in push.sent if m.token == s.push_token] == [trip["id"], trip2["id"]]
