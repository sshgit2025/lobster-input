import asyncio
import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi import HTTPException

from app.api.v1.schemas import (
    CancelRenewalRequest,
    CreateCreditTopupCheckoutRequest,
    CreateSubscriptionCheckoutRequest,
    CreditTopupPaymentRequest,
    SubscriptionPaymentRequest,
)
from app.api.v1.payments import (
    _can_replace_immediately,
    _can_self_checkout,
    _clean_plan_config,
    _masked_billing_config,
    _merge_existing_channel_secrets,
    _resolve_change_mode,
    _unused_refund_amount,
    cancel_subscription_renewal,
    create_credits_topup_checkout,
    create_subscription_checkout,
    credits_topup_callback,
    subscription_callback,
)
from app.api.v1 import payments
from app.api.v1.payments import _common as _pay_common
from app.api.v1.payments import checkout as _pay_checkout
from app.api.v1.payments import subscription as _pay_subscription
from app.api.v1.payments import callback as _pay_callback
from app.api.v1.payments import webhook as _pay_webhook
from app.services.payment_providers import creem as creem_module
from app.services.payment_providers.creem import CREEM_HEADERS, CreemPaymentProviderAdapter
from app.services.payment_providers.zpay import ZPayPaymentProviderAdapter


# 计费域已由单文件 payments.py 拆分为 payments/ 包。各端点在其所属子模块
# (checkout/subscription/callback/webhook)与共享内核 _common 内按裸名解析可替换依赖
# (get_main_db / load_billing_config / _payment_context_for_account /
# CreditGrantLifecycleCoordinator)。因此打桩须覆盖所有承载该依赖的模块,才能命中
# 实际执行处的绑定——单打包级 payments 属性对子模块内的裸名调用不生效。
_PAY_MODULES = (payments, _pay_common, _pay_checkout, _pay_subscription, _pay_callback, _pay_webhook)


def _patch_all(monkeypatch, name, value):
    """把依赖 name 打桩到所有承载它的支付模块上(拆包后跨子模块统一替换)。"""
    for _m in _PAY_MODULES:
        if hasattr(_m, name):
            monkeypatch.setattr(_m, name, value, raising=False)


def _run_creem_event(db, profile, event_id, event_type, obj, *, adapter=None):
    """驱动 creem webhook 走新链路:adapter.normalize_webhook_event → dispatch_webhook_event。"""
    ad = adapter or CreemPaymentProviderAdapter(profile)
    raw_body = json.dumps({"id": event_id, "eventType": event_type, "object": obj}).encode("utf-8")
    event = asyncio.run(ad.normalize_webhook_event(db, raw_body, None))
    return asyncio.run(payments.dispatch_webhook_event(db, profile, ad, event))


def _run_zpay_event(db, profile, raw_body):
    ad = ZPayPaymentProviderAdapter(profile)
    event = asyncio.run(ad.normalize_webhook_event(db, raw_body, None))
    return asyncio.run(payments.dispatch_webhook_event(db, profile, ad, event))


def _recording_creem_adapter(profile=None):
    """真实 Creem adapter(normalize 走真逻辑)+ 记录 cancel_subscription 调用。"""
    ad = CreemPaymentProviderAdapter(profile or _payment_profile())
    ad.cancelled = []

    async def _rec(subscription_id, *, mode="immediate", on_execute=""):
        ad.cancelled.append({"subscription_id": subscription_id, "mode": mode})
        return {"id": subscription_id, "status": "canceled"}

    ad.cancel_subscription = _rec
    return ad
from app.services.billing.config import clean_billing_config


class _FakePaymentAdapter:
    code = "creem"
    display_name = "Creem"
    supports_recurring = True
    supports_discount_codes = True
    supports_customer_portal = True
    order_mode = "external_product"
    webhook_signature_header = "creem-signature"
    webhook_ack_text = None

    def __init__(self):
        # webhook 解析(normalize/event_id/rebuild)委托给真实 Creem adapter,验签/下单用桩
        self._webhook = CreemPaymentProviderAdapter({})

    async def product_details(self, product_map):
        return {key: {"product_id": product_id, "price_cents": 100, "currency": "USD"} for key, product_id in product_map.items()}

    async def product_by_id(self, product_id):
        return {"product_id": product_id, "price_cents": 100, "currency": "USD"} if product_id else {}

    async def create_checkout(self, **kwargs):
        assert kwargs["product_id"] in {"prod_lite", "prod_topup"}
        assert kwargs["user_email"] == "user@example.com"
        assert "/api/v1/payments/creem/return?request_id=lobster_" in kwargs["success_url"]
        return {"id": "ch_test", "checkout_url": "https://checkout.creem.io/ch_test", "status": "pending"}

    def verify_webhook_signature(self, *_args, **_kwargs):
        return None

    def webhook_verify_body(self, raw_body, request):
        return raw_body

    def webhook_signature(self, request):
        return None

    def webhook_event_id(self, raw_body, request):
        return self._webhook.webhook_event_id(raw_body, request)

    def webhook_ingest_raw(self, raw_body, request):
        return self._webhook.webhook_ingest_raw(raw_body, request)

    def rebuild_webhook_body(self, raw):
        return self._webhook.rebuild_webhook_body(raw)

    async def normalize_webhook_event(self, db, raw_body, request):
        return await self._webhook.normalize_webhook_event(db, raw_body, request)


class _DiscountRetryAdapter(_FakePaymentAdapter):
    def __init__(self):
        self.discount_codes = []

    async def create_checkout(self, **kwargs):
        self.discount_codes.append(kwargs.get("discount_code") or "")
        if kwargs.get("discount_code") == "LAUNCH50":
            raise HTTPException(
                status_code=502,
                detail={
                    "message": "Creem checkout 创建失败",
                    "creem_status": 400,
                    "creem_body": '{"message":"Discount cannot be applied to the product."}',
                },
            )
        return await super().create_checkout(**kwargs)


def _payment_profile(**overrides):
    profile = {
        "id": "creem_test",
        "provider_code": "creem",
        "name": "Creem Test",
        "enabled": True,
        "environment": "test",
        "api_base_url": "https://test-api.creem.io",
        "api_key": "test-key",
        "webhook_secret": "test-secret",
        "subscription_product_map": {"lite:monthly": "prod_lite"},
        "topup_product_id": "prod_topup",
        "topup_credits": 10000,
    }
    profile.update(overrides)
    return profile


def _patch_payment_context(monkeypatch, profile=None, adapter=None):
    account = profile or _payment_profile()

    async def fake_context(_account):
        return account, adapter or _FakePaymentAdapter()

    async def fake_billing_config(*_args, **_kwargs):
        return {
            "products": [
                {
                    "code": "lite_monthly",
                    "type": "subscription",
                    "name": "Lite Monthly",
                    "plan_code": "lite",
                    "billing_cycle": "monthly",
                    "enabled": True,
                    "sort_order": 10,
                },
                {
                    "code": "credits_topup",
                    "type": "credits_topup",
                    "name": "Topup",
                    "topup_credits": int(account.get("topup_credits") or 10000),
                    "enabled": True,
                    "sort_order": 100,
                },
            ],
            "currencies": [
                {"code": "USD", "name": "美元", "rate_to_usd": 1, "enabled": True},
            ],
            "payment_methods": [{"code": "card", "name": "Card", "enabled": True, "sort_order": 10, "currencies": ["USD"], "channel_code": "creem"}],
            "channels": [{
                "code": "creem",
                "provider_code": account.get("provider_code"),
                "name": "Creem",
                "enabled": True,
                "active_account_code": account.get("id"),
                "accounts": [{**account, "code": account.get("id")}],
            }],
            "channel_prices": [
                {
                    "product_code": "lite_monthly",
                    "payment_method": "card",
                    "channel_code": "creem",
                    "account_code": account.get("id"),
                    "mode": "external_product",
                    "external_product_id": "prod_lite",
                    "currency": "USD",
                    "amount_cents": 100,
                    "discount_mode": "auto_apply" if account.get("binding_discount_code") else "none",
                    "discount_code": account.get("binding_discount_code") or "",
                    "enabled": True,
                },
                {"product_code": "credits_topup", "payment_method": "card", "channel_code": "creem", "account_code": account.get("id"), "mode": "external_product", "external_product_id": "prod_topup", "currency": "USD", "amount_cents": 100, "enabled": True},
            ],
        }

    _patch_all(monkeypatch,"_payment_context_for_account", fake_context)
    _patch_all(monkeypatch,"load_billing_config", fake_billing_config)
    # creem adapter 的 webhook normalize 也用 billing_config 解析 product→plan(续费无 checkout 时)
    monkeypatch.setattr(creem_module, "load_billing_config", fake_billing_config)


class _Cursor:
    def __init__(self, rows):
        self.rows = rows

    def sort(self, *_args, **_kwargs):
        return self

    def limit(self, *_args, **_kwargs):
        return self

    async def to_list(self, length=None):
        return self.rows[:length] if length else list(self.rows)


class _AggregateCursor(_Cursor):
    pass


class _Collection:
    def __init__(self, docs=None):
        self.docs = list(docs or [])
        self.inserted = []
        self.updated = []

    async def find_one(self, query):
        for doc in self.docs:
            if _matches(doc, query):
                return doc
        return None

    async def insert_one(self, doc):
        self.docs.append(doc)
        self.inserted.append(doc)
        return type("InsertResult", (), {"inserted_id": "inserted-id"})()

    async def update_one(self, query, update, upsert=False):
        self.updated.append((query, update))
        for doc in self.docs:
            if _matches(doc, query):
                _apply_update(doc, update)
                return type("UpdateResult", (), {"modified_count": 1})()
        if upsert:
            doc = {key: value for key, value in query.items() if not key.startswith("$")}
            _apply_update(doc, update, is_insert=True)
            self.docs.append(doc)
            return type("UpdateResult", (), {"modified_count": 0, "upserted_id": "upserted-id"})()
        return type("UpdateResult", (), {"modified_count": 0})()

    def find(self, query):
        return _Cursor([doc for doc in self.docs if _matches(doc, query)])

    def aggregate(self, _pipeline):
        total = 0
        now = datetime.now(timezone.utc)
        for doc in self.docs:
            expires_at = doc.get("expires_at")
            if doc.get("status") == "active" and (expires_at is None or expires_at > now):
                total += max(0, int(doc.get("amount_total", 0)) - int(doc.get("amount_used", 0)))
        return _AggregateCursor([{"_id": None, "total": total}] if total else [])


class _Db(dict):
    def __getitem__(self, key):
        if key not in self:
            self[key] = _Collection()
        return dict.__getitem__(self, key)


class _FakeLifecycle:
    def __init__(self, _db):
        self.db = _db

    async def refresh_for_user(self, *_args, **_kwargs):
        return {}

    async def apply_subscription_activation(self, *_args, **_kwargs):
        return {"paid_topups": 0, "subscription_linked": 0}


def _matches(doc, query):
    for key, expected in query.items():
        if key == "$and":
            if not all(_matches(doc, item) for item in expected):
                return False
            continue
        if key == "$or":
            if not any(_matches(doc, item) for item in expected):
                return False
            continue
        value = doc.get(key)
        if isinstance(expected, dict):
            if "$gt" in expected and not (value is not None and value > expected["$gt"]):
                return False
            if "$exists" in expected and (key in doc) != expected["$exists"]:
                return False
            continue
        if value != expected:
            return False
    return True


def _apply_update(doc, update, is_insert=False):
    for key, value in update.get("$set", {}).items():
        doc[key] = value
    if is_insert:
        # $setOnInsert 仅在 upsert 新建文档时生效(重投命中已有文档时不覆盖,保证幂等)
        for key, value in update.get("$setOnInsert", {}).items():
            doc[key] = value
    for key, value in update.get("$inc", {}).items():
        doc[key] = doc.get(key, 0) + value


def _plan_configs():
    return {
        "free": {"code": "free", "paid": False, "rank": 0, "credits": 500, "reset_period": "week"},
        "trial": {"code": "trial", "paid": False, "rank": 0, "credits": 10_000, "reset_period": "month"},
        "lite": {
            "code": "lite",
            "paid": True,
            "rank": 10,
            "credits": 20_000,
            "reset_period": "month",
            "billing_options": {
                "monthly": {
                    "enabled": True,
                    "duration_count": 1,
                    "duration_period": "month",
                }
            },
        },
        "pro": {
            "code": "pro",
            "paid": True,
            "rank": 30,
            "credits": 100_000,
            "reset_period": "month",
            "billing_options": {
                "monthly": {
                    "enabled": True,
                    "duration_count": 1,
                    "duration_period": "month",
                }
            },
        },
    }


def _db(user, *, grants=None, events=None, system_config_extra=None):
    return _Db({
        "users": _Collection([user]),
        "system_config": _Collection([{"key": "plan_configs", "value": _plan_configs()}] + (system_config_extra or [])),
        "payment_callback_events": _Collection(events or []),
        "payment_orders": _Collection(),
        "payment_attempts": _Collection(),
        "payment_transactions": _Collection(),
        "payment_refunds": _Collection(),
        "credit_grants": _Collection(grants or []),
        "subscription_refund_events": _Collection(),
    })


@pytest.fixture(autouse=True)
def _patch_db_and_lifecycle(monkeypatch):
    _patch_all(monkeypatch,"CreditGrantLifecycleCoordinator", _FakeLifecycle)


def test_equal_or_higher_rank_can_replace_immediately():
    assert _can_replace_immediately({"rank": 0}, {"rank": 0}) is True
    assert _can_replace_immediately({"rank": 0}, {"rank": 10}) is True
    assert _can_replace_immediately({"rank": 20}, {"rank": 10}) is False


def test_self_checkout_requires_paid_active_base_plan():
    paid = _clean_plan_config("lite", {"paid": True, "rank": 10})
    trial = _clean_plan_config("trial", {"paid": False})
    archived = _clean_plan_config("pro", {"paid": True, "lifecycle_status": "archived"})
    addon = _clean_plan_config("addon", {"paid": True, "plan_family": "addon"})

    assert _can_self_checkout(paid) is True
    assert _can_self_checkout(trial) is False
    assert _can_self_checkout(archived) is False
    assert _can_self_checkout(addon) is False


def test_plan_auto_renew_supported_is_catalog_capability():
    unsupported = _clean_plan_config("lite", {"paid": True, "auto_renew_supported": False})
    supported = _clean_plan_config("lite", {"paid": True, "auto_renew_supported": True})

    assert unsupported["auto_renew_supported"] is False
    assert supported["auto_renew_supported"] is True


def test_plan_validity_fields_are_cleaned_without_changing_billing_duration():
    trial = _clean_plan_config("trial", {"paid": False, "validity_period": "day", "validity_count": 7})
    free = _clean_plan_config("free", {"paid": False, "validity_period": "forever", "validity_count": 12})
    paid = _clean_plan_config("lite", {"paid": True})

    assert trial["validity_period"] == "day"
    assert trial["validity_count"] == 7
    assert free["validity_period"] == "forever"
    assert free["validity_count"] == 0
    assert paid["validity_period"] == "month"
    assert paid["validity_count"] == 1


def test_creem_adapter_normalizes_provider_minor_units():
    product = CreemPaymentProviderAdapter._normalize_product({
        "id": "prod_lite",
        "name": "Lobster Light Subscribe",
        "price": 100,
        "currency": "usd",
        "billing_type": "recurring",
        "billing_period": "monthly",
        "status": "active",
    })

    assert product is not None
    assert product.product_id == "prod_lite"
    assert product.price_cents == 100
    assert product.currency == "USD"
    assert product.to_dict()["price_cents"] == 100


def test_creem_adapter_uses_stable_user_agent_header():
    assert CREEM_HEADERS["User-Agent"].startswith("LobsterInputPayment/")


def test_zpay_adapter_creates_signed_wechat_checkout_url():
    adapter = ZPayPaymentProviderAdapter({
        "provider_code": "zpay",
        "merchant_id": "2025082621264355",
        "api_base_url": "https://zpayz.cn",
        "api_key": "secret-key",
    })

    checkout = asyncio.run(adapter.create_checkout(
        product_id="",
        request_id="lobster_sub_test",
        user_email="user@example.com",
        success_url="https://example.com/lobster/payment/api/v1/payments/zpay/return?request_id=lobster_sub_test",
        notify_url="https://example.com/lobster/payment/api/v1/payments/webhook/zpay",
        product_name="Lite Monthly",
        amount_cents=990,
        currency="CNY",
        payment_method="wechat",
    ))

    assert checkout["id"] == "lobster_sub_test"
    assert checkout["checkout_url"].startswith("https://zpayz.cn/submit.php?")
    assert "type=wxpay" in checkout["checkout_url"]
    assert "money=9.90" in checkout["checkout_url"]
    assert "return_url=https%3A%2F%2Fexample.com%2Flobster%2Fpayment%2Fapi%2Fv1%2Fpayments%2Fzpay%2Freturn" in checkout["checkout_url"]
    assert "sign_type=MD5" in checkout["checkout_url"]
    assert "sign=" in checkout["checkout_url"]


def test_clean_billing_config_keeps_same_product_on_multiple_channels():
    config = clean_billing_config({
        "products": [{"code": "pro_yearly", "type": "subscription", "name": "Pro Yearly", "plan_code": "pro", "billing_cycle": "yearly", "enabled": True}],
        "currencies": [{"code": "USD", "name": "美元", "rate_to_usd": 1, "enabled": True}, {"code": "CNY", "name": "人民币", "rate_to_usd": 0.138, "enabled": True}],
        "payment_methods": [
            {"code": "card", "name": "Card", "enabled": True, "currencies": ["USD"], "channel_code": "creem"},
            {"code": "wechat", "name": "Wechat", "enabled": True, "currencies": ["CNY"], "channel_code": "zpay"},
        ],
        "channels": [
            {"code": "creem", "provider_code": "creem", "name": "Creem", "enabled": True, "active_account_code": "creem_test", "accounts": [{"code": "creem_test", "name": "Creem Test", "enabled": True}]},
            {"code": "zpay", "provider_code": "zpay", "name": "ZPay", "enabled": True, "active_account_code": "zpay_live", "accounts": [{"code": "zpay_live", "name": "ZPay Live", "enabled": True}]},
        ],
        "channel_prices": [
            {"product_code": "pro_yearly", "payment_method": "card", "channel_code": "creem", "account_code": "creem_test", "currency": "USD", "amount_cents": 20000, "mode": "external_product", "external_product_id": "prod_pro_year"},
            {"product_code": "pro_yearly", "payment_method": "wechat", "channel_code": "zpay", "account_code": "zpay_live", "currency": "CNY", "amount_cents": 144928, "mode": "amount_order"},
        ],
    })

    assert len(config["channel_prices"]) == 2
    assert {row["channel_code"] for row in config["channel_prices"]} == {"creem", "zpay"}


def test_create_subscription_checkout_records_pending_session(monkeypatch):
    db = _db({"email": "user@example.com", "subscription_plan_code": "free"})
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_payment_context(monkeypatch)

    result = asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="creem",
        user_email="user@example.com",
        plan_code="lite",
        billing_cycle="monthly",
        discount_code="LAUNCH50",
    ), None))

    assert result["checkout_url"] == "https://checkout.creem.io/ch_test"
    assert db["payment_checkout_sessions"].docs[0]["kind"] == "subscription"
    assert db["payment_checkout_sessions"].docs[0]["discount_code"] == "LAUNCH50"


def test_create_subscription_checkout_retries_without_auto_product_discount(monkeypatch):
    db = _db({"email": "user@example.com", "subscription_plan_code": "free"})
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    adapter = _DiscountRetryAdapter()
    _patch_payment_context(monkeypatch, profile=_payment_profile(binding_discount_code="LAUNCH50"), adapter=adapter)

    result = asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="creem",
        user_email="user@example.com",
        plan_code="lite",
        billing_cycle="monthly",
    ), None))

    assert result["checkout_url"] == "https://checkout.creem.io/ch_test"
    assert adapter.discount_codes == ["LAUNCH50", ""]
    assert db["payment_checkout_sessions"].docs[0]["discount_code"] == ""


def test_create_subscription_checkout_rejects_when_client_module_disabled(monkeypatch):
    db = _db(
        {"email": "user@example.com", "subscription_plan_code": "free"},
        system_config_extra=[{"key": "show_subscription_module_enabled", "value": False}],
    )
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_payment_context(monkeypatch)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
            provider="creem",
            user_email="user@example.com",
            plan_code="lite",
            billing_cycle="monthly",
        ), None))

    assert exc.value.status_code == 403


def test_create_subscription_checkout_rejects_active_same_plan(monkeypatch):
    db = _db({
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_expires_at": datetime.now(timezone.utc) + timedelta(days=20),
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_payment_context(monkeypatch)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
            provider="creem",
            user_email="user@example.com",
            plan_code="lite",
            billing_cycle="monthly",
        ), None))

    assert exc.value.status_code == 400


def test_create_subscription_checkout_rejects_active_downgrade(monkeypatch):
    db = _db({
        "email": "user@example.com",
        "subscription_plan_code": "pro",
        "subscription_expires_at": datetime.now(timezone.utc) + timedelta(days=20),
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_payment_context(monkeypatch)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
            provider="creem",
            user_email="user@example.com",
            plan_code="lite",
            billing_cycle="monthly",
        ), None))

    assert exc.value.status_code == 400


def test_creem_subscription_paid_applies_subscription_from_product_mapping(monkeypatch):
    db = _db({"email": "user@example.com", "subscription_plan_code": "free"})
    db["payment_checkout_sessions"].docs.append({
        "request_id": "req-sub",
        "provider": "creem",
        "kind": "subscription",
        "status": "pending",
        "user_email": "user@example.com",
        "plan_code": "lite",
        "billing_cycle": "monthly",
        "settlement_mode": "full_price",
        "auto_renew": True,
        "product_id": "prod_lite",
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    profile = _payment_profile()

    result = _run_creem_event(db, profile, "evt-paid", "subscription.paid", {
        "id": "sub_1",
        "product": {"id": "prod_lite", "price": 1200},
        "customer": {"email": "user@example.com", "id": "cust_1"},
        "last_transaction_id": "tran_1",
        "metadata": {"request_id": "req-sub"},
    })

    user = db["users"].docs[0]
    assert result["status"] == "applied"
    assert user["subscription_plan_code"] == "lite"
    assert user["latest_provider_subscription_id"] == "sub_1"
    assert db["payment_checkout_sessions"].docs[0]["status"] == "completed"


def test_creem_checkout_completed_applies_credit_topup(monkeypatch):
    expires_at = datetime.now(timezone.utc) + timedelta(days=20)
    db = _db({
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_expires_at": expires_at,
        "plan_credits_total": 100,
        "plan_credits_used": 100,
    })
    db["payment_checkout_sessions"].docs.append({
        "request_id": "req-topup",
        "checkout_id": "ch_topup",
        "provider": "creem",
        "kind": "credits_topup",
        "status": "pending",
        "user_email": "user@example.com",
        "amount": 10000,
        "product_id": "prod_topup",
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    profile = _payment_profile(topup_product_id="prod_topup", topup_credits=10000)

    result = _run_creem_event(db, profile, "evt-topup-paid", "checkout.completed", {
        "id": "ch_topup",
        "request_id": "req-topup",
        "product": {"id": "prod_topup"},
        "order": {"id": "ord_1"},
        "customer": {"id": "cust_1"},
    })

    assert result["status"] == "applied"
    assert db["credit_grants"].docs[0]["amount_total"] == 10000
    assert db["payment_checkout_sessions"].docs[0]["status"] == "completed"


def test_resolve_change_mode_rejects_immediate_downgrade():
    with pytest.raises(HTTPException):
        _resolve_change_mode(
            {"subscription_billing_cycle": "monthly"},
            "pro",
            {"rank": 30, "billing_options": {}},
            "lite",
            {"rank": 10},
            "monthly",
            1,
            "month",
        )


def test_refund_amount_is_prorated_by_unused_entitlement():
    now = datetime(2026, 5, 15, tzinfo=timezone.utc)
    event = {
        "price_cents": 3000,
        "refunded_cents": 0,
        "result": {
            "entitlement_started_at": now - timedelta(days=15),
            "entitlement_expires_at": now + timedelta(days=15),
        },
    }

    assert _unused_refund_amount(event, now) == 1500


def test_subscription_callback_paid_plan_over_trial_resets_plan_credits(monkeypatch):
    user = {
        "email": "user@example.com",
        "subscription_plan_code": "trial",
        "subscription_expires_at": datetime.now(timezone.utc) + timedelta(days=10),
        "plan_credits_total": 10_000,
        "plan_credits_used": 9_999,
    }
    db = _db(user)
    _patch_all(monkeypatch,"get_main_db", lambda: db)

    result = asyncio.run(subscription_callback(SubscriptionPaymentRequest(
        payment_event_id="evt-activate-lite",
        user_email="user@example.com",
        plan_code="lite",
        paid_amount_cents=1200,
    )))

    assert result["status"] == "applied"
    assert result["change_mode"] == "activate_now"
    assert user["subscription_plan_code"] == "lite"
    assert user["plan_credits_total"] == 20_000
    assert user["plan_credits_used"] == 0
    assert user["credits_used"] == 0


def test_subscription_callback_same_plan_renews_without_resetting_current_usage(monkeypatch):
    user = {
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_billing_cycle": "monthly",
        "subscription_expires_at": datetime.now(timezone.utc) + timedelta(days=5),
        "plan_credits_total": 20_000,
        "plan_credits_used": 12_345,
    }
    db = _db(user)
    _patch_all(monkeypatch,"get_main_db", lambda: db)

    result = asyncio.run(subscription_callback(SubscriptionPaymentRequest(
        payment_event_id="evt-renew-lite",
        user_email="user@example.com",
        plan_code="lite",
        paid_amount_cents=1200,
    )))

    assert result["change_mode"] == "renew"
    assert user["subscription_plan_code"] == "lite"
    assert user["plan_credits_used"] == 12_345


def test_subscription_callback_rejects_trial_checkout(monkeypatch):
    db = _db({"email": "user@example.com", "subscription_plan_code": "free"})
    _patch_all(monkeypatch,"get_main_db", lambda: db)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(subscription_callback(SubscriptionPaymentRequest(
            payment_event_id="evt-trial-checkout",
            user_email="user@example.com",
            plan_code="trial",
        )))

    assert exc.value.status_code == 400


def test_subscription_callback_rejects_lower_rank_downgrade(monkeypatch):
    db = _db({
        "email": "user@example.com",
        "subscription_plan_code": "pro",
        "subscription_billing_cycle": "monthly",
        "subscription_expires_at": datetime.now(timezone.utc) + timedelta(days=10),
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(subscription_callback(SubscriptionPaymentRequest(
            payment_event_id="evt-downgrade-lite",
            user_email="user@example.com",
            plan_code="lite",
            paid_amount_cents=1200,
        )))

    assert exc.value.status_code == 400
    assert "降级" in exc.value.detail


def test_subscription_callback_duplicate_event_is_idempotent(monkeypatch):
    db = _db(
        {"email": "user@example.com", "subscription_plan_code": "free"},
        events=[{"payment_event_id": "evt-duplicate"}],
    )
    _patch_all(monkeypatch,"get_main_db", lambda: db)

    result = asyncio.run(subscription_callback(SubscriptionPaymentRequest(
        payment_event_id="evt-duplicate",
        user_email="user@example.com",
        plan_code="lite",
        paid_amount_cents=1200,
    )))

    assert result == {"status": "duplicate"}


def test_credit_topup_callback_inserts_paid_topup_when_paid_user_has_no_credits(monkeypatch):
    expires_at = datetime.now(timezone.utc) + timedelta(days=20)
    db = _db({
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_expires_at": expires_at,
        "plan_credits_total": 20_000,
        "plan_credits_used": 20_000,
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)

    result = asyncio.run(credits_topup_callback(CreditTopupPaymentRequest(
        payment_event_id="evt-topup",
        user_email="user@example.com",
        amount=5000,
    )))

    assert result["status"] == "applied"
    assert result["credit_type"] == "paid_topup"
    grant = db["credit_grants"].inserted[0]
    assert grant["amount_total"] == 5000
    assert grant["expires_at"] == expires_at


def test_credit_topup_callback_rejects_when_plan_credit_remains(monkeypatch):
    expires_at = datetime.now(timezone.utc) + timedelta(days=20)
    db = _db({
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_expires_at": expires_at,
        "plan_credits_total": 20_000,
        "plan_credits_used": 19_999,
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(credits_topup_callback(CreditTopupPaymentRequest(
            payment_event_id="evt-topup-blocked",
            user_email="user@example.com",
            amount=5000,
        )))

    assert exc.value.status_code == 400
    assert "套餐积分仍有剩余" in exc.value.detail


def test_admin_billing_config_masks_channel_secrets():
    config = {
        "channels": [
            {"code": "creem", "accounts": [
                {"code": "creem_test", "api_key": "key-123", "webhook_secret": "secret-123"},
                {"code": "manual", "api_key": "", "webhook_secret": ""},
            ]},
        ]
    }

    masked = _masked_billing_config(config)

    accounts = masked["channels"][0]["accounts"]
    assert accounts[0]["api_key"] == "__configured__"
    assert accounts[0]["webhook_secret"] == "__configured__"
    assert accounts[0]["api_key_configured"] is True
    assert accounts[1]["api_key"] == ""
    assert accounts[1]["api_key_configured"] is False


def test_admin_billing_config_preserves_existing_channel_secrets_when_empty_or_placeholder():
    current = {
        "channels": [{"code": "creem", "accounts": [
            {"code": "creem_test", "api_key": "old-key", "webhook_secret": "old-secret"},
            {"code": "new_key", "api_key": "replace-key", "webhook_secret": "replace-secret"},
        ]}]
    }
    payload = {
        "channels": [{"code": "creem", "accounts": [
            {"code": "creem_test", "api_key": "", "webhook_secret": "__configured__"},
            {"code": "new_key", "api_key": "new-key", "webhook_secret": "new-secret"},
        ]}]
    }

    merged = _merge_existing_channel_secrets(payload, current)

    accounts = merged["channels"][0]["accounts"]
    assert accounts[0]["api_key"] == "old-key"
    assert accounts[0]["webhook_secret"] == "old-secret"
    assert accounts[1]["api_key"] == "new-key"
    assert accounts[1]["webhook_secret"] == "new-secret"


# ---------------- 补差价升级(月付→年付等)规则 ----------------

class _AmountOrderAdapter:
    code = "zpay"
    display_name = "ZPay"
    supports_recurring = False
    supports_discount_codes = False
    order_mode = "amount_order"
    webhook_signature_header = ""
    webhook_ack_text = "success"

    def __init__(self):
        self.checkouts = []
        # webhook 解析委托给真实 ZPay adapter,验签/下单用桩
        self._webhook = ZPayPaymentProviderAdapter({})

    async def create_checkout(self, **kwargs):
        self.checkouts.append(kwargs)
        return {"id": "zp_test", "checkout_url": "https://pay.example.com/zp_test", "status": "pending"}

    def verify_webhook_signature(self, *_args, **_kwargs):
        return None

    def webhook_verify_body(self, raw_body, request):
        return self._webhook.webhook_verify_body(raw_body, request)

    def webhook_signature(self, request):
        return None

    def webhook_event_id(self, raw_body, request):
        return self._webhook.webhook_event_id(raw_body, request)

    def webhook_ingest_raw(self, raw_body, request):
        return self._webhook.webhook_ingest_raw(raw_body, request)

    def rebuild_webhook_body(self, raw):
        return self._webhook.rebuild_webhook_body(raw)

    async def normalize_webhook_event(self, db, raw_body, request):
        return await self._webhook.normalize_webhook_event(db, raw_body, request)


def _upgrade_plan_configs():
    configs = _plan_configs()
    for code in ("lite", "pro"):
        configs[code]["billing_options"]["yearly"] = {
            "enabled": True,
            "duration_count": 1,
            "duration_period": "year",
        }
    return configs


def _amount_order_billing_config():
    def _product(code, plan, cycle, amount):
        return (
            {"code": code, "type": "subscription", "name": code, "plan_code": plan, "billing_cycle": cycle, "enabled": True, "sort_order": 10},
            {"product_code": code, "payment_method": "wechat", "channel_code": "zpay", "account_code": "zpay_main", "mode": "amount_order", "external_product_id": "", "currency": "CNY", "amount_cents": amount, "enabled": True},
        )

    pairs = [
        _product("lite_monthly", "lite", "monthly", 1000),
        _product("lite_yearly", "lite", "yearly", 10000),
        _product("pro_monthly", "pro", "monthly", 3000),
        _product("pro_yearly", "pro", "yearly", 30000),
    ]
    return {
        "products": [p for p, _ in pairs],
        "currencies": [{"code": "CNY", "name": "人民币", "rate_to_usd": 0.14, "enabled": True}],
        "payment_methods": [{"code": "wechat", "name": "WeChat", "enabled": True, "sort_order": 10, "currencies": ["CNY"], "channel_code": "zpay"}],
        "channels": [{
            "code": "zpay",
            "provider_code": "zpay",
            "name": "ZPay",
            "enabled": True,
            "active_account_code": "zpay_main",
            "accounts": [{"code": "zpay_main", "id": "zpay_main", "provider_code": "zpay", "enabled": True}],
        }],
        "channel_prices": [r for _, r in pairs],
    }


def _patch_amount_order_context(monkeypatch, adapter=None):
    account = {"code": "zpay_main", "id": "zpay_main", "provider_code": "zpay", "enabled": True}

    async def fake_context(_account):
        return account, adapter or _AmountOrderAdapter()

    async def fake_billing_config(*_args, **_kwargs):
        return _amount_order_billing_config()

    _patch_all(monkeypatch,"_payment_context_for_account", fake_context)
    _patch_all(monkeypatch,"load_billing_config", fake_billing_config)


def _lite_monthly_user(now):
    return {
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_billing_cycle": "monthly",
        "subscription_expires_at": now + timedelta(days=15),
        "latest_payment_event_id": "evt-prev",
    }


def _lite_monthly_prev_event(now):
    return {
        "payment_event_id": "evt-prev",
        "event_type": "subscription",
        "status": "applied",
        "user_email": "user@example.com",
        "plan_code": "lite",
        "payment_order_id": "ord-prev",
        "result": {
            "entitlement_started_at": now - timedelta(days=15),
            "entitlement_expires_at": now + timedelta(days=15),
            "price_cents": 1000,
        },
    }


def _upgrade_db(monkeypatch, user, events=None, orders=None):
    db = _db(user, events=events)
    db["system_config"] = _Collection([{"key": "plan_configs", "value": _upgrade_plan_configs()}])
    for order in orders or []:
        db["payment_orders"].docs.append(order)
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    return db


def test_checkout_same_plan_monthly_to_yearly_charges_prorated_difference(monkeypatch):
    now = datetime.now(timezone.utc)
    adapter = _AmountOrderAdapter()
    db = _upgrade_db(
        monkeypatch,
        _lite_monthly_user(now),
        events=[_lite_monthly_prev_event(now)],
        orders=[{"order_id": "ord-prev", "currency": "CNY", "paid_amount_cents": 1000}],
    )
    _patch_amount_order_context(monkeypatch, adapter=adapter)

    result = asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="zpay",
        user_email="user@example.com",
        plan_code="lite",
        billing_cycle="yearly",
        payment_method="wechat",
    ), None))

    assert result["settlement_mode"] == "prorated_difference"
    # 抵扣 = 1000 * 剩余15天/共30天 ≈ 500，应付 = 10000 - 500
    assert 9499 <= result["amount_cents"] <= 9501
    assert result["list_price_cents"] == 10000
    assert adapter.checkouts[0]["amount_cents"] == result["amount_cents"]
    order = db["payment_orders"].docs[-1]
    assert order["settlement_mode"] == "prorated_difference"
    assert order["change_mode"] == "cycle_upgrade"
    assert order["amount_cents"] == result["amount_cents"]


def test_checkout_rejects_yearly_to_monthly_cycle_downgrade(monkeypatch):
    now = datetime.now(timezone.utc)
    user = {
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_billing_cycle": "yearly",
        "subscription_expires_at": now + timedelta(days=200),
    }
    _upgrade_db(monkeypatch, user)
    _patch_amount_order_context(monkeypatch)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
            provider="zpay",
            user_email="user@example.com",
            plan_code="lite",
            billing_cycle="monthly",
            payment_method="wechat",
        ), None))

    assert exc.value.status_code == 400
    assert "账期" in str(exc.value.detail)


def test_checkout_rejects_higher_tier_with_shorter_cycle_after_yearly(monkeypatch):
    now = datetime.now(timezone.utc)
    user = {
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_billing_cycle": "yearly",
        "subscription_expires_at": now + timedelta(days=200),
    }
    _upgrade_db(monkeypatch, user)
    _patch_amount_order_context(monkeypatch)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
            provider="zpay",
            user_email="user@example.com",
            plan_code="pro",
            billing_cycle="monthly",
            payment_method="wechat",
        ), None))

    assert exc.value.status_code == 400


def test_checkout_higher_tier_same_cycle_charges_prorated_difference(monkeypatch):
    now = datetime.now(timezone.utc)
    adapter = _AmountOrderAdapter()
    _upgrade_db(
        monkeypatch,
        _lite_monthly_user(now),
        events=[_lite_monthly_prev_event(now)],
        orders=[{"order_id": "ord-prev", "currency": "CNY", "paid_amount_cents": 1000}],
    )
    _patch_amount_order_context(monkeypatch, adapter=adapter)

    result = asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="zpay",
        user_email="user@example.com",
        plan_code="pro",
        billing_cycle="monthly",
        payment_method="wechat",
    ), None))

    assert result["settlement_mode"] == "prorated_difference"
    assert 2499 <= result["amount_cents"] <= 2501


def test_checkout_prorates_from_current_subscription_when_no_previous_payment(monkeypatch):
    # 无历史支付事件(自动续费/后台分配)时,仍按当前订阅周期剩余时间×目录价补差价,不再误收全价
    now = datetime.now(timezone.utc)
    user = {
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_billing_cycle": "monthly",
        "subscription_expires_at": now + timedelta(days=15),
    }
    _upgrade_db(monkeypatch, user)
    _patch_amount_order_context(monkeypatch)

    result = asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="zpay",
        user_email="user@example.com",
        plan_code="lite",
        billing_cycle="yearly",
        payment_method="wechat",
    ), None))

    # lite月付目录价 1000,剩约15天/约30天窗口 → 抵扣约 450~500,应付 = 10000 - 抵扣
    assert result["settlement_mode"] == "prorated_difference"
    assert result["list_price_cents"] == 10000
    assert 430 <= result["upgrade_credit_cents"] <= 520
    assert 9480 <= result["amount_cents"] <= 9570


def test_quote_subscription_options_reports_upgrade_and_blocked(monkeypatch):
    now = datetime.now(timezone.utc)
    _upgrade_db(
        monkeypatch,
        _lite_monthly_user(now),
        events=[_lite_monthly_prev_event(now)],
        orders=[{"order_id": "ord-prev", "currency": "CNY", "paid_amount_cents": 1000}],
    )
    _patch_amount_order_context(monkeypatch)

    result = asyncio.run(payments.quote_subscription_options(payments.SubscriptionQuoteRequest(
        user_email="user@example.com",
        payment_method="wechat",
    ), None))

    assert result["active_plan_code"] == "lite"
    assert result["active_billing_cycle"] == "monthly"
    options = result["options"]
    assert options["lite:monthly"]["purchasable"] is False
    assert options["lite:monthly"]["blocked_reason"] == "duplicate_purchase"
    assert options["lite:yearly"]["purchasable"] is True
    assert options["lite:yearly"]["settlement_mode"] == "prorated_difference"
    assert 9499 <= options["lite:yearly"]["payable_cents"] <= 9501
    assert options["pro:monthly"]["purchasable"] is True
    assert options["pro:yearly"]["purchasable"] is True


def test_quote_subscription_options_blocks_lower_tier_yearly_after_higher_monthly(monkeypatch):
    now = datetime.now(timezone.utc)
    user = {
        "email": "user@example.com",
        "subscription_plan_code": "pro",
        "subscription_billing_cycle": "monthly",
        "subscription_expires_at": now + timedelta(days=15),
    }
    _upgrade_db(monkeypatch, user)
    _patch_amount_order_context(monkeypatch)

    result = asyncio.run(payments.quote_subscription_options(payments.SubscriptionQuoteRequest(
        user_email="user@example.com",
        payment_method="wechat",
    ), None))

    options = result["options"]
    assert options["lite:yearly"]["purchasable"] is False
    assert options["lite:yearly"]["blocked_reason"] == "lower_tier"
    # 无历史支付事件也按当前订阅周期剩余×目录价补差价(自动续费用户不再被误收全价)
    assert options["pro:yearly"]["purchasable"] is True
    assert options["pro:yearly"]["settlement_mode"] == "prorated_difference"
    assert options["pro:yearly"]["payable_cents"] < 30000


def test_zpay_checkout_forces_auto_renew_off(monkeypatch):
    # zpay 无代扣能力,即使客户端请求 auto_renew=True 也强制关闭
    now = datetime.now(timezone.utc)
    db = _upgrade_db(monkeypatch, {"email": "user@example.com", "subscription_plan_code": "free"})
    _patch_amount_order_context(monkeypatch)

    asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="zpay",
        user_email="user@example.com",
        plan_code="lite",
        billing_cycle="monthly",
        payment_method="wechat",
        auto_renew=True,
    ), None))

    order = db["payment_orders"].docs[-1]
    session = db["payment_checkout_sessions"].docs[-1]
    assert order["auto_renew"] is False
    assert session["auto_renew"] is False


# ---------------- Creem(external_product)升级补差价:动态折扣券 ----------------

class _ExternalProductAdapter:
    """Creem 固定价商品适配器桩:记录建券/结账/删券调用。"""

    code = "creem"
    display_name = "Creem"

    def __init__(self, fail_discount=False):
        self.discounts = []
        self.checkouts = []
        self.deleted = []
        self.fail_discount = fail_discount

    async def create_discount(self, **kwargs):
        if self.fail_discount:
            raise HTTPException(status_code=502, detail={"message": "Creem 折扣创建失败"})
        self.discounts.append(kwargs)
        return {"discount_id": "disc_test", "code": kwargs.get("code") or "GEN", "raw": {}}

    async def delete_discount(self, discount_id):
        self.deleted.append(discount_id)
        return {"status": "deleted", "discount_id": discount_id}

    async def create_checkout(self, **kwargs):
        self.checkouts.append(kwargs)
        return {"id": "ch_test", "checkout_url": "https://checkout.creem.io/ch_test", "status": "pending"}

    def verify_webhook_signature(self, *_args, **_kwargs):
        return None


def _external_product_billing_config():
    def _product(code, plan, cycle, amount, pid):
        return (
            {"code": code, "type": "subscription", "name": code, "plan_code": plan, "billing_cycle": cycle, "enabled": True, "sort_order": 10},
            {"product_code": code, "payment_method": "card", "channel_code": "creem", "account_code": "creem_main", "mode": "external_product", "external_product_id": pid, "currency": "USD", "amount_cents": amount, "enabled": True},
        )

    pairs = [
        _product("lite_monthly", "lite", "monthly", 1000, "prod_lite_m"),
        _product("lite_yearly", "lite", "yearly", 10000, "prod_lite_y"),
        _product("pro_monthly", "pro", "monthly", 3000, "prod_pro_m"),
        _product("pro_yearly", "pro", "yearly", 30000, "prod_pro_y"),
    ]
    return {
        "products": [p for p, _ in pairs],
        "currencies": [{"code": "USD", "name": "美元", "rate_to_usd": 1, "enabled": True}],
        "payment_methods": [{"code": "card", "name": "Card", "enabled": True, "sort_order": 10, "currencies": ["USD"], "channel_code": "creem"}],
        "channels": [{
            "code": "creem",
            "provider_code": "creem",
            "name": "Creem",
            "enabled": True,
            "active_account_code": "creem_main",
            "accounts": [{"code": "creem_main", "id": "creem_main", "provider_code": "creem", "enabled": True}],
        }],
        "channel_prices": [r for _, r in pairs],
    }


def _patch_external_product_context(monkeypatch, adapter=None):
    account = {"code": "creem_main", "id": "creem_main", "provider_code": "creem", "enabled": True}

    async def fake_context(_account):
        return account, adapter or _ExternalProductAdapter()

    async def fake_billing_config(*_args, **_kwargs):
        return _external_product_billing_config()

    _patch_all(monkeypatch,"_payment_context_for_account", fake_context)
    _patch_all(monkeypatch,"load_billing_config", fake_billing_config)


def test_creem_upgrade_mints_single_use_discount_and_charges_difference(monkeypatch):
    # Creem 固定价商品:lite月 → pro年 升级,建一次性折扣券把未用价值减掉,用户只付差价
    now = datetime.now(timezone.utc)
    adapter = _ExternalProductAdapter()
    db = _upgrade_db(
        monkeypatch,
        _lite_monthly_user(now),
        events=[_lite_monthly_prev_event(now)],
        orders=[{"order_id": "ord-prev", "currency": "USD", "paid_amount_cents": 1000}],
    )
    _patch_external_product_context(monkeypatch, adapter=adapter)

    result = asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="creem",
        user_email="user@example.com",
        plan_code="pro",
        billing_cycle="yearly",
        payment_method="card",
    ), None))

    # 抵扣 = 1000 * 剩余15天/共30天 ≈ 500,pro年原价 30000,应付 ≈ 29500
    assert result["settlement_mode"] == "prorated_difference"
    assert result["list_price_cents"] == 30000
    assert 499 <= result["upgrade_credit_cents"] <= 501
    assert 29499 <= result["amount_cents"] <= 29501
    # 建券:单次核销、限定目标商品、固定金额=抵扣、带过期
    assert len(adapter.discounts) == 1
    minted = adapter.discounts[0]
    assert minted["max_redemptions"] == 1
    assert minted["applies_to_product_ids"] == ["prod_pro_y"]
    assert 499 <= minted["amount_cents"] <= 501
    assert minted["expiry_date"]
    assert minted["code"].startswith("UPG")
    # 结账带上券号,券号回传
    assert adapter.checkouts[0]["discount_code"] == result["discount_code"]
    assert result["discount_code"].startswith("UPG")
    # 订单落库记录券信息(供履约删券)
    order = db["payment_orders"].docs[-1]
    assert order["settlement_mode"] == "prorated_difference"
    assert order["upgrade_discount"]["status"] == "issued"
    assert order["upgrade_discount"]["discount_id"] == "disc_test"
    assert order["upgrade_discount"]["single_use"] is True


def test_creem_upgrade_discount_mint_failure_falls_back_to_full_price(monkeypatch):
    # 建券失败:诚实回退全价,标记待人工补退,不静默坑用户也不阻断升级
    now = datetime.now(timezone.utc)
    adapter = _ExternalProductAdapter(fail_discount=True)
    db = _upgrade_db(
        monkeypatch,
        _lite_monthly_user(now),
        events=[_lite_monthly_prev_event(now)],
        orders=[{"order_id": "ord-prev", "currency": "USD", "paid_amount_cents": 1000}],
    )
    _patch_external_product_context(monkeypatch, adapter=adapter)

    result = asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="creem",
        user_email="user@example.com",
        plan_code="pro",
        billing_cycle="yearly",
        payment_method="card",
    ), None))

    assert result["settlement_mode"] == "full_price"
    assert result["amount_cents"] == 30000
    # 结账不带补差价券
    assert not adapter.discounts
    assert adapter.checkouts[0]["discount_code"] == ""
    order = db["payment_orders"].docs[-1]
    assert order["upgrade_discount"]["status"] == "mint_failed"
    assert 499 <= order["upgrade_discount"]["owed_cents"] <= 501


def test_creem_non_upgrade_purchase_does_not_mint_discount(monkeypatch):
    # 全新购买(无在期付费订阅)不触发建券,正常全价
    now = datetime.now(timezone.utc)
    adapter = _ExternalProductAdapter()
    _upgrade_db(monkeypatch, {"email": "user@example.com", "subscription_plan_code": "free"})
    _patch_external_product_context(monkeypatch, adapter=adapter)

    result = asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="creem",
        user_email="user@example.com",
        plan_code="lite",
        billing_cycle="monthly",
        payment_method="card",
    ), None))

    assert result["settlement_mode"] == "full_price"
    assert result["amount_cents"] == 1000
    assert not adapter.discounts


def test_creem_upgrade_without_previous_event_still_mints_discount(monkeypatch):
    # 自动续费/后台分配的 pro月付用户(无历史支付事件)升 pro年:仍按当前订阅周期补差价并建券
    now = datetime.now(timezone.utc)
    adapter = _ExternalProductAdapter()
    db = _upgrade_db(
        monkeypatch,
        {
            "email": "user@example.com",
            "subscription_plan_code": "pro",
            "subscription_billing_cycle": "monthly",
            "subscription_status": "active",
            "subscription_expires_at": now + timedelta(days=15),
            "latest_payment_event_id": "auto:auto_renewal:xxx",  # 指向不存在的事件
        },
    )
    _patch_external_product_context(monkeypatch, adapter=adapter)

    result = asyncio.run(create_subscription_checkout(CreateSubscriptionCheckoutRequest(
        provider="creem",
        user_email="user@example.com",
        plan_code="pro",
        billing_cycle="yearly",
        payment_method="card",
    ), None))

    # pro月付目录价 3000,剩约15天/约30天 → 抵扣约 1350~1550,pro年原价 30000
    assert result["settlement_mode"] == "prorated_difference"
    assert result["list_price_cents"] == 30000
    assert 1300 <= result["upgrade_credit_cents"] <= 1600
    assert result["amount_cents"] < 30000
    assert len(adapter.discounts) == 1
    assert result["discount_code"].startswith("UPG")
    order = db["payment_orders"].docs[-1]
    assert order["upgrade_discount"]["status"] == "issued"


# ---------------- 取消自动续费(cancel-renewal)与旧订阅代扣清理 ----------------

class _CancelRecordingAdapter:
    """Creem 适配器桩:记录取消订阅调用(subscription_id + mode)。"""

    code = "creem"
    display_name = "Creem"

    def __init__(self, fail_cancel=False):
        self.cancelled = []
        self.fail_cancel = fail_cancel

    async def cancel_subscription(self, subscription_id, mode="scheduled", on_execute="cancel"):
        if self.fail_cancel:
            raise HTTPException(status_code=502, detail={"message": "Creem 订阅取消失败"})
        self.cancelled.append({"subscription_id": subscription_id, "mode": mode})
        return {"id": subscription_id, "status": "canceled"}


def _creem_auto_renew_user(now, **overrides):
    user = {
        "email": "user@example.com",
        "subscription_plan_code": "lite",
        "subscription_billing_cycle": "monthly",
        "subscription_status": "active",
        "subscription_auto_renew": True,
        "subscription_expires_at": now + timedelta(days=15),
        "latest_payment_provider": "creem",
        "latest_provider_subscription_id": "sub_old",
    }
    user.update(overrides)
    return user


def test_cancel_renewal_cancels_creem_channel_and_disables_auto_renew(monkeypatch):
    now = datetime.now(timezone.utc)
    adapter = _CancelRecordingAdapter()
    db = _db(_creem_auto_renew_user(now))
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_external_product_context(monkeypatch, adapter=adapter)

    result = asyncio.run(cancel_subscription_renewal(CancelRenewalRequest(user_email="user@example.com"), None))

    assert result["status"] == "cancelled"
    assert result["channel_sync"] == "ok"
    assert result["effective_until"] == db["users"].docs[0]["subscription_expires_at"]
    # 渠道侧周期末取消(scheduled),不是立即取消
    assert adapter.cancelled == [{"subscription_id": "sub_old", "mode": "scheduled"}]
    assert db["users"].docs[0]["subscription_auto_renew"] is False
    events = db["subscription_events"].docs
    assert len(events) == 1
    assert events[0]["event_type"] == "cancel_renewal"
    assert events[0]["channel_sync"] == "ok"
    assert events[0]["subscription_id"] == "sub_old"


def test_cancel_renewal_is_idempotent_when_already_off(monkeypatch):
    now = datetime.now(timezone.utc)
    adapter = _CancelRecordingAdapter()
    db = _db(_creem_auto_renew_user(now, subscription_auto_renew=False))
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_external_product_context(monkeypatch, adapter=adapter)

    result = asyncio.run(cancel_subscription_renewal(CancelRenewalRequest(user_email="user@example.com"), None))

    assert result["status"] == "already_cancelled"
    assert not adapter.cancelled
    assert not db["subscription_events"].docs


def test_cancel_renewal_channel_failure_still_disables_auto_renew(monkeypatch):
    # 渠道取消失败:用户取消意图优先,本地仍关闭自动续费,channel_sync=failed 留待人工处理
    now = datetime.now(timezone.utc)
    adapter = _CancelRecordingAdapter(fail_cancel=True)
    db = _db(_creem_auto_renew_user(now))
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_external_product_context(monkeypatch, adapter=adapter)

    result = asyncio.run(cancel_subscription_renewal(CancelRenewalRequest(user_email="user@example.com"), None))

    assert result["status"] == "cancelled"
    assert result["channel_sync"] == "failed"
    assert db["users"].docs[0]["subscription_auto_renew"] is False
    assert db["subscription_events"].docs[0]["channel_sync"] == "failed"


def test_cancel_renewal_without_provider_subscription_skips_channel(monkeypatch):
    # zpay 用户 / 后台分配:无渠道订阅 id,只改本地开关
    now = datetime.now(timezone.utc)
    adapter = _CancelRecordingAdapter()
    db = _db(_creem_auto_renew_user(
        now,
        latest_payment_provider="zpay",
        latest_provider_subscription_id=None,
    ))
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_external_product_context(monkeypatch, adapter=adapter)

    result = asyncio.run(cancel_subscription_renewal(CancelRenewalRequest(user_email="user@example.com"), None))

    assert result["status"] == "cancelled"
    assert result["channel_sync"] == "skipped"
    assert not adapter.cancelled
    assert db["users"].docs[0]["subscription_auto_renew"] is False


def test_cancel_renewal_missing_user_returns_404(monkeypatch):
    db = _db({"email": "other@example.com"})
    _patch_all(monkeypatch,"get_main_db", lambda: db)

    with pytest.raises(HTTPException) as exc:
        asyncio.run(cancel_subscription_renewal(CancelRenewalRequest(user_email="user@example.com"), None))

    assert exc.value.status_code == 404


def test_creem_upgrade_payment_cancels_stale_previous_subscription(monkeypatch):
    # lite(sub_old 代扣中) → 购买 pro:履约覆盖订阅 id 之前必须周期末取消旧 Creem 订阅,防双重扣费
    now = datetime.now(timezone.utc)
    db = _db(_creem_auto_renew_user(now))
    db["payment_checkout_sessions"].docs.append({
        "request_id": "req-upgrade",
        "provider": "creem",
        "kind": "subscription",
        "status": "pending",
        "user_email": "user@example.com",
        "plan_code": "pro",
        "billing_cycle": "monthly",
        "settlement_mode": "full_price",
        "auto_renew": True,
        "product_id": "prod_pro",
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    profile = _payment_profile()
    adapter = _recording_creem_adapter(profile)

    result = _run_creem_event(db, profile, "evt-upgrade-paid", "subscription.paid", {
        "id": "sub_new",
        "product": {"id": "prod_pro", "price": 3000},
        "customer": {"email": "user@example.com", "id": "cust_1"},
        "last_transaction_id": "tran_2",
        "metadata": {"request_id": "req-upgrade"},
    }, adapter=adapter)

    user = db["users"].docs[0]
    assert result["status"] == "applied"
    assert user["subscription_plan_code"] == "pro"
    assert user["latest_provider_subscription_id"] == "sub_new"
    assert adapter.cancelled == [{"subscription_id": "sub_old", "mode": "scheduled"}]
    events = db["subscription_events"].docs
    assert len(events) == 1
    assert events[0]["event_type"] == "stale_subscription_cancelled"
    assert events[0]["subscription_id"] == "sub_old"
    assert events[0]["new_subscription_id"] == "sub_new"


def test_creem_renewal_payment_does_not_cancel_same_subscription(monkeypatch):
    # 同一订阅的自动续费扣款(subscription id 不变)不是换订阅,不得误取消
    now = datetime.now(timezone.utc)
    db = _db(_creem_auto_renew_user(now, latest_provider_subscription_id="sub_1"))
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_payment_context(monkeypatch)
    profile = _payment_profile()
    adapter = _recording_creem_adapter(profile)

    result = _run_creem_event(db, profile, "evt-renew-paid", "subscription.paid", {
        "id": "sub_1",
        "product": {"id": "prod_lite", "price": 100},
        "customer": {"email": "user@example.com", "id": "cust_1"},
        "last_transaction_id": "tran_renew",
        "metadata": {},
    }, adapter=adapter)

    assert result["status"] == "applied"
    assert result["change_mode"] == "renew"
    assert not adapter.cancelled
    assert not db["subscription_events"].docs
    assert db["users"].docs[0]["latest_provider_subscription_id"] == "sub_1"


def test_zpay_subscription_payment_cancels_stale_creem_subscription(monkeypatch):
    # 旧 Creem 代扣用户改用 ZPay 购买:履约后也要取消旧 Creem 订阅(helper 从计费配置构建 adapter)
    now = datetime.now(timezone.utc)
    db = _db(_creem_auto_renew_user(now))
    db["payment_checkout_sessions"].docs.append({
        "request_id": "zp-req",
        "provider": "zpay",
        "kind": "subscription",
        "status": "pending",
        "user_email": "user@example.com",
        "plan_code": "pro",
        "billing_cycle": "monthly",
        "settlement_mode": "full_price",
        "auto_renew": False,
        "payment_channel": "zpay_main",
    })
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    adapter = _CancelRecordingAdapter()

    async def fake_context(_account):
        return _account, adapter

    async def fake_billing_config(*_args, **_kwargs):
        return {
            "channels": [{
                "code": "creem",
                "provider_code": "creem",
                "enabled": True,
                "active_account_code": "creem_main",
                "accounts": [{"code": "creem_main", "enabled": True}],
            }],
        }

    _patch_all(monkeypatch,"_payment_context_for_account", fake_context)
    _patch_all(monkeypatch,"load_billing_config", fake_billing_config)
    raw_body = b"out_trade_no=zp-req&trade_no=zp_tr_1&trade_status=TRADE_SUCCESS&money=30.00"

    result = _run_zpay_event(db, {"provider_code": "zpay"}, raw_body)

    user = db["users"].docs[0]
    assert result["status"] == "applied"
    assert user["subscription_plan_code"] == "pro"
    assert adapter.cancelled == [{"subscription_id": "sub_old", "mode": "scheduled"}]
    events = db["subscription_events"].docs
    assert events[0]["event_type"] == "stale_subscription_cancelled"
    assert events[0]["new_subscription_id"] == ""


# ---------------- Creem adapter 取消订阅请求体 ----------------

class _FakeCancelResponse:
    status_code = 200
    text = "{}"

    def json(self):
        return {"id": "sub_1", "status": "canceled"}


def test_creem_adapter_cancel_subscription_builds_mode_body(monkeypatch):
    calls = []

    class _FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        async def post(self, url, headers=None, json=None, **kwargs):
            calls.append({"url": url, "json": json})
            return _FakeCancelResponse()

    monkeypatch.setattr(httpx, "AsyncClient", _FakeAsyncClient)
    adapter = CreemPaymentProviderAdapter({
        "provider_code": "creem",
        "api_key": "test-key",
        "api_base_url": "https://test-api.creem.io",
    })

    # 默认:周期末取消(用户取消自动续费)
    asyncio.run(adapter.cancel_subscription("sub_1"))
    assert calls[-1]["url"] == "https://test-api.creem.io/v1/subscriptions/sub_1/cancel"
    assert calls[-1]["json"] == {"mode": "scheduled", "onExecute": "cancel"}

    # 立即取消(退款等管理场景):不带 onExecute
    asyncio.run(adapter.cancel_subscription("sub_1", mode="immediate"))
    assert calls[-1]["json"] == {"mode": "immediate"}


def test_cancel_renewal_rejects_apple_managed_subscription(monkeypatch):
    # Apple IAP 订阅只能在 App Store 取消:不改本地 auto_renew(Apple 通知回同步),不碰渠道
    now = datetime.now(timezone.utc)
    adapter = _CancelRecordingAdapter()
    db = _db(_creem_auto_renew_user(now, latest_payment_provider="apple", latest_provider_subscription_id=""))
    _patch_all(monkeypatch,"get_main_db", lambda: db)
    _patch_external_product_context(monkeypatch, adapter=adapter)

    result = asyncio.run(cancel_subscription_renewal(CancelRenewalRequest(user_email="user@example.com"), None))

    assert result["status"] == "apple_managed"
    assert db["users"].docs[0]["subscription_auto_renew"] is True  # 本地状态未被篡改
    assert not adapter.cancelled
    assert not db["subscription_events"].docs
