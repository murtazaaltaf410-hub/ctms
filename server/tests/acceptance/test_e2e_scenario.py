"""End-to-end: admin sets up a route, bus and driver; the driver runs a trip with the simulator
past a waiting student who has alerts on; the student gets one alert, the live socket and
ETAs follow the bus; the trip ends and shows up in the report and CSV export."""

from __future__ import annotations

import asyncio
import csv
import io

from scripts.simulate import Route, StatusChange, decode_polyline
from tests.acceptance.sim_support import (
    L_ROUTE,
    SimPlayer,
    alert_student,
    drain_alerts,
    plan,
    stop_eta,
    within,
    ws_connect,
)
from tests.conftest import bearer

STOP_NAMES = ["Main Gate", "Library", "Science Block", "Hostel", "Sports Ground"]


async def test_e2e_route_to_report(
    client, con, live_app, fake_clock, admin, fake_routes, push, driver_login, google_login
):
    # 1. Admin: route (Routes API faked), bus with that default route, driver linked to the bus.
    _, adm = await admin()
    stops = [{"name": n, "lat": lat, "lng": lng} for n, (lat, lng) in zip(STOP_NAMES, L_ROUTE, strict=True)]
    resp = await client.post("/api/v1/admin/routes", json={"name": "North Loop", "stops": stops}, headers=adm)
    assert resp.status_code == 201, resp.text
    route = resp.json()
    assert route["status"] == "active" and route["polyline"] and len(fake_routes.calls) == 1
    bus = await client.post(
        "/api/v1/admin/buses",
        json={"label": "Bus 7", "plate": "JK01E2E7", "default_route_id": route["id"]},
        headers=adm,
    )
    assert bus.status_code == 201, bus.text
    bus_id = bus.json()["id"]
    drv = await client.post(
        "/api/v1/admin/drivers", json={"name": "E2E Driver", "phone": "+919877700001", "bus_id": bus_id}, headers=adm
    )
    assert drv.status_code == 201 and drv.json()["bus_id"] == bus_id, drv.text
    assigned = await client.put(
        f"/api/v1/admin/drivers/{drv.json()['id']}/routes",
        json={"route_ids": [route["id"]]},
        headers=adm,
    )
    assert assigned.status_code == 200, assigned.text

    # 2. Student waiting at "Hostel" with alerts on, app open (live socket).
    hostel = next(s for s in route["stops"] if s["name"] == "Hostel")
    student = await alert_student(client, google_login, 41, hostel["lat"], hostel["lng"])
    ws, task = await ws_connect(live_app, student.headers["Authorization"].removeprefix("Bearer "))

    # 3. Driver signs in with the temporary password from step 1 and starts the trip on the default route.
    tokens = await driver_login("+919877700001", drv.json()["temporary_password"])
    me = (await client.get("/api/v1/me", headers=bearer(tokens["access_token"]))).json()
    assert me["role"] == "driver"
    start = await client.post("/api/v1/trips/start", json={}, headers=bearer(tokens["access_token"]))
    assert start.status_code == 201, start.text
    trip = start.json()
    assert trip["route_id"] == route["id"] and trip["bus_id"] == bus_id

    # 4. The simulator drives the route it fetched from GET /routes/{id}, like the CLI does.
    public = (await client.get(f"/api/v1/routes/{route['id']}", headers=student.headers)).json()
    geom = Route(decode_polyline(public["polyline"]))
    player = SimPlayer(client, fake_clock, bearer(tokens["access_token"]), trip["id"], fake_clock.current)
    fixes, events = plan(
        geom,
        player.start,
        speed_kmh=30,
        fix_every_s=3,
        interval_s=10,
        statuses=[StatusChange(120, "delayed", "Traffic at the gate")],
    )
    etas: list[dict] = []

    async def after(upload):
        await drain_alerts(live_app)
        [eta] = (await stop_eta(client, student.headers, hostel["id"]))["etas"]
        etas.append(eta)

    uploads = await player.play(events, after=after)
    assert all(u.status_code == 200 and not u.rejected for u in uploads)

    # Exactly one alert, sent as the bus came within 500 m of the waiting student.
    mine = [m for m in push.sent if m.token == student.push_token]
    assert len(mine) == 1 and "Bus 7 (North Loop route) is about" in mine[0].body
    assert mine[0].data["trip_id"] == trip["id"]

    # ETA to the student's stop: counts down, then the stop is passed.
    upcoming = [e["eta_seconds"] for e in etas if not e["passed"]]
    assert len(upcoming) > 10 and upcoming == sorted(upcoming, reverse=True) and upcoming[-1] < 60
    assert etas[-1]["passed"] is True and etas[-1]["eta_seconds"] is None
    assert any(e["status"] == "delayed" for e in etas)

    # 5. Driver ends the trip.
    end_t = events[-1].t
    summary = await player.end(end_t)
    assert within(summary["distance_m"], fixes[-1].along_m, 2)

    # The socket saw the whole trip, in order.
    types = [m["type"] for m in ws.sent]
    assert types[0] == "trip_started" and types[-1] == "trip_ended"
    assert types.count("bus_position") == len(uploads)
    assert {"type": "bus_status", "bus_id": bus_id, "trip_id": trip["id"], "status": "delayed",
            "note": "Traffic at the gate"} in ws.sent
    assert types.index("bus_status") > types.index("bus_position")
    ws.hang_up()
    await asyncio.wait_for(task, timeout=2)
    assert (await client.get("/api/v1/buses/live", headers=student.headers)).json() == []

    # 6. Admin: trip report, path replay, summary and CSV.
    [row] = (await client.get(f"/api/v1/admin/trips?bus_id={bus_id}", headers=adm)).json()["items"]
    assert row["id"] == trip["id"] and row["driver_name"] == "E2E Driver" and row["closed_by"] == "driver"
    assert row["status"] == "delayed" and within(row["distance_m"], fixes[-1].along_m, 2)
    assert within(row["duration_s"], end_t, 2)
    path = (await client.get(f"/api/v1/admin/trips/{trip['id']}/path", headers=adm)).json()["positions"]
    assert len(path) == len(fixes)
    summary = (await client.get("/api/v1/admin/reports/summary", headers=adm)).json()
    [per_bus] = [b for b in summary["buses"] if b["bus_id"] == bus_id]
    assert per_bus["trips"] == 1 and within(per_bus["distance_m"], fixes[-1].along_m, 2)
    resp = await client.get("/api/v1/admin/reports/trips.csv", headers=adm)
    [csv_row] = [r for r in csv.DictReader(io.StringIO(resp.text)) if r["trip_id"] == trip["id"]]
    assert csv_row["bus_label"] == "Bus 7" and csv_row["route_name"] == "North Loop"
    assert within(float(csv_row["distance_m"]), fixes[-1].along_m, 2)
    assert await con.fetchval("select count(*) from public.alert_log where trip_id = $1::uuid", trip["id"]) == 1
