"""T2 auto-close (time-mocked) and the retention purge."""

from __future__ import annotations

from datetime import timedelta
from uuid import UUID, uuid4

from app.jobs import registered_jobs
from app.jobs.retention import retention_tick
from app.jobs.trips import auto_close_tick
from app.live.hub import get_hub
from app.live.state import get_live
from app.live.writer import get_writer
from tests.tracking_support import FakeWS, along_fix

pytest_plugins = ["tests.tracking_support"]


def test_jobs_registered():
    names = {job.name for job in registered_jobs()}
    assert {"live_db_writer", "trip_auto_close", "retention"} <= names


async def test_t2_auto_close_after_15_minutes_silence(client, con, live_app, driver_with_bus, start_trip,
                                                     post_fixes, fake_clock, hook_log):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    trip_id = UUID(trip["id"])
    await post_fixes(driver, trip["id"], [along_fix(0, fake_clock.current), along_fix(
        50, fake_clock.current + timedelta(seconds=5))])
    last_fix_at = fake_clock.current
    await get_writer(live_app).flush(live_app)
    ws = FakeWS(live_app)
    get_hub(live_app).add(ws, uuid4(), uuid4())
    fake_clock.advance(14 * 60 + 59)
    assert await auto_close_tick(live_app) == 0
    fake_clock.advance(1)
    assert await auto_close_tick(live_app) == 1
    row = await con.fetchrow("select ended_at, closed_by, distance_m from public.trips where id = $1", trip_id)
    assert row["closed_by"] == "auto" and row["ended_at"] == last_fix_at and row["distance_m"] > 40
    assert ws.sent == [{"type": "trip_ended", "bus_id": trip["bus_id"], "trip_id": trip["id"]}]
    assert hook_log["trip"][-1].kind == "ended"
    assert get_live(live_app).by_trip(trip_id) is None
    assert (await client.get("/api/v1/buses/live", headers=driver["headers"])).json() == []
    assert await auto_close_tick(live_app) == 0   # idempotent


async def test_t2_trip_without_any_fix_closes_15_min_after_start(con, live_app, driver_with_bus, start_trip,
                                                                 fake_clock):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    fake_clock.advance(15 * 60)
    assert await auto_close_tick(live_app) == 1
    row = await con.fetchrow("select ended_at, started_at, closed_by from public.trips where id = $1",
                             UUID(trip["id"]))
    assert row["closed_by"] == "auto" and row["ended_at"] == row["started_at"]


async def test_fresh_trip_not_closed(live_app, driver_with_bus, start_trip, post_fixes, fake_clock):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    fake_clock.advance(14 * 60)
    await post_fixes(driver, trip["id"], [along_fix(0, fake_clock.current)])
    fake_clock.advance(5 * 60)   # 19 min after start but only 5 min since the last fix
    assert await auto_close_tick(live_app) == 0


async def test_retention_purges_old_rows_only(con, live_app, create_user, driver_with_bus, start_trip, fake_clock):
    now = fake_clock.current
    driver = await driver_with_bus()
    trip_id = UUID((await start_trip(driver))["id"])
    for days, fid in ((91, uuid4()), (1, uuid4())):
        await con.execute(
            "insert into public.locations (trip_id, fix_id, lat, lng, recorded_at, received_at) "
            "values ($1, $2, 34.1, 74.8, $3, $3)", trip_id, fid, now - timedelta(days=days))
        await con.execute("insert into public.rejected_fixes (trip_id, fix_id, reason, received_at) "
                          "values ($1, $2, 'DUPLICATE', $3)", trip_id, fid, now - timedelta(days=days))
    old_student = await create_user("student", email="old@uok.edu.in")
    new_student = await create_user("student", email="new@uok.edu.in")
    for uid, age in ((old_student, 301), (new_student, 60)):
        await con.execute("insert into public.student_locations (user_id, lat, lng, accuracy_m, recorded_at) "
                          "values ($1, 34.1, 74.8, 10, $2)", uid, now - timedelta(seconds=age))
    await con.execute("insert into public.sessions (user_id, refresh_hash, expires_at) values ($1, $2, $3)",
                      old_student, "expired-hash-p3", now - timedelta(seconds=1))
    await con.execute("insert into public.phone_otp_requests (phone, requested_at) values ($1, $2), ($1, $3)",
                      "+919800000077", now - timedelta(days=2), now - timedelta(hours=1))
    counts = await retention_tick(live_app)
    assert counts["locations"] >= 1 and counts["rejected_fixes"] >= 1
    assert counts["student_locations"] >= 1 and counts["sessions"] >= 1 and counts["phone_otp_requests"] >= 1
    assert await con.fetchval("select count(*) from public.locations where trip_id = $1", trip_id) == 1
    assert await con.fetchval("select count(*) from public.rejected_fixes where trip_id = $1", trip_id) == 1
    remaining = {r["user_id"] for r in await con.fetch("select user_id from public.student_locations")}
    assert new_student in remaining and old_student not in remaining
    assert await con.fetchval("select count(*) from public.sessions where refresh_hash = 'expired-hash-p3'") == 0
    assert await con.fetchval(
        "select count(*) from public.phone_otp_requests where phone = '+919800000077'") == 1
    # The driver's own (unexpired) session survives.
    assert await con.fetchval("select count(*) from public.sessions where user_id = $1", driver["driver_id"]) >= 1
