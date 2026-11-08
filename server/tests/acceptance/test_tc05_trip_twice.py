"""TC5 (T10): starting a trip twice gives 409 TRIP_ALREADY_ACTIVE; the driver can resume the
active trip (GET /trips/active) or end it, after which a new trip starts."""

from __future__ import annotations

from tests.acceptance.sim_support import live_buses, plan


async def test_tc5_second_start_is_409_and_the_trip_can_be_resumed(client, live_app, sim_trip):
    route, driver, trip, player = await sim_trip()
    _, events = plan(route.geom, player.start, minutes=1)
    await player.play(events[:3])

    again = await client.post("/api/v1/trips/start", json={}, headers=driver["headers"])
    assert again.status_code == 409 and again.json()["error"]["code"] == "TRIP_ALREADY_ACTIVE"
    explicit = await client.post("/api/v1/trips/start", json={"route_id": str(route.id)}, headers=driver["headers"])
    assert explicit.status_code == 409

    # Resume: the app asks for the active trip and keeps uploading to it.
    active = (await client.get("/api/v1/trips/active", headers=driver["headers"])).json()
    assert active["id"] == trip["id"]
    rest = await player.play(events[3:])
    assert all(u.status_code == 200 and not u.rejected for u in rest)
    assert len(await live_buses(client, driver["headers"])) == 1          # still one bus, one trip

    # End it, then a new trip starts normally.
    await player.end()
    assert (await client.get("/api/v1/trips/active", headers=driver["headers"])).json() is None
    new = await client.post("/api/v1/trips/start", json={}, headers=driver["headers"])
    assert new.status_code == 201 and new.json()["id"] != trip["id"]


async def test_tc5_bus_in_use_by_another_driver_is_409(client, con, live_app, sim_trip, create_user, driver_login):
    """A substitute linked to the same bus while a trip runs cannot start a second one."""
    _route, _driver, trip, _player = await sim_trip()
    await create_user("driver", name="Substitute", phone="+919833300001")
    sub = await driver_login("+919833300001")
    # Link check: one driver per bus, so relink the bus to the substitute (U8) and try to start.
    await con.execute("update public.buses set driver_id = (select id from public.users where phone = $1) "
                      "where id = $2::uuid", "+919833300001", trip["bus_id"])
    resp = await client.post("/api/v1/trips/start", json={},
                             headers={"Authorization": f"Bearer {sub['access_token']}"})
    assert resp.status_code == 409 and resp.json()["error"]["code"] == "TRIP_ALREADY_ACTIVE"
