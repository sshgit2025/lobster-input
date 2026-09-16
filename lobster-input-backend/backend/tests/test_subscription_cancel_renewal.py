"""用户取消订阅(自动续费)链路单测。

覆盖:
- /api/v1/config/plan 响应新增订阅管理字段(auto_renew / next_renewal_at / renewal_cancellable);
- /api/v1/subscription/cancel-renewal 客户端代理:注入登录用户 email、HMAC 签名、
  不向客户端暴露 channel_sync;
- 管理端 auto-renew 开关的渠道拉齐:关闭时 best-effort 同步取消 Creem 代扣,
  开启时对已有 Creem 订阅 id 的用户拒绝(渠道代扣无法程序化恢复)。
"""
import asyncio
import hmac
import json
from datetime import datetime, timedelta, timezone
from hashlib import sha256

import httpx
import pytest

from app.api.v1 import payments, plan_admin
from app.models.schemas import UserPlanInfo
from app.repositories import plan_repository, user_repository
from app.services.billing.plan_service import PlanService


def _run(coro):
    return asyncio.run(coro)


# ── PlanService.get_user_plan_info 订阅管理字段 ────────────
class _FakePlanRepo:
    async def get_registration_enabled(self):
        return True

    async def get_invite_code_enabled(self):
        return False

    async def get_show_invite_codes_enabled(self):
        return False

    async def get_show_subscription_module_enabled(self):
        return True

    async def get_plan_config(self, code):
        return {"code": code, "credits": 9000, "reset_period": "month", "paid": True, "rank": 10}


class _FakeUserRepo:
    def __init__(self, user):
        self.user = dict(user)

    async def find_by_email(self, email):
        return dict(self.user) if self.user.get("email") == email else None


class _FakeGrantRepo:
    async def refresh_statuses(self, email, now=None):
        return 0

    async def get_available_total(self, email, *args, **kwargs):
        return 0

    async def list_active_grants(self, email):
        return []


def _plan_info_service(user):
    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo()
    return service


def _subscribed_user(now, **overrides):
    user = {
        "email": "u@example.com",
        "subscription_plan_code": "lite",
        "subscription_billing_cycle": "monthly",
        "subscription_status": "active",
        "subscription_auto_renew": True,
        "subscription_expires_at": now + timedelta(days=20),
        "plan_expires_at": now + timedelta(days=20),
        "plan_current_period_end": now + timedelta(days=10),
        "plan_credits_total": 9000,
        "plan_credits_used": 100,
    }
    user.update(overrides)
    return user


def test_plan_info_exposes_renewal_fields_when_auto_renew_on():
    now = datetime.now(timezone.utc)
    user = _subscribed_user(now)
    info = _run(_plan_info_service(user).get_user_plan_info("u@example.com"))

    assert info["auto_renew"] is True
    assert info["next_renewal_at"] == user["subscription_expires_at"]
    assert info["renewal_cancellable"] is True
    # 既有字段不破坏
    assert info["tier"] == "lite"
    assert info["subscription_auto_renew"] is True
    assert info["subscription_expires_at"] == user["subscription_expires_at"]
    # 响应模型可正常序列化(response_model 不会丢字段)
    model = UserPlanInfo(**info)
    assert model.renewal_cancellable is True


def test_plan_info_renewal_fields_when_auto_renew_off():
    now = datetime.now(timezone.utc)
    user = _subscribed_user(now, subscription_auto_renew=False)
    info = _run(_plan_info_service(user).get_user_plan_info("u@example.com"))

    assert info["auto_renew"] is False
    assert info["next_renewal_at"] is None
    assert info["renewal_cancellable"] is False


# ── 客户端 /api/v1/subscription/cancel-renewal 代理 ────────
class _FakeHttpResponse:
    status_code = 200

    def __init__(self, payload):
        self._payload = payload
        self.text = json.dumps(payload)

    def json(self):
        return self._payload


def _patch_payment_service_http(monkeypatch, captured, payload):
    async def fake_runtime_config():
        return {
            "callback_internal_key": "internal-key",
            "service_url": "https://payment.example.com",
            "checkout_public_base_url": "",
        }

    class _FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        async def request(self, method, url, content=None, headers=None):
            captured.append({"method": method, "url": url, "content": content, "headers": headers})
            return _FakeHttpResponse(payload)

    monkeypatch.setattr(payments, "load_payment_runtime_config", fake_runtime_config)
    monkeypatch.setattr(httpx, "AsyncClient", _FakeAsyncClient)


def test_cancel_renewal_proxy_injects_session_email_and_hides_channel_sync(monkeypatch):
    captured = []
    _patch_payment_service_http(monkeypatch, captured, {
        "status": "cancelled",
        "effective_until": "2026-08-01T00:00:00+00:00",
        "channel_sync": "ok",
    })

    result = _run(payments.cancel_subscription_renewal(payload={"sub": "u@example.com"}))

    # 透传 status / effective_until,channel_sync 为内部字段不暴露给客户端
    assert result == {"status": "cancelled", "effective_until": "2026-08-01T00:00:00+00:00"}
    assert len(captured) == 1
    call = captured[0]
    assert call["method"] == "POST"
    assert call["url"] == "https://payment.example.com/api/v1/payments/subscription/cancel-renewal"
    # body 注入登录态 email,绝不信任客户端传入
    assert json.loads(call["content"]) == {"user_email": "u@example.com"}
    # X-Callback HMAC 签名可被支付端 verify_callback_key 验证
    headers = call["headers"]
    assert headers["X-API-Key"] == "internal-key"
    signed = b"\n".join([
        b"POST",
        b"/api/v1/payments/subscription/cancel-renewal",
        b"",
        headers["X-Callback-Timestamp"].encode("utf-8"),
        call["content"],
    ])
    expected = hmac.new(b"internal-key", signed, sha256).hexdigest()
    assert headers["X-Callback-Signature"] == expected


def test_cancel_renewal_proxy_passes_through_idempotent_status(monkeypatch):
    captured = []
    _patch_payment_service_http(monkeypatch, captured, {
        "status": "already_cancelled",
        "effective_until": None,
    })

    result = _run(payments.cancel_subscription_renewal(payload={"sub": "u@example.com"}))

    assert result == {"status": "already_cancelled", "effective_until": None}


# ── 管理端 auto-renew 渠道拉齐 ─────────────────────────────
class _Result:
    def __init__(self, matched=0, modified=0):
        self.matched_count = matched
        self.modified_count = modified


class _Collection:
    def __init__(self):
        self.docs = []

    async def find_one(self, query, projection=None):
        for doc in self.docs:
            if all(doc.get(k) == v for k, v in query.items()):
                return dict(doc)
        return None

    async def insert_one(self, doc):
        self.docs.append(dict(doc))
        return _Result(1, 1)

    async def update_one(self, query, update, upsert=False):
        for doc in self.docs:
            if all(doc.get(k) == v for k, v in query.items()):
                doc.update(update.get("$set", {}))
                return _Result(1, 1)
        if upsert:
            doc = {k: v for k, v in query.items() if not isinstance(v, dict)}
            doc.update(update.get("$set", {}))
            self.docs.append(doc)
        return _Result(0, 0)


class _FakeDB:
    def __init__(self):
        self.cols = {}

    def __getitem__(self, name):
        return self.cols.setdefault(name, _Collection())


@pytest.fixture
def fake_db(monkeypatch):
    db = _FakeDB()
    for mod in (plan_admin, plan_repository, user_repository):
        monkeypatch.setattr(mod, "get_db", lambda: db, raising=True)
    return db


def _seed_creem_user(fake_db, *, auto_renew=True):
    now = datetime.now(timezone.utc)
    user = {
        "email": "u@example.com",
        "subscription_plan_code": "lite",
        "plan_code": "lite",
        "tier": "lite",
        "subscription_billing_cycle": "monthly",
        "subscription_auto_renew": auto_renew,
        "subscription_expires_at": now + timedelta(days=20),
        "latest_payment_provider": "creem",
        "latest_provider_subscription_id": "sub_1",
        "created_at": now,
    }
    fake_db["users"].docs.append(user)
    return user


def test_admin_auto_renew_off_syncs_channel_cancel(fake_db, monkeypatch):
    _seed_creem_user(fake_db, auto_renew=True)
    calls = []

    async def fake_post(path, payload):
        calls.append({"path": path, "payload": payload})
        return {"status": "cancelled", "effective_until": None, "channel_sync": "ok"}

    monkeypatch.setattr(plan_admin, "_post_payment_service", fake_post)
    req = plan_admin.AutoRenewRequest(email="u@example.com", auto_renew=False, admin_email="a@x.com")
    resp = _run(plan_admin.update_auto_renew(req, _={}))

    assert resp["channel_sync"] == "ok"
    assert calls == [{
        "path": "/api/v1/payments/subscription/cancel-renewal",
        "payload": {"user_email": "u@example.com"},
    }]
    assert fake_db["users"].docs[0]["subscription_auto_renew"] is False
    assert fake_db["subscription_events"].docs[0]["channel_sync"] == "ok"


def test_admin_auto_renew_off_channel_failure_does_not_block(fake_db, monkeypatch):
    _seed_creem_user(fake_db, auto_renew=True)

    async def fail_post(path, payload):
        raise RuntimeError("payment service unreachable")

    monkeypatch.setattr(plan_admin, "_post_payment_service", fail_post)
    req = plan_admin.AutoRenewRequest(email="u@example.com", auto_renew=False, admin_email="a@x.com")
    resp = _run(plan_admin.update_auto_renew(req, _={}))

    assert resp["channel_sync"] == "failed"
    assert fake_db["users"].docs[0]["subscription_auto_renew"] is False


def test_admin_auto_renew_on_rejected_for_creem_subscription(fake_db, monkeypatch):
    # 渠道代扣取消后无法程序化恢复:本地 OFF→ON 会造成状态分裂,一律拒绝
    _seed_creem_user(fake_db, auto_renew=False)

    async def unexpected_post(path, payload):
        raise AssertionError("开启自动续费不应调用支付端")

    monkeypatch.setattr(plan_admin, "_post_payment_service", unexpected_post)
    req = plan_admin.AutoRenewRequest(email="u@example.com", auto_renew=True, admin_email="a@x.com")
    with pytest.raises(Exception) as exc:
        _run(plan_admin.update_auto_renew(req, _={}))

    assert getattr(exc.value, "status_code", None) == 400
    assert fake_db["users"].docs[0]["subscription_auto_renew"] is False


def test_admin_auto_renew_off_for_zpay_user_skips_channel(fake_db, monkeypatch):
    # zpay 用户无渠道代扣,关闭只改本地,不调支付端
    user = _seed_creem_user(fake_db, auto_renew=True)
    user["latest_payment_provider"] = "zpay"
    user["latest_provider_subscription_id"] = None
    calls = []

    async def fake_post(path, payload):
        calls.append(path)
        return {}

    monkeypatch.setattr(plan_admin, "_post_payment_service", fake_post)
    req = plan_admin.AutoRenewRequest(email="u@example.com", auto_renew=False, admin_email="a@x.com")
    resp = _run(plan_admin.update_auto_renew(req, _={}))

    assert resp["channel_sync"] is None
    assert not calls
    assert fake_db["users"].docs[0]["subscription_auto_renew"] is False


def test_plan_info_apple_managed_subscription_is_not_cancellable():
    # Apple IAP 用户:auto_renew 展示为 True,但取消只能走 App Store,
    # renewal_cancellable 恒 False,客户端据此展示「请在应用商店管理」而非取消入口
    now = datetime.now(timezone.utc)
    user = _subscribed_user(now, latest_payment_provider="apple")
    info = _run(_plan_info_service(user).get_user_plan_info("u@example.com"))

    assert info["auto_renew"] is True
    assert info["next_renewal_at"] == user["subscription_expires_at"]
    assert info["renewal_cancellable"] is False
