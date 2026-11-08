"""Fix ingestion: TC6 (T3/T4), TC7 (N6), T6, T12, T13, T14, N5, OUT_OF_ORDER, limits."""

from __future__ import annotations

from contextlib import asynccontextmanager
from datetime import timedelta
from uuid import UUID, uuid4

import pytest

from app.errors import DbUnavailable
from app.live.hub import get_hub
from app.live.state import get_live
from app.live.writer import get_writer
from tests.conftest import bearer
from tests.tracking_support import FakeWS, along_fix, fix, point_at

pytest_plugins = ["tests.tracking_support"]


@pytest.fixture
async def trip_ctx(live_app, driver_with_bus, start_trip, fake_clock):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    return {"driver": driver, "trip": trip, "id": trip["id"], "t0": fake_clock.current}


async def live_buses(client, driver) -> list[dict]:
    resp = await client.get("/api/v1/buses/live", headers=driver["headers"])
    assert resp.status_code == 200, resp.text
    return resp.json()


async def test_t1_no_trip_no_bus(client, live_app, driver_with_bus, google_login):
    await driver_with_bus()
    student = await google_login()
    resp = await client.get("/api/v1/buses/live", headers=bearer(student["access_token"]))
    assert resp.status_code == 200 and resp.json() == []


async def test_accepted_fix_appears_live_and_is_broadcast(client, live_app, trip_ctx, post_fixes, hook_log):
    ws = FakeWS(live_app)
    get_hub(live_app).add(ws, uuid4(), uuid4())
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    f1 = along_fix(0, t0, speed=8.0, heading=10.0)
    body = await post_fixes(driver, trip_ctx["id"], [f1])
    assert body == {"accepted": [f1["fix_id"]], "rejected": []}
    [bus] = await live_buses(client, driver)
    assert bus["bus_id"] == trip_ctx["trip"]["bus_id"] and bus["trip_id"] == trip_ctx["id"]
    assert (bus["lat"], bus["lng"], bus["heading"]) == (f1["lat"], f1["lng"], 10.0)
    assert bus["state"] == "live" and bus["status"] == "on_time" and bus["last_fix_at"].endswith("Z")
    assert set(bus) >= {"label", "route_id", "speed", "note", "last_fix_at", "state"}
    msg = ws.sent[-1]
    assert msg["type"] == "bus_position" and msg["trip_id"] == trip_ctx["id"] and msg["lat"] == f1["lat"]
    assert msg["recorded_at"] == f1["recorded_at"]
    assert [e.trip_status for e in hook_log["fix"]] == ["on_time"]
    assert hook_log["fix"][0].bus_label == bus["label"] and hook_log["fix"][0].route_name == bus["route_name"]


async def test_tc6_bad_accuracy_and_speed_rejected_last_good_kept(client, con, live_app, trip_ctx, post_fixes):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    good = along_fix(100, t0)
    inaccurate = along_fix(110, t0 + timedelta(seconds=2), accuracy=80)
    # 200 km/h = 55.6 m/s: 556 m in 10 s.
    jump = along_fix(100 + 556, t0 + timedelta(seconds=10))
    body = await post_fixes(driver, trip_ctx["id"], [good, inaccurate, jump])
    assert body["accepted"] == [good["fix_id"]]
    assert {(r["fix_id"], r["reason"]) for r in body["rejected"]} == {
        (inaccurate["fix_id"], "ACCURACY_TOO_LOW"),
        (jump["fix_id"], "SPEED_IMPLAUSIBLE"),
    }
    [bus] = await live_buses(client, driver)
    assert (bus["lat"], bus["lng"]) == (good["lat"], good["lng"])
    # T4: the next consistent fix is accepted.
    nxt = along_fix(180, t0 + timedelta(seconds=12))
    assert (await post_fixes(driver, trip_ctx["id"], [nxt]))["accepted"] == [nxt["fix_id"]]
    await get_writer(live_app).flush(live_app)
    reasons = await con.fetch(
        "select reason from public.rejected_fixes where trip_id = $1 order by reason", trip_ctx["id"]
    )
    assert [r["reason"] for r in reasons] == ["ACCURACY_TOO_LOW", "SPEED_IMPLAUSIBLE"]
    assert await con.fetchval("select count(*) from public.locations where trip_id = $1", trip_ctx["id"]) == 2


async def test_tc7_same_fix_id_twice_stored_once(client, con, live_app, trip_ctx, post_fixes):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    f1 = along_fix(50, t0)
    assert (await post_fixes(driver, trip_ctx["id"], [f1]))["accepted"] == [f1["fix_id"]]
    # Retry before the writer flushed (still queued) and after (already in the DB).
    retry = await post_fixes(driver, trip_ctx["id"], [f1])
    assert retry == {"accepted": [], "rejected": [{"fix_id": f1["fix_id"], "reason": "DUPLICATE"}]}
    await get_writer(live_app).flush(live_app)
    get_live(live_app).by_trip(UUID(trip_ctx["id"])).seen_fix_ids.clear()  # force the DB check
    again = await post_fixes(driver, trip_ctx["id"], [f1, f1])
    assert [r["reason"] for r in again["rejected"]] == ["DUPLICATE", "DUPLICATE"]
    await get_writer(live_app).flush(live_app)
    assert await con.fetchval("select count(*) from public.locations where fix_id = $1", f1["fix_id"]) == 1


async def test_t6_t12_buffered_and_late_fixes_fill_history_only(client, con, live_app, trip_ctx, post_fixes, hook_log):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    # Buffered upload sent out of order: the newest fix wins the map, all are stored.
    batch = [along_fix(10 * i, t0 + timedelta(seconds=2 * i)) for i in range(6)]
    body = await post_fixes(driver, trip_ctx["id"], list(reversed(batch)))
    assert sorted(body["accepted"]) == sorted(f["fix_id"] for f in batch)
    [bus] = await live_buses(client, driver)
    assert bus["lat"] == batch[-1]["lat"] and bus["recorded_at"] == batch[-1]["recorded_at"]
    assert len(hook_log["fix"]) == 1  # one live update per batch
    # T12: a late fix (older than the live one) is accepted for history but not shown live.
    late = along_fix(25, t0 + timedelta(seconds=5))
    assert (await post_fixes(driver, trip_ctx["id"], [late]))["accepted"] == [late["fix_id"]]
    [bus] = await live_buses(client, driver)
    assert bus["lat"] == batch[-1]["lat"]
    assert len(hook_log["fix"]) == 1  # no emit for a late fix
    await get_writer(live_app).flush(live_app)
    assert await con.fetchval("select count(*) from public.locations where trip_id = $1", trip_ctx["id"]) == 7


async def test_out_of_order_before_trip_start_rejected(client, live_app, trip_ctx, post_fixes):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    old = along_fix(0, t0 - timedelta(minutes=10))
    now = along_fix(5, t0)
    body = await post_fixes(driver, trip_ctx["id"], [old, now])
    assert body["accepted"] == [now["fix_id"]]
    assert body["rejected"] == [{"fix_id": old["fix_id"], "reason": "OUT_OF_ORDER"}]


async def test_t13_phone_clock_ahead_is_flagged_and_server_time_used(
    client, live_app, trip_ctx, post_fixes, fake_clock
):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    ahead = along_fix(0, t0 + timedelta(minutes=10))
    await post_fixes(driver, trip_ctx["id"], [ahead])
    [bus] = await live_buses(client, driver)
    assert bus["clock_skew_s"] == pytest.approx(-600, abs=1)
    # Freshness follows the server receive time, not the (future) phone timestamp.
    assert bus["last_fix_at"] == fake_clock.current.isoformat().replace("+00:00", "Z")
    fake_clock.advance(31)
    [bus] = await live_buses(client, driver)
    assert bus["state"] == "stale"


async def test_t13_phone_clock_behind_still_accepts_fixes(client, live_app, trip_ctx, post_fixes):
    """Phone 10 min slow: the newest fix lags, so OUT_OF_ORDER's grace widens; skew is flagged."""
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    behind = along_fix(0, t0 - timedelta(minutes=10))
    assert (await post_fixes(driver, trip_ctx["id"], [behind]))["accepted"] == [behind["fix_id"]]
    [bus] = await live_buses(client, driver)
    assert bus["clock_skew_s"] == pytest.approx(600, abs=1)


async def test_t14_parked_with_fixes_is_stopped_not_offline(client, live_app, trip_ctx, post_fixes, fake_clock):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    for i in range(10):
        fake_clock.advance(15)
        await post_fixes(driver, trip_ctx["id"], [along_fix(200, t0 + timedelta(seconds=15 * (i + 1)), speed=0.0)])
    [bus] = await live_buses(client, driver)
    assert bus["state"] == "stopped" and bus["speed"] == 0.0


async def test_ema_speed_smooths_noise(client, live_app, trip_ctx, post_fixes):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    fixes = [
        along_fix(40 * i, t0 + timedelta(seconds=4 * i), speed=s) for i, s in enumerate([10, 10, 10, 10, 30, 10, 10])
    ]
    for f in fixes:
        await post_fixes(driver, trip_ctx["id"], [f])
    bus = get_live(live_app).by_trip(UUID(trip_ctx["id"]))
    assert 10 < bus.ema_speed_mps < 15  # one 30 m/s spike is damped


async def test_batch_limits_and_validation(client, live_app, trip_ctx, post_fixes):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    too_many = [along_fix(i, t0 + timedelta(seconds=i)) for i in range(21)]
    body = await post_fixes(driver, trip_ctx["id"], too_many, expect=400)
    assert body["error"]["code"] == "VALIDATION_ERROR"
    assert (await post_fixes(driver, trip_ctx["id"], [], expect=400))["error"]["code"] == "VALIDATION_ERROR"
    bad_lat = fix(91.0, 74.8, t0)
    assert (await post_fixes(driver, trip_ctx["id"], [bad_lat], expect=400))["error"]["code"] == "VALIDATION_ERROR"
    ok = [along_fix(i, t0 + timedelta(seconds=i)) for i in range(20)]
    assert len((await post_fixes(driver, trip_ctx["id"], ok))["accepted"]) == 20


async def test_unknown_trip_and_missing_token(client, live_app, trip_ctx, post_fixes):
    t0 = trip_ctx["t0"]
    resp = await client.post(
        f"/api/v1/trips/{uuid4()}/locations", json={"fixes": [along_fix(0, t0)]}, headers=trip_ctx["driver"]["headers"]
    )
    assert resp.status_code == 404
    resp = await client.post(f"/api/v1/trips/{trip_ctx['id']}/locations", json={"fixes": [along_fix(0, t0)]})
    assert resp.status_code == 401


async def test_n5_db_down_live_continues_and_writes_queue(client, con, live_app, trip_ctx, post_fixes):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    f1 = along_fix(0, t0)
    await post_fixes(driver, trip_ctx["id"], [f1])
    working = live_app.state.live_conn_provider

    @asynccontextmanager
    async def db_down():
        raise DbUnavailable()
        yield  # pragma: no cover

    live_app.state.live_conn_provider = db_down
    f2, f3 = along_fix(30, t0 + timedelta(seconds=3)), along_fix(60, t0 + timedelta(seconds=6))
    body = await post_fixes(driver, trip_ctx["id"], [f2, f3])
    assert body["accepted"] == [f2["fix_id"], f3["fix_id"]]
    # Duplicates still detected from memory while the DB is down.
    assert (await post_fixes(driver, trip_ctx["id"], [f3]))["rejected"][0]["reason"] == "DUPLICATE"
    assert get_live(live_app).by_trip(UUID(trip_ctx["id"])).lat == f3["lat"]
    writer = get_writer(live_app)
    assert await writer.flush(live_app) == 0 and writer.last_error is not None
    assert writer.pending >= 3  # f1..f3 still queued (plus progress)
    # Another driver's trip cannot be written through the offline path.
    other_trip_fix = await client.post(
        f"/api/v1/trips/{uuid4()}/locations", json={"fixes": [along_fix(0, t0)]}, headers=driver["headers"]
    )
    assert other_trip_fix.status_code == 503
    # DB back: the queue drains in one flush.
    live_app.state.live_conn_provider = working
    assert await writer.flush(live_app) > 0 and writer.pending == 0
    stored = await con.fetch(
        "select fix_id from public.locations where trip_id = $1 order by recorded_at", trip_ctx["id"]
    )
    assert [str(r["fix_id"]) for r in stored] == [f1["fix_id"], f2["fix_id"], f3["fix_id"]]
    assert await con.fetchval("select last_fix_at is not null from public.trips where id = $1", trip_ctx["id"])


async def test_n5_writer_queue_is_bounded(live_app):
    from datetime import UTC, datetime

    from app.live.writer import RejectedRow, Writer

    writer = Writer(max_rows=3)
    for _ in range(5):
        writer.queue_rejection(RejectedRow(uuid4(), uuid4(), "DUPLICATE", datetime.now(UTC)))
    assert len(writer.rows) == 3 and writer.dropped == 2


async def test_n5_revoked_session_refused_while_db_down(client, live_app, trip_ctx, post_fixes, driver_login):
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    await post_fixes(driver, trip_ctx["id"], [along_fix(0, t0)])
    await driver_login(driver["phone"])  # second device: first session revoked (SESSIONS_REVOKED)

    @asynccontextmanager
    async def db_down():
        raise DbUnavailable()
        yield  # pragma: no cover

    live_app.state.live_conn_provider = db_down
    resp = await client.post(
        f"/api/v1/trips/{trip_ctx['id']}/locations",
        json={"fixes": [along_fix(10, t0 + timedelta(seconds=2))]},
        headers=driver["headers"],
    )
    assert resp.status_code == 401


async def test_downsampling_keeps_live_but_thins_history(client, con, live_app, trip_ctx, post_fixes):
    await con.execute("update public.settings set value = '10' where key = 'history_downsample_s'")
    await live_app.state.settings_store.refresh(con)
    t0, driver = trip_ctx["t0"], trip_ctx["driver"]
    for i in range(6):  # every 4 s for 20 s -> stored at 0 and 12 s only
        await post_fixes(driver, trip_ctx["id"], [along_fix(30 * i, t0 + timedelta(seconds=4 * i))])
    await get_writer(live_app).flush(live_app)
    assert await con.fetchval("select count(*) from public.locations where trip_id = $1", trip_ctx["id"]) == 2
    assert get_live(live_app).by_trip(UUID(trip_ctx["id"])).lat == point_at(150)[0]
