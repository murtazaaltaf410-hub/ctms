"""Trip history and reports (PRD A6): TC18 (three trips -> distance and times), path replay, summary, CSV."""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

import csv
import io
from datetime import UTC, datetime, timedelta

import pytest

from app.modules.routes.geo import cumulative_distances
from tests.admin_helpers import CAMPUS, admin, err, insert_path, insert_route, insert_trip  # noqa: F401

T0 = datetime(2026, 11, 4, 3, 0, tzinfo=UTC)  # 08:30 IST


@pytest.fixture
async def three_trips(con, create_user, create_bus):
    """Three simulated trips on two buses. Each trip's distance_m is the simulator's path length."""
    rid = await insert_route(con)
    d1 = await create_user("driver", name="Driver One", phone="+919000000401")
    d2 = await create_user("driver", name="Driver Two", phone="+919000000402")
    b1 = await create_bus(d1, label="Bus 1", plate="JK01R1")
    b2 = await create_bus(d2, label="Bus 2", plate="JK01R2")
    path = CAMPUS
    length = cumulative_distances(path)[-1]
    specs = [  # (bus, driver, start offset, duration, laps, closed_by)
        (b1, d1, timedelta(0), timedelta(minutes=12), 1, "driver"),
        (b1, d1, timedelta(hours=2), timedelta(minutes=25), 2, "auto"),
        (b2, d2, timedelta(hours=1), timedelta(minutes=10), 1, "driver"),
    ]
    trips = []
    for bus, driver, offset, duration, laps, closed_by in specs:
        points = (path + path[::-1][1:]) if laps == 2 else path
        distance = cumulative_distances(points)[-1]
        start = T0 + offset
        tid = await insert_trip(
            con,
            bus_id=bus,
            driver_id=driver,
            route_id=rid,
            started_at=start,
            ended_at=start + duration,
            closed_by=closed_by,
            distance_m=distance,
            last_fix_at=start + duration,
        )
        await insert_path(con, tid, points, start)
        trips.append(
            {
                "id": tid,
                "bus": bus,
                "distance": distance,
                "duration": duration.total_seconds(),
                "closed_by": closed_by,
                "points": points,
            }
        )
    return {"route": rid, "buses": (b1, b2), "trips": trips, "length": length}


async def test_tc18_trip_list_distance_and_times(client, admin, three_trips):
    _, headers = await admin()
    resp = await client.get("/api/v1/admin/trips", headers=headers)
    assert resp.status_code == 200
    items = resp.json()["items"]
    assert resp.json()["next_cursor"] is None
    by_id = {str(t["id"]): t for t in three_trips["trips"]}
    assert [i["started_at"] for i in items] == sorted((i["started_at"] for i in items), reverse=True)
    for item in items:
        sim = by_id[item["id"]]
        assert item["distance_m"] == pytest.approx(sim["distance"], rel=0.02)
        assert item["duration_s"] == pytest.approx(sim["duration"], rel=0.02)
        assert item["avg_speed"] == pytest.approx(sim["distance"] / sim["duration"], rel=0.02)
        assert item["closed_by"] == sim["closed_by"]
        assert item["driver_name"] in ("Driver One", "Driver Two") and item["route_name"] == "Route T"
        assert item["started_at"].endswith("Z") and item["ended_at"].endswith("Z")
    assert {i["closed_by"] for i in items} == {"driver", "auto"}


async def test_trip_filters_and_cursor(client, admin, three_trips):
    _, headers = await admin()
    b1, _ = three_trips["buses"]
    resp = await client.get("/api/v1/admin/trips", params={"bus_id": str(b1)}, headers=headers)
    assert len(resp.json()["items"]) == 2
    window = {"from": "2026-11-04T03:30:00Z", "to": "2026-11-04T04:30:00Z"}
    items = (await client.get("/api/v1/admin/trips", params=window, headers=headers)).json()["items"]
    assert [i["started_at"] for i in items] == ["2026-11-04T04:00:00Z"]
    page1 = (await client.get("/api/v1/admin/trips", params={"limit": 2}, headers=headers)).json()
    page2 = (
        await client.get("/api/v1/admin/trips", params={"limit": 2, "cursor": page1["next_cursor"]}, headers=headers)
    ).json()
    ids = [i["id"] for i in page1["items"] + page2["items"]]
    assert len(ids) == len(set(ids)) == 3 and page2["next_cursor"] is None
    resp = await client.get(
        "/api/v1/admin/trips", params={"from": "2026-11-05T00:00:00Z", "to": "2026-11-04T00:00:00Z"}, headers=headers
    )
    assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR"


async def test_trip_path_is_ordered(client, admin, con, three_trips):
    _, headers = await admin()
    trip = three_trips["trips"][0]
    # A late-arriving (out-of-order) fix is still replayed in recorded order.
    await con.execute(
        """insert into public.locations (trip_id, fix_id, lat, lng, recorded_at)
                         values ($1, gen_random_uuid(), 34.1255, 74.8345, $2)""",
        trip["id"],
        T0 - timedelta(seconds=5),
    )
    resp = await client.get(f"/api/v1/admin/trips/{trip['id']}/path", headers=headers)
    positions = resp.json()["positions"]
    assert resp.json()["trip_id"] == str(trip["id"])
    assert [(p["lat"], p["lng"]) for p in positions] == [(34.1255, 74.8345), *trip["points"]]
    assert [p["recorded_at"] for p in positions] == sorted(p["recorded_at"] for p in positions)
    assert positions[1]["speed"] == 6 and positions[1]["accuracy"] == 8
    resp = await client.get("/api/v1/admin/trips/00000000-0000-4000-8000-000000000000/path", headers=headers)
    assert resp.status_code == 404


async def test_summary_totals_per_bus(client, admin, three_trips):
    _, headers = await admin()
    trips = three_trips["trips"]
    resp = await client.get(
        "/api/v1/admin/reports/summary",
        params={"from": "2026-11-04T00:00:00Z", "to": "2026-11-05T00:00:00Z"},
        headers=headers,
    )
    body = resp.json()
    assert body["from"] == "2026-11-04T00:00:00Z" and body["to"] == "2026-11-05T00:00:00Z"
    bus1, bus2 = body["buses"]
    assert (bus1["label"], bus1["trips"], bus2["label"], bus2["trips"]) == ("Bus 1", 2, "Bus 2", 1)
    assert bus1["distance_m"] == pytest.approx(trips[0]["distance"] + trips[1]["distance"], abs=0.2)
    assert bus1["running_time_s"] == pytest.approx(12 * 60 + 25 * 60)
    assert body["totals"]["trips"] == 3
    assert body["totals"]["running_time_s"] == pytest.approx(47 * 60)
    empty = (
        await client.get("/api/v1/admin/reports/summary", params={"from": "2027-01-01T00:00:00Z"}, headers=headers)
    ).json()
    assert empty["buses"] == [] and empty["totals"] == {"trips": 0, "distance_m": 0, "running_time_s": 0}


async def test_trip_report_csv_export(client, admin, con, three_trips):
    _, headers = await admin()
    await con.execute("update public.users set name = '=HYPERLINK(\"x\")' where name = 'Driver Two'")
    resp = await client.get("/api/v1/admin/reports/trips.csv", headers=headers)
    assert resp.status_code == 200 and resp.headers["content-type"].startswith("text/csv")
    assert "attachment" in resp.headers["content-disposition"]
    rows = list(csv.reader(io.StringIO(resp.text)))
    assert rows[0] == [
        "trip_id",
        "started_at",
        "ended_at",
        "bus_label",
        "driver_name",
        "route_name",
        "type",
        "status",
        "closed_by",
        "distance_m",
        "duration_s",
        "avg_speed_mps",
        "avg_speed_kmh",
    ]
    assert len(rows) == 4
    by_id = {str(t["id"]): t for t in three_trips["trips"]}
    for row in rows[1:]:
        record = dict(zip(rows[0], row, strict=True))
        sim = by_id[record["trip_id"]]
        assert float(record["distance_m"]) == pytest.approx(sim["distance"], rel=0.02)
        assert float(record["duration_s"]) == pytest.approx(sim["duration"])
        assert float(record["avg_speed_kmh"]) == pytest.approx(float(record["avg_speed_mps"]) * 3.6, abs=0.1)
    assert any(r[4] == '\'=HYPERLINK("x")' for r in rows[1:])  # formula neutralised
    b2 = three_trips["buses"][1]
    filtered = (await client.get("/api/v1/admin/reports/trips.csv", params={"bus_id": str(b2)}, headers=headers)).text
    assert len(list(csv.reader(io.StringIO(filtered)))) == 2


async def test_active_trip_running_time_uses_last_fix(client, admin, con, create_user, create_bus):
    _, headers = await admin()
    rid = await insert_route(con)
    driver = await create_user("driver", name="D", phone="+919000000411")
    bus = await create_bus(driver)
    start = datetime.now(UTC) - timedelta(minutes=30)
    await insert_trip(
        con,
        bus_id=bus,
        driver_id=driver,
        route_id=rid,
        started_at=start,
        distance_m=1200,
        last_fix_at=start + timedelta(minutes=10),
    )
    item = (await client.get("/api/v1/admin/trips", headers=headers)).json()["items"][0]
    assert item["ended_at"] is None and item["closed_by"] is None
    assert item["duration_s"] == 600 and item["avg_speed"] == 2.0
