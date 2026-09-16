import asyncio
import copy

import pytest

from app.api.v1 import catalog_admin
from app.services.billing import catalog as billing_catalog
from app.services.billing.catalog import (
    CatalogError,
    archive_price,
    create_price,
    diff_is_empty,
    make_price_current,
    migrate_catalog_v1,
    publish_catalog,
    set_plan_status,
    update_price,
    upsert_plan,
)
from app.services.billing.config import clean_billing_config


# ---------------- fake db(参考 tests/test_payment_rules.py,扩展 upsert 支持) ----------------


class _Cursor:
    def __init__(self, rows):
        self.rows = rows

    def sort(self, *_args, **_kwargs):
        return self

    def limit(self, *_args, **_kwargs):
        return self

    async def to_list(self, length=None):
        return self.rows[:length] if length else list(self.rows)


def _matches(doc, query):
    for key, expected in (query or {}).items():
        if doc.get(key) != expected:
            return False
    return True


def _apply_update(doc, update):
    for key, value in update.get("$set", {}).items():
        doc[key] = value


class _Collection:
    def __init__(self, docs=None):
        self.docs = [copy.deepcopy(doc) for doc in (docs or [])]

    async def find_one(self, query):
        for doc in self.docs:
            if _matches(doc, query):
                return copy.deepcopy(doc)
        return None

    async def insert_one(self, doc):
        self.docs.append(copy.deepcopy(doc))
        return type("InsertResult", (), {"inserted_id": "inserted-id"})()

    async def update_one(self, query, update, upsert=False):
        for doc in self.docs:
            if _matches(doc, query):
                _apply_update(doc, update)
                return type("UpdateResult", (), {"modified_count": 1})()
        if upsert:
            doc = {key: value for key, value in query.items() if not key.startswith("$")}
            _apply_update(doc, update)
            self.docs.append(doc)
        return type("UpdateResult", (), {"modified_count": 0})()

    def find(self, query):
        return _Cursor([copy.deepcopy(doc) for doc in self.docs if _matches(doc, query)])


class _Db(dict):
    def __getitem__(self, key):
        if key not in self:
            self[key] = _Collection()
        return dict.__getitem__(self, key)


# ---------------- 现有配置 fixture(与管理端 _clean_plan_configs 落库形态一致) ----------------


def _plan_configs():
    return {
        "free": {
            "code": "free", "name": "免费套餐", "enabled": True, "credits": 500,
            "reset_period": "week", "auto_assign_on_register": False,
            "validity_period": "forever", "validity_count": 0,
            "manual_assign_enabled": True, "paid": False, "rank": 0, "sort_order": 20,
            "plan_family": "base", "stackable": False, "self_checkout_enabled": False,
            "auto_renew_supported": False, "paid_topup_enabled": False,
            "lifecycle_status": "active", "trial_once_per_user": False, "billing_options": {},
        },
        "lite": {
            "code": "lite", "name": "轻量套餐", "enabled": True, "credits": 9000,
            "reset_period": "month", "auto_assign_on_register": False,
            "validity_period": "month", "validity_count": 1,
            "manual_assign_enabled": True, "paid": True, "rank": 10, "sort_order": 30,
            "plan_family": "base", "stackable": False, "self_checkout_enabled": True,
            "auto_renew_supported": True, "paid_topup_enabled": True,
            "lifecycle_status": "active", "trial_once_per_user": False,
            "billing_options": {
                "monthly": {"cycle": "monthly", "enabled": True, "duration_period": "month", "duration_count": 1},
                "yearly": {"cycle": "yearly", "enabled": True, "duration_period": "year", "duration_count": 1},
            },
        },
    }


def _billing_config():
    return clean_billing_config({
        "products": [
            {"code": "lite_monthly", "type": "subscription", "name": "轻量月付", "description": "", "plan_code": "lite", "billing_cycle": "monthly", "enabled": True, "sort_order": 30},
            {"code": "lite_yearly", "type": "subscription", "name": "轻量年付", "description": "", "plan_code": "lite", "billing_cycle": "yearly", "enabled": True, "sort_order": 30},
            {"code": "credits_topup", "type": "credits_topup", "name": "积分充值", "topup_credits": 10000, "enabled": True, "sort_order": 100},
        ],
        "currencies": [
            {"code": "USD", "name": "美元", "symbol": "$", "rate_to_usd": 1, "rate_source": "fixed", "auto_update": False, "enabled": True},
            {"code": "CNY", "name": "人民币", "symbol": "¥", "rate_to_usd": 0.138, "rate_source": "manual", "auto_update": False, "enabled": True},
        ],
        "payment_methods": [
            {"code": "card", "name": "银行卡", "enabled": True, "sort_order": 10, "currencies": ["USD"], "channel_code": "creem"},
            {"code": "wechat", "name": "微信支付", "enabled": True, "sort_order": 20, "currencies": ["CNY"], "channel_code": "zpay"},
        ],
        "channels": [
            {"code": "creem", "provider_code": "creem", "name": "Creem", "enabled": True, "active_account_code": "creem_main", "accounts": [{"code": "creem_main", "name": "Creem Main", "enabled": True}]},
            {"code": "zpay", "provider_code": "zpay", "name": "ZPay", "enabled": True, "active_account_code": "zpay_main", "accounts": [{"code": "zpay_main", "name": "ZPay Main", "enabled": True}]},
        ],
        "channel_prices": [
            {"product_code": "lite_monthly", "payment_method": "card", "channel_code": "creem", "account_code": "creem_main", "mode": "external_product", "currency": "USD", "amount_cents": 990, "external_product_id": "prod_lite_m", "enabled": True},
            {"product_code": "lite_monthly", "payment_method": "wechat", "channel_code": "zpay", "account_code": "zpay_main", "mode": "amount_order", "currency": "CNY", "amount_cents": 6900, "enabled": True},
            {"product_code": "lite_yearly", "payment_method": "card", "channel_code": "creem", "account_code": "creem_main", "mode": "external_product", "currency": "USD", "amount_cents": 9900, "external_product_id": "prod_lite_y", "enabled": True},
            {"product_code": "credits_topup", "payment_method": "card", "channel_code": "creem", "account_code": "creem_main", "mode": "external_product", "currency": "USD", "amount_cents": 500, "external_product_id": "prod_topup", "enabled": True},
        ],
    })


def _db():
    return _Db({
        "system_config": _Collection([
            {"key": "plan_configs", "value": _plan_configs()},
            {"key": "payment_billing_config", "value": _billing_config()},
        ]),
        "payment_orders": _Collection(),
    })


def _billing_value(db):
    doc = asyncio.run(db["system_config"].find_one({"key": "payment_billing_config"}))
    return doc["value"]


def _plan_configs_value(db):
    doc = asyncio.run(db["system_config"].find_one({"key": "plan_configs"}))
    return doc["value"]


# ---------------- 迁移 → dry-run 零 diff(往返一致性) ----------------


def test_migration_generates_catalog_and_dry_run_publish_has_zero_diff():
    db = _db()

    stats = asyncio.run(migrate_catalog_v1(db))
    assert stats == {"plans_created": 2, "plans_skipped": 0, "prices_created": 3, "prices_skipped": 0}

    plan_codes = {doc["plan_code"] for doc in db["billing_plans"].docs}
    assert plan_codes == {"free", "lite"}
    price_ids = {doc["price_id"] for doc in db["billing_prices"].docs}
    assert price_ids == {"lite_monthly_usd_v1", "lite_monthly_cny_v1", "lite_yearly_usd_v1"}
    monthly_usd = next(doc for doc in db["billing_prices"].docs if doc["price_id"] == "lite_monthly_usd_v1")
    assert monthly_usd["lookup_key"] == "lite_monthly"
    assert monthly_usd["sellable"] is True
    assert monthly_usd["version"] == 1
    assert monthly_usd["amount_cents"] == 990
    assert monthly_usd["channel_bindings"]["creem"]["external_product_id"] == "prod_lite_m"

    result = asyncio.run(publish_catalog(db, dry_run=True))
    assert result["dry_run"] is True
    assert result["has_changes"] is False, result["diff"]
    assert diff_is_empty(result["diff"]) is True


def test_migration_is_idempotent():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))
    stats = asyncio.run(migrate_catalog_v1(db))

    assert stats == {"plans_created": 0, "plans_skipped": 2, "prices_created": 0, "prices_skipped": 3}
    assert len(db["billing_plans"].docs) == 2
    assert len(db["billing_prices"].docs) == 3
    result = asyncio.run(publish_catalog(db, dry_run=True))
    assert result["has_changes"] is False


# ---------------- 改价流程:新建 price → make-current → publish 投影更新 ----------------


def test_price_change_flow_updates_projection_after_publish():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))

    created = asyncio.run(create_price(db, {
        "plan_code": "lite",
        "period": "monthly",
        "currency": "USD",
        "amount_cents": 1490,
        "channel_bindings": {
            "creem": {"payment_method": "card", "account_code": "creem_main", "mode": "external_product", "external_product_id": "prod_lite_m_v2"},
        },
    }))
    assert created["price_id"] == "lite_monthly_usd_v2"
    assert created["version"] == 2
    assert created["sellable"] is False

    asyncio.run(make_price_current(db, "lite_monthly_usd_v2"))
    old = next(doc for doc in db["billing_prices"].docs if doc["price_id"] == "lite_monthly_usd_v1")
    new = next(doc for doc in db["billing_prices"].docs if doc["price_id"] == "lite_monthly_usd_v2")
    assert old["lookup_key"] == ""
    assert old["sellable"] is False
    assert new["lookup_key"] == "lite_monthly"
    assert new["sellable"] is True
    # CNY 在售版不受 USD 改价影响
    cny = next(doc for doc in db["billing_prices"].docs if doc["price_id"] == "lite_monthly_cny_v1")
    assert cny["lookup_key"] == "lite_monthly"

    result = asyncio.run(publish_catalog(db, operator="tester", dry_run=False))
    assert result["dry_run"] is False
    assert result["has_changes"] is True
    assert result["snapshot_version"] == 1

    rows = _billing_value(db)["channel_prices"]
    usd_row = next(r for r in rows if r["product_code"] == "lite_monthly" and r["currency"] == "USD")
    assert usd_row["amount_cents"] == 1490
    assert usd_row["external_product_id"] == "prod_lite_m_v2"
    cny_row = next(r for r in rows if r["product_code"] == "lite_monthly" and r["currency"] == "CNY")
    assert cny_row["amount_cents"] == 6900
    # plan_configs 投影不受改价影响
    assert _plan_configs_value(db)["lite"]["billing_options"]["monthly"]["enabled"] is True

    logs = db["catalog_publish_log"].docs
    assert len(logs) == 1
    assert logs[0]["operator"] == "tester"
    assert logs[0]["snapshot_version"] == 1
    assert logs[0]["diff_summary"]["billing_config"]["channel_prices"]["changed"]


# ---------------- 不可变约束 ----------------


def test_immutable_price_rejects_amount_change_once_sellable():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))

    with pytest.raises(CatalogError) as exc:
        asyncio.run(update_price(db, "lite_monthly_usd_v1", {"amount_cents": 100}))
    assert "不可变" in str(exc.value)

    with pytest.raises(CatalogError):
        asyncio.run(update_price(db, "lite_monthly_usd_v1", {"currency": "EUR"}))
    with pytest.raises(CatalogError):
        asyncio.run(update_price(db, "lite_monthly_usd_v1", {"channel_bindings": {}}))

    doc = next(d for d in db["billing_prices"].docs if d["price_id"] == "lite_monthly_usd_v1")
    assert doc["amount_cents"] == 990


def test_archived_price_stays_immutable_and_draft_price_is_editable():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))

    # 归档(sellable=false)不解锁计费字段:曾在售即永久锁定
    asyncio.run(archive_price(db, "lite_monthly_usd_v1"))
    with pytest.raises(CatalogError):
        asyncio.run(update_price(db, "lite_monthly_usd_v1", {"amount_cents": 100}))

    # 从未在售、未被订单引用的草稿价允许修正金额
    asyncio.run(create_price(db, {"plan_code": "lite", "period": "monthly", "currency": "USD", "amount_cents": 1200}))
    updated = asyncio.run(update_price(db, "lite_monthly_usd_v2", {"amount_cents": 1300}))
    assert updated["amount_cents"] == 1300


def test_create_price_rejects_duplicate_price_id_and_occupied_lookup_key():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))

    with pytest.raises(CatalogError):
        asyncio.run(create_price(db, {"price_id": "lite_monthly_usd_v1", "plan_code": "lite", "period": "monthly", "currency": "USD", "amount_cents": 990}))
    with pytest.raises(CatalogError):
        asyncio.run(create_price(db, {"plan_code": "lite", "period": "monthly", "currency": "USD", "amount_cents": 990, "lookup_key": "lite_monthly"}))
    with pytest.raises(CatalogError):
        asyncio.run(create_price(db, {"plan_code": "unknown", "period": "monthly", "currency": "USD", "amount_cents": 990}))


# ---------------- 归档 plan:投影移除商品,存量订阅不受影响 ----------------


def test_retired_plan_removes_products_and_leaves_plan_configs_untouched():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))
    before = _plan_configs_value(db)

    plan = asyncio.run(set_plan_status(db, "lite", "retired"))
    assert plan["status"] == "retired"

    result = asyncio.run(publish_catalog(db, operator="tester", dry_run=False))
    assert result["has_changes"] is True

    billing = _billing_value(db)
    product_codes = {row["code"] for row in billing["products"]}
    assert product_codes == {"credits_topup"}  # 订阅商品不再可购
    assert {row["product_code"] for row in billing["channel_prices"]} == {"credits_topup"}

    # catalog 只管价格:publish 不再触碰 plan_configs(套餐定义由 PlansView 独立管理)。
    # 套餐是否下架、自助购买开关等,均在套餐配置页处理,catalog 发布对 plan_configs 零改动。
    after = _plan_configs_value(db)
    assert after == before
    assert after["lite"]["credits"] == 9000
    assert after["free"]["credits"] == 500


# ---------------- 可购性(enabled)以 plan_configs.self_checkout 为准 ----------------


def _set_plan_config(db, code, **changes):
    doc = asyncio.run(db["system_config"].find_one({"key": "plan_configs"}))
    value = copy.deepcopy(doc["value"])
    value[code].update(changes)
    asyncio.run(db["system_config"].update_one({"key": "plan_configs"}, {"$set": {"value": value}}))


def test_product_enabled_follows_plan_configs_self_checkout():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))

    # catalog 状态保持 active,仅在 plan_configs 关闭自助购买 → 商品不可购但仍在售(仅下架购买按钮)
    _set_plan_config(db, "lite", self_checkout_enabled=False)
    asyncio.run(publish_catalog(db, operator="tester", dry_run=False))

    billing = _billing_value(db)
    products = {row["code"]: row for row in billing["products"]}
    # 商品仍存在(catalog 未 retired),但可购性关闭
    assert "lite_monthly" in products
    assert products["lite_monthly"]["enabled"] is False
    assert products["lite_yearly"]["enabled"] is False

    # 重新在 plan_configs 打开自助购买 → 可购性恢复
    _set_plan_config(db, "lite", self_checkout_enabled=True)
    asyncio.run(publish_catalog(db, operator="tester", dry_run=False))
    billing = _billing_value(db)
    products = {row["code"]: row for row in billing["products"]}
    assert products["lite_monthly"]["enabled"] is True


def test_plan_configs_archived_lifecycle_removes_products():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))

    # catalog 状态仍 active,但 plan_configs 生命周期置 archived → 订阅商品移除
    _set_plan_config(db, "lite", lifecycle_status="archived")
    asyncio.run(publish_catalog(db, operator="tester", dry_run=False))

    billing = _billing_value(db)
    assert {row["code"] for row in billing["products"]} == {"credits_topup"}


# ---------------- plan 编辑:catalog 只管展示元数据,不再产生影响提示 ----------------


def test_upsert_plan_updates_metadata_without_impact_hints():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))

    # catalog 已降级为纯价格域:改 display 不产生任何"发布影响"提示
    plan, hints = asyncio.run(upsert_plan(db, {"plan_code": "lite", "display": {"badge": "热销"}}))
    assert plan["display"]["badge"] == "热销"
    assert hints == []
    # 积分/有效期(entitlements)已迁出 catalog,billing_plans 不再建模该字段
    assert "entitlements" not in plan

    # 新建 plan:仅承载 name/display 等展示元数据;积分/等级由 plan_configs 定义
    plan, hints = asyncio.run(upsert_plan(db, {"plan_code": "max", "name": "旗舰套餐", "paid": True}))
    assert plan["plan_code"] == "max"
    assert plan["name"] == "旗舰套餐"
    assert hints == []
    assert asyncio.run(db["billing_plans"].find_one({"plan_code": "max"}))


def test_upsert_plan_rejects_bad_input():
    db = _db()
    with pytest.raises(CatalogError):
        asyncio.run(upsert_plan(db, {"plan_code": "Bad Code!"}))
    with pytest.raises(CatalogError):
        asyncio.run(upsert_plan(db, {"plan_code": "lite", "status": "deleted"}))
    with pytest.raises(CatalogError):
        asyncio.run(set_plan_status(db, "ghost", "retired"))


# ---------------- 新增 plan+price 后 publish 会生成新商品 ----------------


def test_publish_adds_products_for_new_plan_prices():
    db = _db()
    asyncio.run(migrate_catalog_v1(db))
    asyncio.run(upsert_plan(db, {
        "plan_code": "max", "name": "旗舰套餐", "paid": True,
        "display": {"sort_order": 50},
    }))
    asyncio.run(create_price(db, {
        "plan_code": "max", "period": "monthly", "currency": "USD", "amount_cents": 4990,
        "channel_bindings": {"creem": {"payment_method": "card", "account_code": "creem_main", "mode": "external_product", "external_product_id": "prod_max_m"}},
    }))
    asyncio.run(make_price_current(db, "max_monthly_usd_v1"))

    asyncio.run(publish_catalog(db, dry_run=False))

    billing = _billing_value(db)
    product = next(row for row in billing["products"] if row["code"] == "max_monthly")
    assert product["plan_code"] == "max"
    assert product["billing_cycle"] == "monthly"
    assert product["enabled"] is True
    row = next(r for r in billing["channel_prices"] if r["product_code"] == "max_monthly")
    assert row["amount_cents"] == 4990
    assert row["external_product_id"] == "prod_max_m"

    # catalog 只投影价格:publish 生成新商品/价格,但**不自动创建 plan_configs 条目**。
    # 新套餐的积分/有效期定义须由运营在套餐配置页(PlansView)单独定义,plan_configs 是唯一真源。
    plans = _plan_configs_value(db)
    assert "max" not in plans


# ---------------- API 层(router 装配与请求/响应形状) ----------------


def test_catalog_admin_api_endpoints(monkeypatch):
    db = _db()
    asyncio.run(migrate_catalog_v1(db))
    monkeypatch.setattr(catalog_admin, "get_main_db", lambda: db)

    plans = asyncio.run(catalog_admin.list_catalog_plans(None))
    assert {p["plan_code"] for p in plans["plans"]} == {"free", "lite"}

    result = asyncio.run(catalog_admin.upsert_catalog_plan(
        catalog_admin.PlanUpsertRequest(plan_code="lite", display={"badge": "热销"}), None,
    ))
    assert result["plan"]["display"]["badge"] == "热销"
    assert result["impact_hints"] == []

    prices = asyncio.run(catalog_admin.list_catalog_prices("lite", None))
    assert len(prices["prices"]) == 3

    created = asyncio.run(catalog_admin.create_catalog_price(catalog_admin.PriceCreateRequest(
        plan_code="lite", period="monthly", currency="USD", amount_cents=1490,
        channel_bindings={"creem": {"payment_method": "card", "account_code": "creem_main", "mode": "external_product", "external_product_id": "prod_lite_m_v2"}},
        make_current=True,
    ), None))
    assert created["price"]["price_id"] == "lite_monthly_usd_v2"
    assert created["price"]["lookup_key"] == "lite_monthly"
    assert created["made_current"] is True

    published = asyncio.run(catalog_admin.publish_catalog(False, catalog_admin.PublishRequest(operator="ops"), None))
    assert published["dry_run"] is False
    assert published["snapshot_version"] == 1

    logs = asyncio.run(catalog_admin.catalog_publish_log(50, None))
    assert len(logs["logs"]) == 1
    assert logs["logs"][0]["operator"] == "ops"

    status = asyncio.run(catalog_admin.set_catalog_plan_status("lite", catalog_admin.PlanStatusRequest(status="retired"), None))
    assert status["plan"]["status"] == "retired"
    assert status["impact_hints"]

    archived = asyncio.run(catalog_admin.archive_catalog_price("lite_monthly_usd_v2", None))
    assert archived["price"]["sellable"] is False
