"""TC20 (U2): a student with alert mode on deletes their account mid-trip. Their location,
push token, alert settings and alert log are gone, and no further alert is sent."""

from __future__ import annotations

from tests.acceptance.sim_support import SimPlayer, alert_student, drain_alerts, plan

PERSONAL = ["student_locations", "push_tokens", "alert_settings", "sessions", "consents"]


async def test_tc20_delete_account_removes_personal_data_and_stops_alerts(client, con, live_app, push, sim_trip,
                                                                         start_trip, google_login):
    route, driver, _trip, player = await sim_trip()
    s = await alert_student(client, google_login, 31, *route.stop_point(1))
    await client.put("/api/v1/me/consents", json={"kind": "location", "version": "v1"}, headers=s.headers)

    async def after(upload):
        await drain_alerts(live_app)

    _, events = plan(route.geom, player.start, speed_kmh=30, interval_s=10, minutes=2)
    await player.play(events, after=after)
    assert len(push.sent) == 1                                   # alerted once on this trip
    assert await con.fetchval("select count(*) from public.alert_log where student_id = $1", s.id) == 1

    resp = await client.delete("/api/v1/me", headers=s.headers)
    assert resp.status_code == 204
    for table in PERSONAL:
        assert await con.fetchval(f"select count(*) from public.{table} where user_id = $1", s.id) == 0, table
    assert await con.fetchval("select count(*) from public.alert_log where student_id = $1", s.id) == 0
    assert await con.fetchval("select count(*) from public.users where id = $1", s.id) == 0
    assert (await client.get("/api/v1/me", headers=s.headers)).status_code == 401

    # The bus finishes this trip and starts another past the same spot: nothing more is sent.
    await player.end(events[-1].t + 30)
    trip2 = await start_trip(driver)
    p2 = SimPlayer(client, player.fake_clock, driver["headers"], trip2["id"], player.fake_clock.current)
    _, events2 = plan(route.geom, p2.start, speed_kmh=30, interval_s=10, minutes=2)
    await p2.play(events2, after=after)
    assert len(push.attempts) == 1
    # Nothing about the student is left in the audit log either.
    meta = await con.fetch("select meta::text as m from public.audit_log where target_id = $1", str(s.id))
    assert all("acc.student31" not in r["m"] and "fcm-acc-31" not in r["m"] for r in meta)
