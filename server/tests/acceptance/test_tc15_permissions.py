"""TC15 (EC-A5, EC-A6, EC-A7, N9), server side: when the student's phone cannot provide what
alerts need, the server refuses clearly or records the alert for in-app display; it never
fails silently. The permission prompts and warnings themselves are app-owned (P8)."""

from __future__ import annotations

from datetime import timedelta

from app.schemas import iso_utc, utcnow
from tests.acceptance.sim_support import alert_student, drain_alerts, plan


async def test_tc15_alert_mode_needs_notifications_explicit_error(client, google_login):
    """EC-A7: no push token (notifications denied) -> alert mode cannot be switched on, with a reason."""
    tokens = await google_login(sub="tc15-a", email="tc15a@uok.edu.in")
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    resp = await client.put("/api/v1/me/alert-settings", json={"enabled": True}, headers=headers)
    assert resp.status_code == 400
    err = resp.json()["error"]
    assert err["code"] == "VALIDATION_ERROR" and "push token" in err["message"]
    assert (await client.get("/api/v1/me/alert-settings", headers=headers)).json() == {"enabled": False}


async def test_tc15_unusable_student_locations_are_refused_with_reasons(client, google_login):
    """EC-A6: an approximate (>=100 m) or old (>5 min) location is refused, so the app knows to ask again."""
    tokens = await google_login(sub="tc15-b", email="tc15b@uok.edu.in")
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    now = utcnow()
    for body, field in (({"accuracy": 150, "recorded_at": iso_utc(now)}, "accuracy"),
                        ({"accuracy": 10, "recorded_at": iso_utc(now - timedelta(minutes=6))}, "recorded_at")):
        resp = await client.post("/api/v1/me/location", json={"lat": 34.13, "lng": 74.83, **body}, headers=headers)
        assert resp.status_code == 400, resp.text
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR" and field in resp.json()["error"]["message"]


async def test_tc15_a5_location_older_than_5_min_gets_no_alert(client, con, live_app, push, sim_trip, google_login):
    """EC-A5: the student stopped reporting (background location denied); no alert from a stale position."""
    route, _driver, _trip, player = await sim_trip()
    s = await alert_student(client, google_login, 21, *route.stop_point(2))
    await con.execute("update public.student_locations set recorded_at = $2 where user_id = $1",
                      s.id, utcnow() - timedelta(minutes=6))
    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=10)

    async def after(upload):
        await drain_alerts(live_app)

    await player.play(events, after=after)
    assert push.attempts == []
    assert await con.fetchval("select count(*) from public.alert_log where student_id = $1", s.id) == 0


async def test_tc15_n9_invalid_token_deleted_alert_still_shown_in_app(client, con, live_app, push, sim_trip,
                                                                      google_login):
    """N9 / EC-A7: notifications were turned off after sign-up (FCM: unregistered). The token is
    deleted and the alert is still listed by GET /me/alerts for the app to show."""
    route, _driver, trip, player = await sim_trip()
    s = await alert_student(client, google_login, 22, *route.stop_point(2))
    push.invalid.add(s.push_token)
    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=10)

    async def after(upload):
        await drain_alerts(live_app)

    await player.play(events, after=after)
    assert [m.token for m in push.attempts] == [s.push_token] and push.sent == []
    assert await con.fetchval("select count(*) from public.push_tokens where user_id = $1", s.id) == 0
    items = (await client.get("/api/v1/me/alerts", headers=s.headers)).json()["items"]
    assert [i["trip_id"] for i in items] == [trip["id"]]
