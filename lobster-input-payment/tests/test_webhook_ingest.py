"""webhook 事件幂等摄取管道(计费域重构阶段 0)测试。

复用 test_payment_rules 的 fake db 模式,并为 webhook_events 集合补上
(provider, event_id) 唯一索引的 DuplicateKeyError 模拟。
"""
import asyncio
import json

import pytest
from fastapi import HTTPException
from fastapi.responses import PlainTextResponse
from pymongo.errors import DuplicateKeyError

from app.api.v1 import payments, webhook_admin
from app.services.webhook import ingest as webhook_ingest
from test_payment_rules import (
    _Collection,
    _Db,
    _FakeLifecycle,
    _FakePaymentAdapter,
    _patch_all,
    _patch_amount_order_context,
    _patch_payment_context,
    _plan_configs,
)


class _WebhookEventsCollection(_Collection):
    """模拟 (provider, event_id) 唯一索引:重复插入抛 DuplicateKeyError。"""

    async def insert_one(self, doc):
        for existing in self.docs:
            if existing.get("provider") == doc.get("provider") and existing.get("event_id") == doc.get("event_id"):
                raise DuplicateKeyError("E11000 duplicate key error: (provider, event_id)")
        return await super().insert_one(doc)


class _FakeRequest:
    def __init__(self, body: bytes, headers=None, query: str = ""):
        self._body = body
        self.headers = headers or {}
        self.url = type("_URL", (), {"query": query})()

    async def body(self):
        return self._body


class _BadSignatureAdapter(_FakePaymentAdapter):
    def verify_webhook_signature(self, *_args, **_kwargs):
        raise HTTPException(status_code=401, detail="Invalid webhook signature")


def _webhook_db(user=None):
    data = {
        "system_config": _Collection([{"key": "plan_configs", "value": _plan_configs()}]),
        "payment_callback_events": _Collection(),
        "webhook_events": _WebhookEventsCollection(),
    }
    if user is not None:
        data["users"] = _Collection([user])
    return _Db(data)


def _event_doc(db, provider, event_id):
    return next(
        doc for doc in db["webhook_events"].docs
        if doc.get("provider") == provider and doc.get("event_id") == event_id
    )


@pytest.fixture(autouse=True)
def _patch_lifecycle(monkeypatch):
    _patch_all(monkeypatch,"CreditGrantLifecycleCoordinator", _FakeLifecycle)


# ---------------- 摄取模块本身 ----------------


def test_ingest_dedup_and_failed_retry_semantics():
    db = _webhook_db()

    assert asyncio.run(webhook_ingest.ingest(db, "creem", "evt_1", {"id": "evt_1"}, True)) == "new"
    doc = _event_doc(db, "creem", "evt_1")
    assert doc["status"] == "received"
    assert doc["signature_ok"] is True
    assert doc["error"] is None
    assert doc["processed_at"] is None

    # 已存在且非 failed:重复
    assert asyncio.run(webhook_ingest.ingest(db, "creem", "evt_1", {"id": "evt_1"}, True)) == "duplicate"

    asyncio.run(webhook_ingest.mark_failed(db, "creem", "evt_1", "boom"))
    assert doc["status"] == "failed"
    assert doc["error"] == "boom"
    assert doc["processed_at"] is not None

    # failed 状态允许 provider 重试重新处理(与既有 5xx 重试语义一致)
    assert asyncio.run(webhook_ingest.ingest(db, "creem", "evt_1", {"id": "evt_1"}, True)) == "new"
    assert doc["status"] == "processing"

    asyncio.run(webhook_ingest.mark_done(db, "creem", "evt_1", {"status": "applied"}))
    assert doc["status"] == "done"
    assert doc["result"] == {"status": "applied"}
    assert doc["error"] is None


# ---------------- webhook 入口:新事件入库并处理 ----------------


def test_webhook_new_creem_event_is_ingested_and_marked_done(monkeypatch):
    db = _webhook_db(user={"email": "user@example.com", "subscription_plan_code": "free"})
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_payment_context(monkeypatch)

    event = {"id": "evt_unknown_type", "eventType": "some.unknown", "object": {}}
    result = asyncio.run(payments.payment_provider_webhook("creem", _FakeRequest(json.dumps(event).encode("utf-8"))))

    assert result == {"status": "ignored", "event_type": "some.unknown"}
    doc = _event_doc(db, "creem", "evt_unknown_type")
    assert doc["status"] == "done"
    assert doc["signature_ok"] is True
    assert doc["raw"]["id"] == "evt_unknown_type"
    assert doc["result"]["status"] == "ignored"
    # 内部既有 payment_callback_events 幂等逻辑不受影响,照常落记录
    assert db["payment_callback_events"].docs[0]["payment_event_id"] == "evt_unknown_type"


# ---------------- webhook 入口:重复事件跳过 handler ----------------


def test_webhook_duplicate_event_skips_handler(monkeypatch):
    db = _webhook_db(user={"email": "user@example.com", "subscription_plan_code": "free"})
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_payment_context(monkeypatch)

    calls = []
    original_dispatch = payments.dispatch_webhook_event

    async def counting_dispatch(*args, **kwargs):
        calls.append(1)
        return await original_dispatch(*args, **kwargs)

    _patch_all(monkeypatch,"dispatch_webhook_event", counting_dispatch)

    body = json.dumps({"id": "evt_dup", "eventType": "some.unknown", "object": {}}).encode("utf-8")
    first = asyncio.run(payments.payment_provider_webhook("creem", _FakeRequest(body)))
    second = asyncio.run(payments.payment_provider_webhook("creem", _FakeRequest(body)))

    assert first["status"] == "ignored"
    assert second == {"status": "duplicate"}
    assert calls == [1]
    assert _event_doc(db, "creem", "evt_dup")["status"] == "done"


# ---------------- webhook 入口:处理失败标记 failed ----------------


def test_webhook_failure_marks_event_failed_and_reraises(monkeypatch):
    db = _webhook_db()
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_amount_order_context(monkeypatch)

    # checkout 不存在 → 既有行为抛 404,摄取层需 mark_failed 且不吞异常
    body = b"out_trade_no=lobster_missing&trade_no=t1&trade_status=TRADE_SUCCESS&money=9.90"
    with pytest.raises(HTTPException) as exc:
        asyncio.run(payments.payment_provider_webhook("zpay", _FakeRequest(body)))

    assert exc.value.status_code == 404
    doc = _event_doc(db, "zpay", "lobster_missing:TRADE_SUCCESS")
    assert doc["status"] == "failed"
    assert "ZPay" in doc["error"]
    assert doc["raw"]["params"]["out_trade_no"] == "lobster_missing"


def test_webhook_invalid_signature_still_records_event(monkeypatch):
    db = _webhook_db()
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_payment_context(monkeypatch, adapter=_BadSignatureAdapter())

    body = json.dumps({"id": "evt_bad_sig", "eventType": "some.unknown", "object": {}}).encode("utf-8")
    with pytest.raises(HTTPException) as exc:
        asyncio.run(payments.payment_provider_webhook("creem", _FakeRequest(body)))

    assert exc.value.status_code == 401
    doc = _event_doc(db, "creem", "invalid_sig:evt_bad_sig")
    assert doc["signature_ok"] is False
    assert doc["status"] == "received"


# ---------------- replay:failed 事件重放成功 ----------------


def test_replay_failed_zpay_event_succeeds(monkeypatch):
    db = _webhook_db(user={"email": "user@example.com", "subscription_plan_code": "free"})
    db["payment_checkout_sessions"].docs.append({
        "request_id": "lobster_sub_replay",
        "provider": "zpay",
        "kind": "subscription",
        "status": "pending",
        "user_email": "user@example.com",
        "plan_code": "lite",
        "billing_cycle": "monthly",
        "settlement_mode": "full_price",
        "auto_renew": False,
        "payment_channel": "zpay_main",
    })
    db["webhook_events"].docs.append({
        "provider": "zpay",
        "event_id": "lobster_sub_replay:TRADE_SUCCESS",
        "raw": {"params": {
            "out_trade_no": "lobster_sub_replay",
            "trade_no": "t99",
            "trade_status": "TRADE_SUCCESS",
            "money": "9.90",
        }},
        "signature_ok": True,
        "status": "failed",
        "error": "用户不存在",
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    monkeypatch.setattr(webhook_admin, "get_main_db", lambda: db)
    _patch_amount_order_context(monkeypatch)

    response = asyncio.run(webhook_admin.admin_webhook_event_replay("zpay", "lobster_sub_replay:TRADE_SUCCESS", None))

    assert response["message"] == "重放成功"
    assert response["result"]["status"] == "applied"
    doc = _event_doc(db, "zpay", "lobster_sub_replay:TRADE_SUCCESS")
    assert doc["status"] == "done"
    assert doc["error"] is None
    assert db["users"].docs[0]["subscription_plan_code"] == "lite"
    assert db["payment_checkout_sessions"].docs[0]["status"] == "completed"


def test_replay_rejects_non_failed_event(monkeypatch):
    db = _webhook_db()
    db["webhook_events"].docs.append({
        "provider": "creem",
        "event_id": "evt_done",
        "raw": {"id": "evt_done"},
        "signature_ok": True,
        "status": "done",
    })
    monkeypatch.setattr(webhook_admin, "get_main_db", lambda: db)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(webhook_admin.admin_webhook_event_replay("creem", "evt_done", None))

    assert exc.value.status_code == 400
    assert "failed" in str(exc.value.detail)
