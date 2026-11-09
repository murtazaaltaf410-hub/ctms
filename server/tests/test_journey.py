"""Phase 6 (ADR-10): Start Journey push, moved_at, arrival geofence, driver button, reports, settings.

Tests X8 (journey push, moved_at, arrival close) and X9 (campus settings, reports/CSV, auto-close).
"""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

import csv
import io
from datetime import timedelta
from uuid import UUID, uuid4

from app.jobs.trips import auto_close_tick
from app.live.hub import get_hub
from app.live.state import get_live
from app.live.writer import get_writer
from app.modules.trips import service as trips_service
from app.push import get_push
from tests.admin_helpers import admin  # noqa: F401
from tests.alerts_support import push  # noqa: F401
from tests.tracking_support import FakeWS, along_fix, point_at

pytest_plugins = ["tests.tracking_support"]

API = "/api/v1"


async def set_setting(app, con, key: str, value) -> None:
    await con.execute(
        "insert into public.settings (key, value) values ($1, $2) "
        "on conflict (key) do update set value = excluded.value",
        key, value,
    )
    await app.state.settings_store.refresh(con)


async def set_campus(app, con, along_m: float) -> None:
    """Pin the campus at `along_m` metres along the test route."""
    lat, lng = point_at(along_m)
    await set_setting(app, con, "campus_lat", lat)
    await set_setting(app, con, "campus_lng", lng)


async def trip_row(con, trip_id: str):
    return await con.fetchrow(
        "select closed_by, ended_at, moved_at, arrived_at, started_at from public.trips where id = $1", UUID(trip_id))


def watch_ws(app) -> FakeWS:
    ws = FakeWS(app)
    get_hub(app).add(ws, uuid4(), uuid4())
    return ws


# ---------------------------------------------------------------- journey push


async def _student(con, create_user, n: int, *, bus_id, status: str = "approved", token: bool = True) -> UUID:
    user_id = await create_user("student", name=f"S{n}", email=f"x8-s{n}@uok.edu.in", profile=status, bus_id=bus_id)
    if token:
        await con.execute("insert into public.push_tokens (user_id, token, platform) values ($1, $2, 'android')",
                          user_id, f"x8-tok-{n}")
    return user_id


async def test_x8_journey_push_goes_to_approved_students_of_that_bus_only(
    app, client, con, live_app, push, create_user, driver_with_bus, start_trip
):
    mine = await driver_with_bus(label="Bus Mine")
    other = await driver_with_bus(label="Bus Other")
    await _student(con, create_user, 1, bus_id=mine["bus_id"])
    await _student(con, create_user, 2, bus_id=mine["bus_id"])
    await _student(con, create_user, 3, bus_id=other["bus_id"])           # another bus
    await _student(con, create_user, 4, bus_id=None, status="pending")     # not approved
    await _student(con, create_user, 5, bus_id=None, status="rejected")
    trip = await start_trip(mine)
    await get_push(app).drain(app)
    assert sorted(m.token for m in push.sent) == ["x8-tok-1", "x8-tok-2"]
    msg = push.sent[0]
    assert msg.title == "Bus started its journey" and msg.tag == "journey_started"
    assert msg.body == f"Bus Mine ({mine['route']['name']}) has started its journey to campus"
    assert msg.data == {"type": "journey_started", "trip_id": trip["id"], "bus_id": str(mine["bus_id"]),
                        "direction": "to_campus"}


async def test_x8_journey_push_body_follows_direction(app, live_app, con, push, create_user, driver_with_bus,
                                                      start_trip):
    driver = await driver_with_bus(label="Bus E")
    await _student(con, create_user, 1, bus_id=driver["bus_id"])
    await start_trip(driver, {"direction": "from_campus"})
    await get_push(app).drain(app)
    assert push.sent[0].body.endswith("has started its journey from campus")
    assert push.sent[0].data["direction"] == "from_campus"


async def test_x8_journey_push_with_zero_recipients_is_a_noop(app, live_app, push, driver_with_bus, start_trip):
    driver = await driver_with_bus()
    await start_trip(driver)
    assert get_push(app).queue.empty()
    await get_push(app).drain(app)
    assert push.sent == []


async def test_x8_push_failure_never_breaks_trip_start(
    app, client, live_app, con, push, create_user, driver_with_bus, monkeypatch
):
    driver = await driver_with_bus()
    await _student(con, create_user, 1, bus_id=driver["bus_id"])

    def boom(_app):
        raise RuntimeError("push is down")

    monkeypatch.setattr(trips_service, "get_push", boom)
    resp = await client.post(f"{API}/trips/start", json={}, headers=driver["headers"])
    assert resp.status_code == 201, resp.text
    assert (await client.get(f"{API}/trips/active", headers=driver["headers"])).json()["id"] == resp.json()["id"]


# ------------------------------------------------------------------- moved_at


async def test_x8_moved_at_is_set_once_and_only_after_speed_exceeds_threshold(
    app, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    t0 = fake_clock.current
    assert trip["moved_at"] is None and trip["arrived_at"] is None
    bus = get_live(app).by_trip(UUID(trip["id"]))
    # At or below moved_speed_mps (1.5): not moved.
    slow = [along_fix(0, t0, speed=0.0), along_fix(1, t0 + timedelta(seconds=5), speed=1.5)]
    await post_fixes(driver, trip["id"], slow)
    assert bus.moved_at is None
    await get_writer(app).flush(app)
    assert (await trip_row(con, trip["id"]))["moved_at"] is None
    first = t0 + timedelta(seconds=10)
    fake_clock.advance(10)
    await post_fixes(driver, trip["id"], [along_fix(20, first, speed=6.0)])
    assert bus.moved_at == first
    fake_clock.advance(10)
    await post_fixes(driver, trip["id"], [along_fix(80, t0 + timedelta(seconds=20), speed=8.0)])
    assert bus.moved_at == first                      # fires once
    await get_writer(app).flush(app)
    assert (await trip_row(con, trip["id"]))["moved_at"] == first


async def test_x8_restart_rebuild_keeps_moved_at(
    app, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    from app.modules.trips.service import rebuild_live

    driver = await driver_with_bus()
    trip = await start_trip(driver)
    t0 = fake_clock.current
    await post_fixes(driver, trip["id"], [along_fix(0, t0, speed=5.0)])
    await get_writer(app).flush(app)
    get_live(app).buses.clear()                       # simulated restart
    assert await rebuild_live(app) == 1
    bus = get_live(app).by_trip(UUID(trip["id"]))
    assert bus.moved_at == t0 and not bus.arriving


# -------------------------------------------------------------------- arrival


async def test_x8_to_campus_arrival_ends_trip_with_closed_by_arrival(
    app, client, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    await set_campus(app, con, 1100)
    trip = await start_trip(driver)
    ws = watch_ws(app)
    t0 = fake_clock.current
    steps = [(0, 0), (300, 30), (600, 60), (900, 90)]           # 900 m is 200 m from campus: outside 150 m
    await post_fixes(driver, trip["id"], [along_fix(a, t0 + timedelta(seconds=s), speed=10.0) for a, s in steps])
    fake_clock.advance(90)
    assert (await trip_row(con, trip["id"]))["ended_at"] is None
    fake_clock.advance(30)
    arrival_at = t0 + timedelta(seconds=120)
    out = await post_fixes(driver, trip["id"], [along_fix(1000, arrival_at, speed=10.0)])
    assert len(out["accepted"]) == 1
    row = await trip_row(con, trip["id"])
    assert row["closed_by"] == "arrival" and row["ended_at"] == arrival_at and row["arrived_at"] == arrival_at
    assert row["moved_at"] == t0
    assert [m for m in ws.sent if m["type"] == "trip_ended"] == [
        {"type": "trip_ended", "bus_id": str(driver["bus_id"]), "trip_id": trip["id"]}]
    assert get_live(app).by_trip(UUID(trip["id"])) is None
    # Tracking stopped: further fixes are 404, and the driver's button is a safe retry.
    assert (await client.post(f"{API}/trips/{trip['id']}/locations", json={"fixes": [along_fix(1050, arrival_at)]},
                              headers=driver["headers"])).status_code == 404
    again = await client.post(f"{API}/trips/{trip['id']}/end", headers=driver["headers"])
    assert again.status_code == 200 and again.json()["closed_by"] == "arrival"
    summary = again.json()
    assert summary["arrived_at"].endswith("Z") and summary["moved_at"].endswith("Z")


async def test_x8_no_early_end_at_the_start_point_min_time_and_moved_guard(
    app, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    await set_campus(app, con, 0)                               # campus right at the start point
    trip = await start_trip(driver)
    t0 = fake_clock.current

    def at(s: float):
        return t0 + timedelta(seconds=s)

    # Inside the zone from the first fix but never moved and only seconds in: no end.
    await post_fixes(driver, trip["id"], [along_fix(0, at(0), speed=0.0)])
    # Moved, still inside the zone, but before arrival_min_trip_s (120 s): no end.
    fake_clock.advance(10)
    await post_fixes(driver, trip["id"], [along_fix(50, at(10), speed=5.0)])
    assert (await trip_row(con, trip["id"]))["ended_at"] is None
    # After the minimum time and moved: ends.
    fake_clock.advance(120)
    await post_fixes(driver, trip["id"], [along_fix(60, at(130), speed=1.0)])
    row = await trip_row(con, trip["id"])
    assert row["closed_by"] == "arrival" and row["moved_at"] == t0 + timedelta(seconds=10)


async def test_x8_no_end_before_moved_even_after_min_time(
    app, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    await set_campus(app, con, 0)
    trip = await start_trip(driver)
    t0 = fake_clock.current
    fake_clock.advance(300)
    await post_fixes(driver, trip["id"], [along_fix(0, t0 + timedelta(seconds=300), speed=0.4)])
    row = await trip_row(con, trip["id"])
    assert row["ended_at"] is None and row["moved_at"] is None


async def test_x8_geofence_is_off_when_campus_is_unset(
    app, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    assert app.state.settings_store.get_cached("campus_lat") is None
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    t0 = fake_clock.current
    fake_clock.advance(600)
    await post_fixes(driver, trip["id"], [along_fix(0, t0 + timedelta(seconds=300), speed=9.0),
                                          along_fix(1100, t0 + timedelta(seconds=600), speed=9.0)])
    await get_writer(app).flush(app)
    row = await trip_row(con, trip["id"])
    assert row["ended_at"] is None and row["moved_at"] is not None
    live_bus = get_live(app).by_trip(UUID(trip["id"]))
    assert trips_service.arrival_target(app, live_bus) is None


async def test_x8_from_campus_ends_at_the_travel_order_last_stop(
    app, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()                            # stops at 0 m (seq 1), 555 m, 1110 m (seq 3)
    await set_campus(app, con, 1100)                            # to_campus geofence must not matter here
    trip = await start_trip(driver, {"direction": "from_campus"})
    t0 = fake_clock.current
    ws = watch_ws(app)
    bus = get_live(app).by_trip(UUID(trip["id"]))
    lat0, lng0 = point_at(0)
    assert bus.last_stop == (lat0, lng0)                        # lowest sequence = last stop of the travel order
    # Starting at 1100 m is inside 150 m of the highest-sequence stop (the departure): no end there.
    steps = [(1100, 0), (800, 30), (500, 60), (200, 90)]        # 200 m from the last stop: outside
    await post_fixes(driver, trip["id"], [along_fix(a, t0 + timedelta(seconds=s), speed=10.0) for a, s in steps])
    fake_clock.advance(120)
    assert (await trip_row(con, trip["id"]))["ended_at"] is None
    end = t0 + timedelta(seconds=120)
    await post_fixes(driver, trip["id"], [along_fix(100, end, speed=10.0)])
    row = await trip_row(con, trip["id"])
    assert row["closed_by"] == "arrival" and row["arrived_at"] == end and row["ended_at"] == end
    assert any(m["type"] == "trip_ended" for m in ws.sent)


async def test_x8_driver_button_still_works_and_records_arrived_at_only_inside_the_zone(
    app, client, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    inside = await driver_with_bus()
    outside = await driver_with_bus()
    await set_campus(app, con, 1100)
    t0 = fake_clock.current
    trip_in = await start_trip(inside)
    trip_out = await start_trip(outside)
    # 10 s in (before arrival_min_trip_s) at 50 m from campus: the geofence waits, the button works.
    fix_at = t0 + timedelta(seconds=10)
    fake_clock.advance(10)
    await post_fixes(inside, trip_in["id"], [along_fix(1050, fix_at, speed=10.0)])
    await post_fixes(outside, trip_out["id"], [along_fix(300, fix_at, speed=10.0)])
    assert (await trip_row(con, trip_in["id"]))["ended_at"] is None
    resp = await client.post(f"{API}/trips/{trip_in['id']}/end", headers=inside["headers"])
    assert resp.status_code == 200 and resp.json()["closed_by"] == "driver"
    row = await trip_row(con, trip_in["id"])
    assert row["closed_by"] == "driver" and row["arrived_at"] == fix_at
    resp = await client.post(f"{API}/trips/{trip_out['id']}/end", headers=outside["headers"])
    assert resp.status_code == 200 and resp.json()["closed_by"] == "driver" and resp.json()["arrived_at"] is None
    assert (await trip_row(con, trip_out["id"]))["arrived_at"] is None


async def test_x8_button_and_geofence_race_yields_exactly_one_end(
    app, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    await set_campus(app, con, 1100)
    trip = await start_trip(driver)
    trip_id = UUID(trip["id"])
    ws = watch_ws(app)
    t0 = fake_clock.current
    fake_clock.advance(130)
    at = t0 + timedelta(seconds=130)
    await post_fixes(driver, trip["id"], [along_fix(0, t0, speed=8.0), along_fix(1050, at, speed=8.0)])
    assert (await trip_row(con, trip["id"]))["closed_by"] == "arrival"
    # The button arrives after the geofence closed the trip (and the reverse order): the second close is a no-op.
    second = await trips_service.end_trip(
        app, con, trip_id, closed_by="driver", ended_at=at, actor_id=driver["driver_id"])
    assert second.closed_by == "arrival"
    assert len([m for m in ws.sent if m["type"] == "trip_ended"]) == 1
    assert await con.fetchval("select count(*) from public.audit_log where action = 'trip.end' and target_id = $1",
                              str(trip_id)) == 1


async def test_x8_driver_button_first_then_late_fix_is_a_clean_404(
    app, client, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    await set_campus(app, con, 1100)
    trip = await start_trip(driver)
    t0 = fake_clock.current
    await post_fixes(driver, trip["id"], [along_fix(1050, t0, speed=8.0)])
    ended = await client.post(f"{API}/trips/{trip['id']}/end", headers=driver["headers"])
    assert ended.json()["closed_by"] == "driver"
    resp = await client.post(f"{API}/trips/{trip['id']}/locations", json={"fixes": [along_fix(1060, t0)]},
                             headers=driver["headers"])
    assert resp.status_code == 404
    assert (await trip_row(con, trip["id"]))["closed_by"] == "driver"


# ----------------------------------------------- auto-close, reports, settings


async def test_x9_auto_close_is_unaffected_by_arrival_fields(
    app, live_app, con, driver_with_bus, start_trip, post_fixes, fake_clock
):
    driver = await driver_with_bus()
    trip = await start_trip(driver)
    t0 = fake_clock.current
    await post_fixes(driver, trip["id"], [along_fix(0, t0, speed=6.0)])
    fake_clock.advance(15 * 60)
    assert await auto_close_tick(app) == 1
    row = await trip_row(con, trip["id"])
    assert row["closed_by"] == "auto" and row["arrived_at"] is None and row["moved_at"] == t0


async def test_x9_reports_and_csv_carry_direction_moved_and_arrived(
    app, client, live_app, con, admin, driver_with_bus, start_trip, post_fixes, fake_clock
):
    _, headers = await admin()
    driver = await driver_with_bus()
    await set_campus(app, con, 1100)
    trip = await start_trip(driver)
    t0 = fake_clock.current
    fake_clock.advance(130)
    at = t0 + timedelta(seconds=130)
    await post_fixes(driver, trip["id"], [along_fix(0, t0, speed=8.0), along_fix(1050, at, speed=8.0)])
    page = (await client.get(f"{API}/admin/trips", headers=headers)).json()
    item = next(i for i in page["items"] if i["id"] == trip["id"])
    assert item["direction"] == "to_campus" and item["closed_by"] == "arrival"
    assert item["moved_at"].endswith("Z") and item["arrived_at"].endswith("Z")
    resp = await client.get(f"{API}/admin/reports/trips.csv", headers=headers)
    rows = list(csv.reader(io.StringIO(resp.text)))
    record = dict(zip(rows[0], next(r for r in rows[1:] if r[0] == trip["id"]), strict=True))
    assert record["direction"] == "to_campus" and record["closed_by"] == "arrival"
    assert record["moved_at"].endswith("Z") and record["arrived_at"].endswith("Z")


async def test_x9_settings_read_write_and_validation(app, client, con, admin):
    _, headers = await admin()
    url = f"{API}/admin/settings"
    body = (await client.get(url, headers=headers)).json()
    assert body["campus_lat"] is None and body["campus_lng"] is None
    assert body["campus_radius_m"] == 150 and body["last_stop_radius_m"] == 150 and body["alert_radius_m"] == 500
    put = await client.put(url, json={"campus_lat": 34.131, "campus_lng": 74.837, "campus_radius_m": 200,
                                      "last_stop_radius_m": 120}, headers=headers)
    assert put.status_code == 200, put.text
    assert put.json() == {"alert_radius_m": 500, "campus_lat": 34.131, "campus_lng": 74.837,
                          "campus_radius_m": 200, "last_stop_radius_m": 120}
    store = app.state.settings_store
    assert store.get_cached("campus_lat") == 34.131 and store.get_cached("campus_radius_m") == 200
    assert await con.fetchval("select count(*) from public.audit_log where action = 'settings.update'") == 4
    public = (await client.get(f"{API}/config")).json()
    assert public["campus_lat"] == 34.131 and public["campus_lng"] == 74.837 and public["campus_radius_m"] == 200
    # Clear the pin: both null, geofence off again.
    cleared = await client.put(url, json={"campus_lat": None, "campus_lng": None}, headers=headers)
    assert cleared.status_code == 200 and cleared.json()["campus_lat"] is None
    assert store.get_cached("campus_lat") is None
    for bad in ({"campus_lat": 91, "campus_lng": 74}, {"campus_lat": 34, "campus_lng": 181},
                {"campus_lat": 34.1}, {"campus_lat": None, "campus_lng": 74.8},
                {"campus_radius_m": 19}, {"campus_radius_m": 5001}, {"last_stop_radius_m": 10},
                {"last_stop_radius_m": 99999}, {"campus_radius_m": None}, {"campus_radius_m": "wide"}, {}):
        resp = await client.put(url, json=bad, headers=headers)
        assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR", bad
    assert (await client.put(url, json={"campus_radius_m": 20, "last_stop_radius_m": 5000},
                             headers=headers)).status_code == 200
