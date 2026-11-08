"""GET /announcements (cursor, newest first) and POST/PATCH/DELETE /admin/announcements."""
# ruff: noqa: F811  (pytest fixtures imported from tests.alerts_support)

from __future__ import annotations

import pytest

from app.live.hub import get_hub
from tests.alerts_support import FakeWs, admin_token, push, student  # noqa: F401
from tests.conftest import bearer

URL = "/api/v1/admin/announcements"


@pytest.fixture
async def admin(con, google_login) -> dict:
    return bearer(await admin_token(con, google_login))


@pytest.fixture
async def student_auth(google_login) -> dict:
    return bearer((await google_login(sub="p4-ann-s", email="p4-ann-s@uok.edu.in"))["access_token"])


async def post(client, admin, **body) -> dict:
    body = {"title": "Title", "body": "Body", **body}
    resp = await client.post(URL, json=body, headers=admin)
    assert resp.status_code == 201, resp.text
    return resp.json()


async def test_create_broadcasts_audits_and_returns_announcement(app, client, con, admin, push):
    ws = FakeWs()
    get_hub(app).add(ws, "u", "s")
    ann = await post(client, admin, title="Road closed", body="Use the east gate", urgent=True)
    assert set(ann) == {"id", "title", "body", "urgent", "created_at", "updated_at"}
    assert ann["urgent"] is True and ann["created_at"].endswith("Z")
    assert ws.messages == [{"type": "announcement", "id": ann["id"], "title": "Road closed", "urgent": True}]
    audit = await con.fetchrow("select action, target_type, meta from public.audit_log "
                               "where target_id = $1", ann["id"])
    assert audit["action"] == "announcement.create" and audit["target_type"] == "announcement"
    assert audit["meta"] == {"urgent": True, "push": False}
    assert app.state.push.queue.qsize() == 0  # push defaults to false


async def test_push_true_notifies_all_students(app, client, con, admin, push, student, create_user):
    await student(token="tok-a1")
    await student(token="tok-a2")
    driver = await create_user("driver", name="D", phone="+919833300001")
    await con.execute("insert into public.push_tokens (user_id, token, platform) values ($1, 'tok-d', 'android')",
                      driver)
    ann = await post(client, admin, title="Holiday", body="x" * 300, push=True)
    await app.state.push.drain(app)
    assert {m.token for m in push.sent} == {"tok-a1", "tok-a2"}
    msg = push.sent[0]
    assert msg.title == "Holiday" and len(msg.body) == 240 and msg.body.endswith("…")
    assert msg.data == {"type": "announcement", "id": ann["id"], "urgent": "false"}


async def test_feed_is_newest_first_with_cursor_pagination(client, admin, student_auth):
    ids = [(await post(client, admin, title=f"A{i}"))["id"] for i in range(5)]
    resp = await client.get("/api/v1/announcements", params={"limit": 2}, headers=student_auth)
    page1 = resp.json()
    assert [a["id"] for a in page1["items"]] == ids[:-3:-1]
    assert page1["next_cursor"]
    page2 = (await client.get("/api/v1/announcements", params={"limit": 2, "cursor": page1["next_cursor"]},
                              headers=student_auth)).json()
    page3 = (await client.get("/api/v1/announcements", params={"limit": 2, "cursor": page2["next_cursor"]},
                              headers=student_auth)).json()
    seen = [a["id"] for p in (page1, page2, page3) for a in p["items"]]
    assert seen[:5] == ids[::-1]
    mine = [i for i in seen if i in ids]
    assert mine == ids[::-1]


async def test_feed_default_limit_and_last_page_has_no_cursor(client, admin, student_auth):
    ann = await post(client, admin)
    body = (await client.get("/api/v1/announcements", headers=student_auth)).json()
    assert body["items"][0]["id"] == ann["id"]
    assert len(body["items"]) <= 50
    assert (body["next_cursor"] is None) == (len(body["items"]) < 50)


async def test_invalid_cursor_and_limit(client, student_auth):
    resp = await client.get("/api/v1/announcements", params={"cursor": "not-a-cursor"}, headers=student_auth)
    assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR"
    assert (await client.get("/api/v1/announcements", params={"limit": 201}, headers=student_auth)).status_code == 400


async def test_patch_updates_fields_and_is_audited(client, con, admin, student_auth):
    ann = await post(client, admin, title="Old", body="Text")
    resp = await client.patch(f"{URL}/{ann['id']}", json={"title": "New", "urgent": True}, headers=admin)
    assert resp.status_code == 200
    assert resp.json()["title"] == "New" and resp.json()["body"] == "Text" and resp.json()["urgent"] is True
    meta = await con.fetchval("select meta from public.audit_log where action = 'announcement.update' "
                              "and target_id = $1", ann["id"])
    assert meta == {"fields": ["title", "urgent"]}
    resp = await client.patch(f"{URL}/{ann['id']}", json={}, headers=admin)
    assert resp.status_code == 400


async def test_delete_is_soft_and_hides_from_feed(client, con, admin, student_auth):
    ann = await post(client, admin, title="Gone soon")
    assert (await client.delete(f"{URL}/{ann['id']}", headers=admin)).status_code == 204
    feed = (await client.get("/api/v1/announcements", params={"limit": 200}, headers=student_auth)).json()
    assert ann["id"] not in [a["id"] for a in feed["items"]]
    assert await con.fetchval("select active from public.announcements where id = $1", ann["id"]) is False
    assert await con.fetchval("select count(*) from public.audit_log where action = 'announcement.delete' "
                              "and target_id = $1", ann["id"]) == 1
    # Deleted is gone for PATCH and DELETE too.
    assert (await client.delete(f"{URL}/{ann['id']}", headers=admin)).json()["error"]["code"] == "NOT_FOUND"
    assert (await client.patch(f"{URL}/{ann['id']}", json={"title": "x"}, headers=admin)).status_code == 404


async def test_admin_endpoints_reject_students(client, admin, student_auth):
    resp = await client.post(URL, json={"title": "x", "body": "y"}, headers=student_auth)
    assert resp.status_code == 403 and resp.json()["error"]["code"] == "FORBIDDEN_ROLE"
    ann = await post(client, admin)
    assert (await client.patch(f"{URL}/{ann['id']}", json={"title": "x"}, headers=student_auth)).status_code == 403
    assert (await client.delete(f"{URL}/{ann['id']}", headers=student_auth)).status_code == 403
    assert (await client.get("/api/v1/announcements")).status_code == 401


@pytest.mark.parametrize("body", [{"title": "", "body": "x"}, {"title": "x" * 201, "body": "x"},
                                  {"title": "x", "body": "y" * 4001}, {"body": "x"}])
async def test_create_validation(client, admin, body):
    resp = await client.post(URL, json=body, headers=admin)
    assert resp.status_code == 400 and resp.json()["error"]["code"] == "VALIDATION_ERROR"
