"""TC7 (N6): the same fix_id sent twice is stored once. Covers in-batch duplicates and a
whole batch retried after a timeout (before and after the batched DB writer flushed)."""

from __future__ import annotations

from uuid import UUID

from app.live.writer import get_writer
from tests.acceptance.sim_support import assert_server_verdicts, plan


async def stored(con, trip_id: str) -> int:
    return await con.fetchval("select count(*) from public.locations where trip_id = $1", UUID(trip_id))


async def test_tc7_duplicate_fix_ids_are_stored_once(client, con, live_app, sim_trip):
    route, _driver, trip, player = await sim_trip()
    fixes, events = plan(route.geom, player.start, speed_kmh=30, fix_every_s=3, interval_s=6, minutes=2,
                         duplicate_every=4)
    uploads = await player.play(events)
    assert_server_verdicts(uploads)
    dupes = [f for f in fixes if f.kind == "duplicate"]
    assert dupes and sum(r == "DUPLICATE" for u in uploads for r in u.rejected.values()) == len(dupes)
    await get_writer(live_app).flush(live_app)
    assert await stored(con, trip["id"]) == len({f.fix_id for f in fixes})


async def test_tc7_retried_batches_are_ignored(client, con, live_app, sim_trip):
    """The app retries a batch whose response it never got: every fix comes back DUPLICATE."""
    route, driver, trip, player = await sim_trip()
    fixes, events = plan(route.geom, player.start, speed_kmh=30, fix_every_s=3, interval_s=9, minutes=2)
    url = f"/api/v1/trips/{trip['id']}/locations"
    for n, ev in enumerate(events):
        player.move_clock(ev.t)
        first = await client.post(url, json=ev.item.payload, headers=driver["headers"])
        assert first.status_code == 200 and not first.json()["rejected"]
        if n % 2:   # half the retries hit fixes already written to the DB, half still in the write queue
            await get_writer(live_app).flush(live_app)
        retry = await client.post(url, json=ev.item.payload, headers=driver["headers"])
        assert retry.status_code == 200 and retry.json()["accepted"] == []
        assert {r["reason"] for r in retry.json()["rejected"]} == {"DUPLICATE"}
        assert len(retry.json()["rejected"]) == len(ev.item.fixes)
    await get_writer(live_app).flush(live_app)
    assert await stored(con, trip["id"]) == len(fixes)
    dup_rows = await con.fetchval(
        "select count(*) from public.rejected_fixes where trip_id = $1 and reason = 'DUPLICATE'", UUID(trip["id"]))
    assert dup_rows == len(fixes)
