"""TC18: three simulated trips; the trip list, summary report and CSV export show distance and
times that match the simulator's own totals within 2 %."""

from __future__ import annotations

import csv
import io
from datetime import datetime

from scripts.simulate import Dropout
from tests.acceptance.sim_support import SimPlayer, plan, within


def ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


async def test_tc18_three_trips_match_simulator_totals(client, live_app, admin, fake_clock, sim_trip, sim_route,
                                                      start_trip):
    _, headers = await admin()
    loop = await sim_route()
    drives = [   # (bus label, speed, extra faults) - two trips on Bus A, one on Bus B
        ("Bus A", 25, {}),
        ("Bus B", 35, {"bad_accuracy_every": 6, "spike_every": 9, "duplicate_every": 5,
                       "dropouts": [Dropout(60, 90)]}),
        ("Bus A", 18, {"minutes": 6}),
    ]
    expected: dict[str, dict] = {}
    players: dict[str, tuple] = {}
    for label, speed, faults in drives:
        if label in players:
            driver = players[label]
            trip = await start_trip(driver)
            player = SimPlayer(client, fake_clock, driver["headers"], trip["id"], fake_clock.current)
        else:
            _, driver, trip, player = await sim_trip(route=loop, label=label)
            players[label] = driver
        fixes, events = plan(loop.geom, player.start, speed_kmh=speed, fix_every_s=3, interval_s=5, **faults)
        await player.play(events)
        end_t = events[-1].t
        summary = await player.end(end_t)
        expected[trip["id"]] = {"label": label, "distance": fixes[-1].along_m, "duration": end_t,
                                "started": player.start, "ended": player.at(end_t)}
        assert within(summary["distance_m"], fixes[-1].along_m, 2)
        assert within(summary["duration_s"], end_t, 2)
        fake_clock.advance(600)            # a break between trips

    items = (await client.get("/api/v1/admin/trips", headers=headers)).json()["items"]
    assert {t["id"] for t in items} == set(expected)
    for t in items:
        exp = expected[t["id"]]
        assert t["bus_label"] == exp["label"] and t["closed_by"] == "driver"
        assert within(t["distance_m"], exp["distance"], 2), (t, exp)
        assert within(t["duration_s"], exp["duration"], 2), (t, exp)
        assert ts(t["started_at"]) == exp["started"] and ts(t["ended_at"]) == exp["ended"]
        assert within(t["avg_speed"], exp["distance"] / exp["duration"], 2)

    summary = (await client.get("/api/v1/admin/reports/summary", headers=headers)).json()
    per_bus = {b["label"]: b for b in summary["buses"]}
    for label in ("Bus A", "Bus B"):
        mine = [e for e in expected.values() if e["label"] == label]
        assert per_bus[label]["trips"] == len(mine)
        assert within(per_bus[label]["distance_m"], sum(e["distance"] for e in mine), 2)
        assert within(per_bus[label]["running_time_s"], sum(e["duration"] for e in mine), 2)
    assert summary["totals"]["trips"] == 3

    resp = await client.get("/api/v1/admin/reports/trips.csv", headers=headers)
    assert resp.status_code == 200 and resp.headers["content-type"].startswith("text/csv")
    rows = list(csv.DictReader(io.StringIO(resp.text)))
    assert {r["trip_id"] for r in rows} == set(expected)
    for r in rows:
        exp = expected[r["trip_id"]]
        assert within(float(r["distance_m"]), exp["distance"], 2)
        assert within(float(r["duration_s"]), exp["duration"], 2)
