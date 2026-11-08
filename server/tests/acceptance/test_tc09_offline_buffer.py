"""TC9 (T6), server side: the driver phone is offline for 3 minutes. Its buffered fixes
arrive in order, in batches of up to 20; every one is stored (history filled in), the live
position jumps straight to the newest fix, and the trip is not closed.

Buffering on the phone itself is app-owned (P8) and checked in the field test (FT-D6)."""

from __future__ import annotations

import itertools
from uuid import UUID

from app.jobs.trips import auto_close_tick
from app.live.hub import get_hub
from app.live.writer import get_writer
from scripts.simulate import Dropout
from tests.acceptance.sim_support import assert_server_verdicts, live_bus, plan
from tests.tracking_support import FakeWS


async def test_tc9_three_minute_dropout_backfills_in_order_and_live_jumps(client, con, live_app, sim_trip):
    route, driver, trip, player = await sim_trip()
    ws = FakeWS(live_app)
    get_hub(live_app).add(ws, UUID(int=1), UUID(int=2))
    fixes, events = plan(
        route.geom, player.start, speed_kmh=25, fix_every_s=3, interval_s=5, minutes=6, dropouts=[Dropout(60, 180)]
    )
    states = []

    async def watch(upload):
        states.append((upload.t, upload.batch.backlog))

    # Before the network comes back: the bus goes stale then offline, but the trip stays open.
    await player.play(events, until=239)
    player.move_clock(239)
    bus = await live_bus(client, driver["headers"], trip["bus_id"])
    assert bus["state"] == "offline"
    assert await auto_close_tick(live_app) == 0

    ws.sent.clear()
    uploads = await player.play([e for e in events if e.t >= 240], after=watch)
    assert_server_verdicts(player.uploads)

    catch_up = [u for u in uploads if u.batch.backlog]
    assert len(catch_up) >= 3 and all(len(u.batch.fixes) <= 20 for u in catch_up)
    assert {u.t for u in catch_up} == {240}
    # One bus_position per request, each for that batch's newest fix (the map jumps forward).
    positions = [m for m in ws.sent if m["type"] == "bus_position"]
    assert [m["recorded_at"] for m in positions[: len(catch_up)]] == [
        u.batch.fixes[-1].payload()["recorded_at"] for u in catch_up
    ]
    newest_backlog = catch_up[-1].batch.fixes[-1]

    bus = await live_bus(client, driver["headers"], trip["bus_id"])
    assert bus["state"] == "live"
    assert bus["recorded_at"] == fixes[-1].payload()["recorded_at"]  # live = the newest fix overall
    assert newest_backlog.t <= 240

    # History is complete and in recorded order, including the offline period.
    await get_writer(live_app).flush(live_app)
    rows = await con.fetch(
        "select fix_id, recorded_at from public.locations where trip_id = $1 order by id", UUID(trip["id"])
    )
    assert [r["fix_id"] for r in rows] == [f.fix_id for f in fixes]
    assert all(a["recorded_at"] < b["recorded_at"] for a, b in itertools.pairwise(rows))
    gap = [f for f in fixes if 55 < f.t <= 240]
    assert len(gap) > 55 and {f.fix_id for f in gap} <= {r["fix_id"] for r in rows}
    assert await con.fetchval("select ended_at from public.trips where id = $1", UUID(trip["id"])) is None


async def test_tc9_backlog_arriving_out_of_order_is_history_only(client, con, live_app, sim_trip):
    """T12: if a newer fix got through first, the older buffered ones are stored but do not move the bus."""
    route, driver, trip, player = await sim_trip()
    _fixes, events = plan(
        route.geom, player.start, speed_kmh=25, fix_every_s=3, interval_s=5, minutes=3, dropouts=[Dropout(30, 60)]
    )
    before = [e for e in events if e.t < 90]
    catch_up = [e for e in events if e.t == 90]
    await player.play(before)
    # Deliver the newest backlog chunk first, then the older ones.
    await player.play(catch_up[::-1])
    bus = await live_bus(client, driver["headers"], trip["bus_id"])
    assert bus["recorded_at"] == catch_up[-1].item.fixes[-1].payload()["recorded_at"]
    assert all(not u.rejected for u in player.uploads)
    await get_writer(live_app).flush(live_app)
    count = await con.fetchval("select count(*) from public.locations where trip_id = $1", UUID(trip["id"]))
    assert count == sum(len(e.item.fixes) for e in before + catch_up)
