"""TC11 (N2), server side: a student's socket drops mid-trip and comes back. The socket
carries no history, so after re-authenticating the client calls `GET /buses/live`, which
returns the bus's current position; live messages then resume on the new socket.

The "Reconnecting" banner and backoff are app-owned (P7)."""

from __future__ import annotations

import asyncio

from tests.acceptance.sim_support import live_bus, plan, ws_connect
from tests.tracking_support import hub_clients


async def test_tc11_reconnect_then_refetch_gives_correct_positions(client, live_app, sim_trip, google_login):
    route, _driver, trip, player = await sim_trip()
    student = await google_login()
    headers = {"Authorization": f"Bearer {student['access_token']}"}
    fixes, events = plan(route.geom, player.start, speed_kmh=30, minutes=3, interval_s=5)
    third = len(events) // 3

    ws, task = await ws_connect(live_app, student["access_token"])
    await player.play(events[:third])
    got_before = len(ws.sent)
    ws.hang_up()  # connection killed
    await asyncio.wait_for(task, timeout=2)
    assert hub_clients(live_app) == 0

    await player.play(events[third : 2 * third])  # bus keeps moving while the student is away
    assert len(ws.sent) == got_before  # nothing is queued for a dead socket

    ws2, task2 = await ws_connect(live_app, student["access_token"])
    assert ws2.sent == []  # no replay on connect
    bus = await live_bus(client, headers, trip["bus_id"])
    newest = events[2 * third - 1].item.fixes[-1]
    assert (bus["lat"], bus["lng"]) == (round(newest.lat, 7), round(newest.lng, 7))
    assert bus["state"] == "live"

    await player.play(events[2 * third :])
    assert [m["type"] for m in ws2.sent] == ["bus_position"] * (len(events) - 2 * third)
    assert (ws2.sent[-1]["lat"], ws2.sent[-1]["lng"]) == (round(fixes[-1].lat, 7), round(fixes[-1].lng, 7))
    ws2.hang_up()
    await asyncio.wait_for(task2, timeout=2)


async def test_tc11_trip_that_ended_while_disconnected_is_gone_after_refetch(client, live_app, sim_trip, google_login):
    route, _driver, trip, player = await sim_trip()
    student = await google_login()
    ws, task = await ws_connect(live_app, student["access_token"])
    _, events = plan(route.geom, player.start, minutes=1)
    await player.play(events)
    ws.hang_up()
    await asyncio.wait_for(task, timeout=2)
    await player.end()  # trip_ended missed by the student
    assert await live_bus(client, {"Authorization": f"Bearer {student['access_token']}"}, trip["bus_id"]) is None
