"""TC10, server side: while the simulator drives a route, every accepted upload is pushed to
connected students as `bus_position` during the same request, and `GET /buses/live` serves
the new position at once. With a 3 s fix cadence and a 5 s upload interval, the newest fix
is never more than 5 s old when it reaches the socket.

Marker animation on the phone is app-owned (P8); the 5 s end-to-end check is field test FT-D1."""

from __future__ import annotations

from datetime import datetime

from tests.acceptance.sim_support import live_bus, plan, ws_connect


def ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


async def test_tc10_each_upload_reaches_students_immediately(client, live_app, sim_trip, google_login):
    route, _driver, trip, player = await sim_trip()
    student = await google_login()
    ws, _task = await ws_connect(live_app, student["access_token"])
    _fixes, events = plan(route.geom, player.start, speed_kmh=30, fix_every_s=3, interval_s=5, minutes=4)

    async def check(upload):
        newest = upload.batch.fixes[-1]
        msg = ws.sent[-1]
        assert msg["type"] == "bus_position" and msg["trip_id"] == trip["id"]
        assert (msg["lat"], msg["lng"]) == (round(newest.lat, 7), round(newest.lng, 7))
        bus = await live_bus(client, {"Authorization": f"Bearer {student['access_token']}"}, trip["bus_id"])
        assert (bus["lat"], bus["lng"]) == (msg["lat"], msg["lng"]) and bus["state"] == "live"
        # Age of the newest fix when the server published it (receive time - phone time).
        assert (ts(bus["last_fix_at"]) - ts(msg["recorded_at"])).total_seconds() <= 5

    uploads = await player.play(events, after=check)
    assert len(uploads) == len(events)
    positions = [m for m in ws.sent if m["type"] == "bus_position"]
    assert len(positions) == len(uploads)
    assert ws.sent[0]["type"] == "bus_position"     # the trip_started went out before the student connected
    headings = {m["heading"] for m in positions}
    assert {0.0, 90.0} <= headings                    # north leg, then east leg after the corner
