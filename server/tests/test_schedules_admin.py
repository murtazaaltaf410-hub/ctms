"""Schedules (PRD A3): admin CRUD with soft delete, public GET /schedules?route_id=."""

# Fixtures imported from tests.admin_helpers are re-bound as test parameters (pytest idiom).
# ruff: noqa: F811

from __future__ import annotations

from tests.admin_helpers import admin, err, insert_route  # noqa: F401


async def test_schedule_crud_and_public_list(client, admin, con, google_login):
    _, headers = await admin()
    rid = await insert_route(con)
    other = await insert_route(con, name="Other")
    resp = await client.post("/api/v1/admin/schedules", json={"route_id": str(rid), "departure_time": "16:45",
                                                             "days_of_week": [5, 1, 1, 3]}, headers=headers)
    assert resp.status_code == 201, resp.text
    late = resp.json()
    assert late["departure_time"] == "16:45" and late["days_of_week"] == [1, 3, 5] and late["active"] is True
    early = (await client.post("/api/v1/admin/schedules", json={"route_id": str(rid), "departure_time": "08:30:00",
                                                               "days_of_week": [1, 2, 3, 4, 5, 6]},
                               headers=headers)).json()
    await client.post("/api/v1/admin/schedules", json={"route_id": str(other), "departure_time": "09:00",
                                                      "days_of_week": [7]}, headers=headers)

    student = {"Authorization": f"Bearer {(await google_login('s1', 's1@gmail.com'))['access_token']}"}
    slots = (await client.get("/api/v1/schedules", params={"route_id": str(rid)}, headers=student)).json()["items"]
    assert [(s["departure_time"], s["days_of_week"]) for s in slots] == [("08:30", [1, 2, 3, 4, 5, 6]),
                                                                        ("16:45", [1, 3, 5])]
    assert "active" not in slots[0]

    resp = await client.patch(f"/api/v1/admin/schedules/{early['id']}", json={"departure_time": "08:15"},
                              headers=headers)
    assert resp.status_code == 200 and resp.json()["departure_time"] == "08:15"
    resp = await client.patch(f"/api/v1/admin/schedules/{late['id']}", json={"active": False}, headers=headers)
    assert resp.status_code == 200 and resp.json()["active"] is False
    slots = (await client.get("/api/v1/schedules", params={"route_id": str(rid)}, headers=student)).json()["items"]
    assert [s["id"] for s in slots] == [early["id"]]
    all_admin = (await client.get("/api/v1/admin/schedules", params={"route_id": str(rid)}, headers=headers)).json()
    assert len(all_admin["items"]) == 2
    assert await con.fetchval("select count(*) from public.audit_log where target_type = 'schedule'") == 5


async def test_schedule_validation(client, admin, con):
    _, headers = await admin()
    rid = str(await insert_route(con))
    for body in ({"route_id": rid, "departure_time": "08:30", "days_of_week": []},
                 {"route_id": rid, "departure_time": "08:30", "days_of_week": [0]},
                 {"route_id": rid, "departure_time": "08:30", "days_of_week": [8]},
                 {"route_id": rid, "departure_time": "25:00", "days_of_week": [1]},
                 {"route_id": rid, "departure_time": "08:30Z", "days_of_week": [1]},
                 {"route_id": "00000000-0000-4000-8000-000000000000", "departure_time": "08:30",
                  "days_of_week": [1]}):
        resp = await client.post("/api/v1/admin/schedules", json=body, headers=headers)
        assert resp.status_code == 400 and err(resp) == "VALIDATION_ERROR", body
    resp = await client.patch("/api/v1/admin/schedules/00000000-0000-4000-8000-000000000000", json={"active": False},
                              headers=headers)
    assert resp.status_code == 404
