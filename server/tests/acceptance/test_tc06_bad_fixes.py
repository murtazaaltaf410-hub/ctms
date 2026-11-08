"""TC6 (T3, T4): an 80 m-accuracy fix and a fix implying >120 km/h are both rejected with
their reasons, the last good position is kept, and the next consistent fix is accepted."""

from __future__ import annotations

from uuid import UUID

from app.live.writer import get_writer
from tests.acceptance.sim_support import assert_server_verdicts, live_bus, plan


async def test_tc6_bad_accuracy_and_speed_spikes_rejected_last_good_kept(client, con, live_app, sim_trip):
    route, driver, trip, player = await sim_trip()
    fixes, events = plan(
        route.geom,
        player.start,
        speed_kmh=30,
        fix_every_s=3,
        interval_s=3,
        minutes=3,
        bad_accuracy_every=5,
        spike_every=7,
    )
    last_good = {}

    async def check(upload):
        bus = await live_bus(client, driver["headers"], trip["bus_id"])
        good = [f for f in upload.batch.fixes if f.kind == "good"]
        if good:
            last_good["fix"] = good[-1]
        # One fix per upload: after a rejected fix the bus stays at the last good position (T3).
        assert (bus["lat"], bus["lng"]) == (round(last_good["fix"].lat, 7), round(last_good["fix"].lng, 7))

    uploads = await player.play(events, after=check)
    assert_server_verdicts(uploads)

    bad = [f for f in fixes if f.kind != "good"]
    assert {f.kind for f in bad} == {"bad_accuracy", "spike"}
    # T4: the fix right after every spike is accepted (judged against the last good fix, not the spike).
    for spike in (f for f in fixes if f.kind == "spike"):
        nxt = next(f for f in fixes if f.seq == spike.seq + 1)
        if nxt.kind == "good":
            assert any(str(nxt.fix_id) in u.accepted for u in uploads)

    await get_writer(live_app).flush(live_app)
    rows = await con.fetch("select fix_id, reason from public.rejected_fixes where trip_id = $1", UUID(trip["id"]))
    assert {(r["fix_id"], r["reason"]) for r in rows} == {(f.fix_id, f.expected) for f in bad}
    stored = await con.fetchval("select count(*) from public.locations where trip_id = $1", UUID(trip["id"]))
    assert stored == sum(f.kind == "good" for f in fixes)


async def test_tc6_bad_fixes_inside_a_batch(client, live_app, sim_trip):
    """The same rules hold when good and bad fixes arrive together in one batch."""
    route, driver, trip, player = await sim_trip()
    fixes, events = plan(
        route.geom,
        player.start,
        speed_kmh=40,
        fix_every_s=2,
        interval_s=10,
        minutes=2,
        bad_accuracy_every=3,
        spike_every=4,
    )
    uploads = await player.play(events)
    assert all(len(u.batch.fixes) > 1 for u in uploads[1:])
    assert_server_verdicts(uploads)
    bus = await live_bus(client, driver["headers"], trip["bus_id"])
    newest_good = [f for f in fixes if f.kind == "good"][-1]
    assert (bus["lat"], bus["lng"]) == (round(newest_good.lat, 7), round(newest_good.lng, 7))
