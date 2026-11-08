"""TC3 (T11): the driver signs in on a second phone mid-trip. The first phone gets
SESSION_REPLACED (and stops uploading); the trip continues from the second phone."""

from __future__ import annotations

from tests.acceptance.sim_support import SimPlayer, live_bus, plan
from tests.conftest import bearer


async def test_tc3_second_phone_replaces_first_mid_trip(client, live_app, fake_clock, sim_trip, driver_login):
    route, driver, trip, player = await sim_trip()
    fixes, events = plan(route.geom, player.start, speed_kmh=30, minutes=3)
    half = len(events) // 2
    uploads = await player.play(events[:half])
    assert all(u.status_code == 200 for u in uploads)

    second = await driver_login(driver["phone"])  # phone 2 signs in
    phone2 = SimPlayer(client, fake_clock, bearer(second["access_token"]), trip["id"], player.start)

    # Phone 1's next upload is refused with SESSION_REPLACED; nothing from it is stored.
    nxt = events[half]
    resp = await client.post(f"/api/v1/trips/{trip['id']}/locations", json=nxt.item.payload, headers=driver["headers"])
    assert resp.status_code == 401 and resp.json()["error"]["code"] == "SESSION_REPLACED"
    for path in ("/api/v1/trips/active", "/api/v1/me"):
        r = await client.get(path, headers=driver["headers"])
        assert r.status_code == 401 and r.json()["error"]["code"] == "SESSION_REPLACED"

    # Phone 2 sees the same active trip and carries on with the rest of the drive (incl. the refused batch).
    active = await client.get("/api/v1/trips/active", headers=bearer(second["access_token"]))
    assert active.json()["id"] == trip["id"]
    rest = await phone2.play(events[half:])
    assert all(u.status_code == 200 and not u.rejected for u in rest)
    bus = await live_bus(client, bearer(second["access_token"]), trip["bus_id"])
    assert (bus["lat"], bus["lng"]) == (round(fixes[-1].lat, 7), round(fixes[-1].lng, 7))
