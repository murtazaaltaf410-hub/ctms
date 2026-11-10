"""V1.3 decision 8: stop alert job, auto 'Stopped' status, driver reason and prompt preferences."""

# Fixtures imported from tests.alerts_support are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

from uuid import UUID

import pytest

from app.jobs.stop_alerts import stop_alert_tick
from app.live.hub import get_hub
from app.live.state import get_live
from app.modules.trips.service import rebuild_live
from app.push import get_push
from tests.alerts_support import push  # noqa: F401
from tests.conftest import bearer
from tests.tracking_support import FakeWS, along_fix

pytest_plugins = ["tests.tracking_support"]

API = "/api/v1"
AFTER_S = 300


class Scene:
    """A driver on a trip, a student watching the route, and helpers to move the fake clock."""

    def __init__(self, app, client, con, clock, driver, trip, post_fixes, student_headers, ws):
        self.app, self.client, self.con, self.clock = app, client, con, clock
        self.driver, self.trip, self._post, self.student, self.ws = driver, trip, post_fixes, student_headers, ws

    async def fix(self, along_m: float = 100.0, speed: float = 0.0) -> None:
        await self._post(self.driver, self.trip["id"], [along_fix(along_m, self.clock.current, speed=speed)])

    async def stay(self, seconds: float, step: float = 20.0) -> None:
        """Stand still for `seconds`, reporting a fresh stationary fix every `step`."""
        done = 0.0
        while done < seconds:
            self.clock.advance(min(step, seconds - done))
            done += step
            await self.fix()

    async def tick(self) -> None:
        await stop_alert_tick(self.app)

    async def events(self):
        return await self.con.fetch(
            "select * from public.stop_events where trip_id = $1 order by started_at", UUID(self.trip["id"]))

    async def live(self) -> dict:
        resp = await self.client.get(f"{API}/buses/live", headers=self.student)
        assert resp.status_code == 200, resp.text
        return resp.json()[0]

    def statuses(self) -> list[tuple[str, str | None]]:
        return [(m["status"], m["note"]) for m in self.ws.sent if m["type"] == "bus_status"]


@pytest.fixture
async def scene(app, client, con, live_app, push, driver_with_bus, google_login, start_trip, post_fixes, fake_clock):
    driver = await driver_with_bus()
    student = await google_login()
    await con.execute(
        "insert into public.push_tokens (user_id, token, platform) values ($1, 'drv-tok', 'android')",
        driver["driver_id"])
    ws = FakeWS(app)
    get_hub(app).add(ws, UUID(student["user"]["id"]), UUID(int=1), student=True, route_id=driver["route"]["id"])
    trip = await start_trip(driver)
    made = Scene(app, client, con, fake_clock, driver, trip, post_fixes, bearer(student["access_token"]), ws)
    await made.fix(100, speed=6.0)   # moving at first
    return made


async def test_no_alert_before_the_threshold(scene):
    await scene.stay(AFTER_S - 40)
    await scene.tick()
    assert await scene.events() == []
    assert (await scene.live())["status"] == "on_time"


async def test_stationary_bus_opens_one_episode_marks_delayed_and_prompts_the_driver(scene, push, app):
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    [event] = await scene.events()
    assert event["auto_marked"] is True and event["ended_at"] is None and event["reason"] is None
    assert event["driver_notified_at"] is not None
    live = await scene.live()
    assert (live["status"], live["note"]) == ("delayed", "Stopped")
    assert ("delayed", "Stopped") in scene.statuses()
    await get_push(app).drain(app)
    [msg] = push.sent
    assert msg.token == "drv-tok" and msg.tag == "stop_alert"
    assert msg.data["type"] == "stop_alert" and msg.data["trip_id"] == scene.trip["id"]
    # Further passes during the same stop change nothing: one row, one push.
    await scene.stay(60)
    await scene.tick()
    await scene.tick()
    assert len(await scene.events()) == 1
    await get_push(app).drain(app)
    assert len(push.sent) == 1


async def test_bus_moving_again_closes_the_episode_and_clears_the_auto_status(scene):
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    scene.clock.advance(10)
    await scene.fix(160, speed=7.0)   # ingestion closes the episode at once (no waiting for the job)
    [event] = await scene.events()
    assert event["ended_at"] is not None
    live = await scene.live()
    assert (live["status"], live["note"]) == ("on_time", None)
    assert scene.statuses()[-1] == ("on_time", None)
    # A later stop is a new episode.
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    assert len(await scene.events()) == 2


async def test_driver_set_status_is_never_overwritten_or_cleared(scene):
    r = await scene.client.post(f"{API}/trips/{scene.trip['id']}/status",
                                json={"status": "breakdown", "note": "Flat tyre"}, headers=scene.driver["headers"])
    assert r.status_code == 204
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    [event] = await scene.events()
    assert event["auto_marked"] is False
    assert (await scene.live())["status"] == "breakdown"
    scene.clock.advance(10)
    await scene.fix(160, speed=7.0)
    live = await scene.live()
    assert (live["status"], live["note"]) == ("breakdown", "Flat tyre")


async def test_manual_status_during_an_auto_episode_is_kept_when_the_bus_moves(scene):
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    await scene.client.post(f"{API}/trips/{scene.trip['id']}/status", json={"status": "delayed", "note": "Stopped"},
                            headers=scene.driver["headers"])
    scene.clock.advance(10)
    await scene.fix(160, speed=7.0)
    live = await scene.live()
    assert (live["status"], live["note"]) == ("delayed", "Stopped")   # the driver's, so it stays


async def test_stop_reason_updates_the_event_and_what_students_see(scene):
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    r = await scene.client.post(f"{API}/trips/{scene.trip['id']}/stop-reason", json={"reason": "waiting_for_student"},
                                headers=scene.driver["headers"])
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["reason"] == "waiting_for_student" and body["auto_marked"] is False and body["ended_at"] is None
    assert body["started_at"].endswith("Z")
    live = await scene.live()
    assert (live["status"], live["note"]) == ("delayed", "Waiting for a student")
    got = await scene.client.get(f"{API}/trips/{scene.trip['id']}/stop-event", headers=scene.driver["headers"])
    assert got.json()["reason"] == "waiting_for_student"
    # The reason stays when the bus moves on (only the driver changes it); the episode itself closes.
    scene.clock.advance(10)
    await scene.fix(160, speed=7.0)
    live = await scene.live()
    assert (live["status"], live["note"]) == ("delayed", "Waiting for a student")
    assert (await scene.events())[0]["ended_at"] is not None
    assert (await scene.client.get(f"{API}/trips/{scene.trip['id']}/stop-event",
                                   headers=scene.driver["headers"])).json() is None


async def test_stop_reason_with_note_and_breakdown_and_without_an_open_episode(scene):
    r = await scene.client.post(f"{API}/trips/{scene.trip['id']}/stop-reason",
                                json={"reason": "breakdown", "note": "Engine overheated"},
                                headers=scene.driver["headers"])
    assert r.status_code == 200 and r.json()["note"] == "Engine overheated"
    live = await scene.live()
    assert (live["status"], live["note"]) == ("breakdown", "Engine overheated")
    [event] = await scene.events()
    assert event["reason"] == "breakdown" and event["auto_marked"] is False


async def test_stop_reason_validation_and_ownership(scene, client, create_user, driver_login):
    url = f"{API}/trips/{scene.trip['id']}/stop-reason"
    h = scene.driver["headers"]
    for bad in ({"reason": "lunch"}, {"reason": "other", "note": "x" * 141}, {}):
        resp = await client.post(url, json=bad, headers=h)
        assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR", bad
    assert (await client.post(url, json={"reason": "other", "note": "x" * 140}, headers=h)).status_code == 200
    await create_user("driver", name="Other", phone="+919900000077")
    other = bearer((await driver_login("+919900000077"))["access_token"])
    resp = await client.post(url, json={"reason": "fuel"}, headers=other)
    assert resp.status_code == 403 and resp.json()["error"]["code"] == "NOT_YOUR_TRIP"
    assert (await client.post(url, json={"reason": "fuel"}, headers=scene.student)).status_code == 403
    assert (await client.post(f"{API}/trips/{UUID(int=5)}/stop-reason", json={"reason": "fuel"},
                              headers=h)).status_code == 404


async def test_driver_prefs_defaults_validation_and_roles(scene, client):
    h = scene.driver["headers"]
    assert (await client.get(f"{API}/me/driver-prefs", headers=h)).json() == {
        "stop_alerts_enabled": True, "snooze_until": None}
    for bad in ({}, {"snooze_minutes": 20}, {"snooze_minutes": -1}, {"stop_alerts_enabled": "maybe"}):
        resp = await client.put(f"{API}/me/driver-prefs", json=bad, headers=h)
        assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR", bad
    put = await client.put(f"{API}/me/driver-prefs", json={"stop_alerts_enabled": False, "snooze_minutes": 30},
                           headers=h)
    assert put.status_code == 200
    assert put.json()["stop_alerts_enabled"] is False and put.json()["snooze_until"].endswith("Z")
    again = await client.put(f"{API}/me/driver-prefs", json={"snooze_minutes": 0}, headers=h)
    assert again.json() == {"stop_alerts_enabled": False, "snooze_until": None}
    assert (await client.get(f"{API}/me/driver-prefs", headers=scene.student)).status_code == 403
    assert (await client.put(f"{API}/me/driver-prefs", json={"snooze_minutes": 15},
                             headers=scene.student)).status_code == 403


async def test_opted_out_driver_gets_no_prompt_but_students_still_see_the_status(scene, push, app, client):
    await client.put(f"{API}/me/driver-prefs", json={"stop_alerts_enabled": False}, headers=scene.driver["headers"])
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    [event] = await scene.events()
    assert event["auto_marked"] is True and event["driver_notified_at"] is None
    assert (await scene.live())["status"] == "delayed"
    await get_push(app).drain(app)
    assert push.sent == []


async def test_snooze_delays_the_prompt_until_it_ends_if_still_stopped(scene, push, app, client):
    await client.put(f"{API}/me/driver-prefs", json={"snooze_minutes": 15}, headers=scene.driver["headers"])
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    await get_push(app).drain(app)
    assert push.sent == [] and (await scene.live())["status"] == "delayed"
    await scene.stay(15 * 60, step=25)
    await scene.tick()
    await get_push(app).drain(app)
    assert len(push.sent) == 1
    assert (await scene.events())[0]["driver_notified_at"] is not None


async def test_a_bus_that_stopped_reporting_is_offline_not_stopped(scene):
    scene.clock.advance(AFTER_S + 120)   # no fixes at all
    await scene.tick()
    assert await scene.events() == []


async def test_ending_the_trip_closes_the_open_episode(scene):
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    r = await scene.client.post(f"{API}/trips/{scene.trip['id']}/end", headers=scene.driver["headers"])
    assert r.status_code == 200
    [event] = await scene.events()
    assert event["ended_at"] is not None


async def test_restart_rebuild_resumes_the_open_episode(scene, app):
    await scene.stay(AFTER_S + 20)
    await scene.tick()
    get_live(app).buses.clear()   # server restart
    await rebuild_live(app)
    bus = get_live(app).by_trip(UUID(scene.trip["id"]))
    await scene.fix(100, speed=0.0)   # a fresh stationary fix; still the same stop, no second episode
    await scene.tick()
    assert len(await scene.events()) == 1 and bus.stop_open is True
    scene.clock.advance(10)
    await scene.fix(160, speed=7.0)
    await scene.tick()   # the job closes it (ingestion only knows episodes opened since the restart)
    assert (await scene.events())[0]["ended_at"] is not None
    assert (await scene.live())["status"] == "on_time"


async def test_alert_threshold_is_a_setting(scene, app, con):
    await con.execute("update public.settings set value = '60'::jsonb where key = 'stopped_alert_after_s'")
    await app.state.settings_store.refresh(con)
    await scene.stay(80)
    await scene.tick()
    assert len(await scene.events()) == 1
