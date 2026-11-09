"""Push delivery: N9 (invalid token deleted, one retry), sender selection, FCM mapping, queue bounds."""
# ruff: noqa: F811  (pytest fixtures imported from tests.alerts_support)

from __future__ import annotations

from types import SimpleNamespace

import pytest
from firebase_admin import exceptions as fb_exceptions
from firebase_admin import messaging

from app.push import FakeSender, FcmSender, LogSender, PushDispatcher, PushJob, PushMessage, build_sender
from app.push.base import is_invalid_token
from app.push.senders import _to_fcm
from tests.alerts_support import push, student  # noqa: F401
from tests.conftest import make_config


async def tokens(con, user_id) -> set[str]:
    return {r["token"] for r in await con.fetch("select token from public.push_tokens where user_id = $1", user_id)}


async def add_token(con, user_id, token):
    await con.execute(
        "insert into public.push_tokens (user_id, token, platform) values ($1, $2, 'android')", user_id, token
    )


async def test_n9_invalid_token_deleted_and_transient_failure_retried_once(app, con, push, student):
    sid = await student(token="tok-good")
    await add_token(con, sid, "tok-dead")
    await add_token(con, sid, "tok-flaky")
    push.invalid.add("tok-dead")
    push.fail_once.add("tok-flaky")

    await app.state.push.deliver(app, PushJob(title="T", body="B", user_ids=(sid,)))

    assert {m.token for m in push.sent} == {"tok-good", "tok-flaky"}
    attempts = [m.token for m in push.attempts]
    assert attempts.count("tok-dead") == 1  # invalid tokens are not retried
    assert attempts.count("tok-flaky") == 2  # one retry
    assert attempts.count("tok-good") == 1
    assert await tokens(con, sid) == {"tok-good", "tok-flaky"}


async def test_n9_only_one_retry_and_transient_failures_keep_the_token(app, con, push, student):
    sid = await student(token="tok-down")
    push.down.add("tok-down")
    await app.state.push.deliver(app, PushJob(title="T", body="B", user_ids=(sid,)))
    assert [m.token for m in push.attempts] == ["tok-down", "tok-down"]
    assert push.sent == []
    assert await tokens(con, sid) == {"tok-down"}


async def test_audience_all_students_skips_other_roles_and_inactive(app, con, push, student, create_user):
    s1 = await student(token="tok-s1")
    driver = await create_user("driver", name="D", phone="+919822200001")
    await add_token(con, driver, "tok-driver")
    gone = await student(token="tok-gone")
    await con.execute("update public.users set active = false where id = $1", gone)
    await app.state.push.deliver(app, PushJob(title="T", body="B"))
    assert {m.token for m in push.sent} == {"tok-s1"}
    assert s1


async def test_submit_never_blocks_and_drops_when_full():
    dispatcher = PushDispatcher(FakeSender(), maxsize=2)
    assert dispatcher.submit(PushJob(title="1", body="")) is True
    assert dispatcher.submit(PushJob(title="2", body="")) is True
    assert dispatcher.submit(PushJob(title="3", body="")) is False
    assert dispatcher.dropped == 1 and dispatcher.queue.qsize() == 2


async def test_worker_delivers_in_background(app, con, push, student):
    import asyncio

    sid = await student(token="tok-bg")
    dispatcher = app.state.push
    dispatcher.start(app)
    try:
        dispatcher.submit(PushJob(title="bg", body="", user_ids=(sid,)))
        await asyncio.wait_for(dispatcher.queue.join(), timeout=5)
    finally:
        await dispatcher.stop()
    assert [m.title for m in push.sent] == ["bg"]


@pytest.mark.parametrize(
    "exc, invalid",
    [
        (messaging.UnregisteredError("Requested entity was not found."), True),
        (messaging.SenderIdMismatchError("mismatch"), True),
        (fb_exceptions.InvalidArgumentError("The registration token is not a valid FCM registration token"), True),
        (fb_exceptions.InvalidArgumentError("Invalid JSON payload"), False),
        (fb_exceptions.UnavailableError("unavailable"), False),
        (messaging.QuotaExceededError("quota"), False),
        (None, False),
    ],
)
def test_invalid_token_classification(exc, invalid):
    assert is_invalid_token(exc) is invalid


def test_sender_selection():
    assert isinstance(build_sender(make_config()), LogSender)  # dev/test default
    assert isinstance(build_sender(make_config(push_provider="fake")), FakeSender)
    assert isinstance(build_sender(make_config(push_provider="fcm")), FcmSender)


def test_production_refuses_non_fcm_push_provider():
    with pytest.raises(ValueError, match="PUSH_PROVIDER"):
        make_config(
            app_env="production",
            jwt_secret="x" * 40,
            database_url="postgresql://prod/db",
            fcm_credentials="{}",
            google_directions_key="k",
            push_provider="log",
        )


def test_fcm_message_carries_tag_and_data():
    msg = _to_fcm(PushMessage(token="t", title="Bus nearby", body="b", data={"type": "nearby_alert"}, tag="nearby"))
    assert msg.token == "t"
    assert msg.notification.title == "Bus nearby"
    assert msg.data == {"type": "nearby_alert"}
    assert msg.android.collapse_key == "nearby" and msg.android.notification.tag == "nearby"
    assert _to_fcm(PushMessage(token="t", title="x", body="y")).android.notification is None


async def test_fcm_sender_maps_batch_results(monkeypatch):
    calls = []

    def fake_send_each(messages):
        calls.append(len(messages))
        responses = [
            SimpleNamespace(success=i % 2 == 0, exception=None if i % 2 == 0 else messaging.UnregisteredError("gone"))
            for i in range(len(messages))
        ]
        return SimpleNamespace(responses=responses)

    monkeypatch.setattr("app.push.senders.ensure_firebase_app", lambda config: None)
    monkeypatch.setattr(messaging, "send_each", fake_send_each)
    sender = FcmSender(make_config(push_provider="fcm"))
    results = await sender.send([PushMessage(token=f"t{i}", title="x", body="y") for i in range(501)])
    assert calls == [500, 1]
    assert [r.token for r in results[:3]] == ["t0", "t1", "t2"]
    assert results[0].ok and not results[1].ok and is_invalid_token(results[1].exception)


async def test_fcm_sender_whole_batch_failure_marks_every_message(monkeypatch):
    def boom(messages):
        raise fb_exceptions.UnavailableError("down")

    monkeypatch.setattr("app.push.senders.ensure_firebase_app", lambda config: None)
    monkeypatch.setattr(messaging, "send_each", boom)
    results = await FcmSender(make_config(push_provider="fcm")).send(
        [PushMessage(token="a", title="x", body="y"), PushMessage(token="b", title="x", body="y")]
    )
    assert [r.ok for r in results] == [False, False]
    assert not any(is_invalid_token(r.exception) for r in results)
