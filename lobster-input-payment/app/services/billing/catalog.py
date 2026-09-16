"""计费目录域(Catalog)服务 —— 计费域重构阶段 1。

设计要点(见 lobster-input-backend/docs/billing-rearchitecture-design.md 第二、三、五节):

- ``billing_plans`` / ``billing_prices`` 是计费配置的唯一编辑入口(catalog);
- ``billing_prices`` 不可变:被订单引用或曾在售(ever_sellable)的 price 禁改计费字段,
  改价 = 新建 version+1 的 price + make-current(lookup_key 转移 + 旧价 sellable=false);
- catalog 已降级为纯价格域:套餐定义(可购性/积分/有效期/等级/退役)的唯一真源是
  ``system_config.plan_configs``(由管理端 PlansView 编辑);``billing_plans`` 仅承载
  "该 plan_code 归 catalog 管价格 + 展示元数据(name/display)";
- publish 动作只把在售价格物化(投影)为 ``payment_billing_config`` 的 products +
  channel_prices 段并写回 system_config(由在售 prices 的 channel_bindings 生成;
  currencies/payment_methods/channels/exchange 段原样保留),**不再触碰 plan_configs**。
  现有读路径(load_billing_config / plan_configs 消费方)零改动。
- 商品的可购性/名称/是否退役在投影时以 plan_configs 为准(见 build_billing_config_projection),
  retired plan 的商品与渠道价从 billing_config 投影中移除,存量用户续费/积分重置不受影响。
"""

from __future__ import annotations

import copy
import re
from datetime import datetime, timezone
from typing import Any

from app.services.billing.config import (
    BILLING_CONFIG_KEY,
    _CONFIG_CACHE as _BILLING_CONFIG_CACHE,
    clean_billing_config,
)

PLANS_COLLECTION = "billing_plans"
PRICES_COLLECTION = "billing_prices"
PUBLISH_LOG_COLLECTION = "catalog_publish_log"
PLAN_CONFIGS_KEY = "plan_configs"

PLAN_CODE_RE = re.compile(r"^[a-z0-9_-]+$")
PLAN_STATUSES = {"active", "hidden", "retired"}
PLAN_FAMILIES = {"base", "addon"}
PRICE_PERIODS = {"monthly", "quarterly", "yearly"}
PERIOD_ORDER = {"monthly": 0, "quarterly": 1, "yearly": 2}
DEFAULT_DURATIONS = {"monthly": ("month", 1), "quarterly": ("month", 3), "yearly": ("year", 1)}
DURATION_PERIODS = {"month", "year"}
BINDING_MODES = {"external_product", "amount_order"}

# price 一经在售/被引用即锁定的计费字段("改价"必须新建版本)
IMMUTABLE_PRICE_FIELDS = ("plan_code", "period", "duration_period", "duration_count", "currency", "amount_cents", "channel_bindings", "version")
# 始终可变的运营字段
MUTABLE_PRICE_FIELDS = ("sellable", "lookup_key", "payment_methods", "effective_from")

BINDING_FIELDS = (
    "payment_method",
    "channel_code",
    "account_code",
    "mode",
    "external_product_id",
    "external_price_id",
    "pricing_strategy",
    "base_currency",
    "base_amount_cents",
    "discount_mode",
    "discount_code",
    "enabled",
)


class CatalogError(ValueError):
    """catalog 校验/约束错误,API 层统一映射为 400。"""


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _norm(value: Any) -> str:
    return str(value or "").strip().lower()


def _str(value: Any) -> str:
    return str(value or "").strip()


def _int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except Exception:
        return default


def _nn_int(value: Any) -> int:
    return max(0, _int(value, 0))


def _norm_code(value: Any) -> str:
    code = _norm(value)
    return code if code and PLAN_CODE_RE.match(code) else ""


def _strip_id(doc: dict[str, Any] | None) -> dict[str, Any]:
    row = dict(doc or {})
    row.pop("_id", None)
    return row


def lookup_key_for(plan_code: str, period: str) -> str:
    return f"{_norm(plan_code)}_{_norm(period)}"


def product_code_for(plan_code: str, period: str) -> str:
    return f"{_norm(plan_code)}_{_norm(period)}"


# ---------------------------------------------------------------------------
# 模型清洗
# ---------------------------------------------------------------------------


def clean_plan(payload: dict[str, Any] | None, existing: dict[str, Any] | None = None) -> dict[str, Any]:
    """清洗/合并 billing_plans 文档;payload 只需携带要变更的字段。"""
    data = dict(payload or {})
    base = _strip_id(existing)
    code = _norm_code(data.get("plan_code") or base.get("plan_code"))
    if not code:
        raise CatalogError("plan_code 不合法(仅支持小写字母/数字/_/-)")

    def pick(field: str, default: Any) -> Any:
        if field in data and data[field] is not None:
            return data[field]
        return base.get(field, default)

    paid = bool(pick("paid", code not in {"free", "trial"}))
    status = _norm(pick("status", "active")) or "active"
    if status not in PLAN_STATUSES:
        raise CatalogError("status 仅支持 active/hidden/retired")
    plan_family = _norm(pick("plan_family", "base")) or "base"
    if plan_family not in PLAN_FAMILIES:
        raise CatalogError("plan_family 仅支持 base/addon")

    display = dict(base.get("display") or {})
    if isinstance(data.get("display"), dict):
        display.update(data["display"])
    display = {
        "description": _str(display.get("description")),
        "sort_order": _int(display.get("sort_order"), 0),
        "badge": _str(display.get("badge")),
    }

    # 积分/有效期(entitlements)已迁出 catalog:真源是 plan_configs,billing_plans 不再建模。
    legacy = data.get("legacy") if isinstance(data.get("legacy"), dict) else (base.get("legacy") or {})
    return {
        "plan_code": code,
        "rank": _int(pick("rank", 10 if paid else 0), 0),
        "name": _str(pick("name", "")) or code,
        "display": display,
        "paid": paid,
        "status": status,
        "plan_family": plan_family,
        "stackable": bool(pick("stackable", False)),
        "self_checkout_enabled": bool(pick("self_checkout_enabled", paid)),
        "auto_renew_supported": bool(pick("auto_renew_supported", paid)),
        "paid_topup_enabled": bool(pick("paid_topup_enabled", paid)),
        "legacy": dict(legacy),
        "created_at": base.get("created_at"),
        "updated_at": _now(),
    }


def _clean_binding(key: str, raw: Any, price_amount_cents: int) -> dict[str, Any]:
    binding = raw if isinstance(raw, dict) else {}
    channel_code = _norm(binding.get("channel_code")) or _norm(str(key).split("#")[0])
    if not channel_code:
        raise CatalogError("channel_bindings 缺少 channel_code")
    mode = _norm(binding.get("mode")) or "amount_order"
    if mode not in BINDING_MODES:
        raise CatalogError(f"channel_bindings[{key}].mode 仅支持 external_product/amount_order")
    pricing_strategy = _norm(binding.get("pricing_strategy")) or "fixed"
    if pricing_strategy not in {"fixed", "exchange_rate"}:
        pricing_strategy = "fixed"
    discount_mode = _norm(binding.get("discount_mode")) or "none"
    if discount_mode not in {"none", "auto_apply"}:
        discount_mode = "none"
    row = {
        "payment_method": _norm(binding.get("payment_method")),
        "channel_code": channel_code,
        "account_code": _norm(binding.get("account_code")),
        "mode": mode,
        "external_product_id": _str(binding.get("external_product_id")),
        "external_price_id": _str(binding.get("external_price_id")),
        "pricing_strategy": pricing_strategy,
        "base_currency": (_norm(binding.get("base_currency")) or "usd").upper(),
        "base_amount_cents": _nn_int(binding.get("base_amount_cents")),
        "discount_mode": discount_mode,
        "discount_code": _str(binding.get("discount_code")) if discount_mode == "auto_apply" else "",
        "enabled": bool(binding.get("enabled", True)),
    }
    # 仅当与 price 主金额不一致时保留渠道级金额覆盖(迁移兼容多渠道同币种不同价的旧数据)
    if "amount_cents" in binding and _nn_int(binding.get("amount_cents")) != price_amount_cents:
        row["amount_cents"] = _nn_int(binding.get("amount_cents"))
    return row


def clean_price(payload: dict[str, Any] | None) -> dict[str, Any]:
    data = dict(payload or {})
    plan_code = _norm_code(data.get("plan_code"))
    if not plan_code:
        raise CatalogError("plan_code 不合法")
    period = _norm(data.get("period"))
    if period not in PRICE_PERIODS:
        raise CatalogError("period 仅支持 monthly/quarterly/yearly")
    default_duration_period, default_duration_count = DEFAULT_DURATIONS[period]
    duration_period = _norm(data.get("duration_period")) or default_duration_period
    if duration_period not in DURATION_PERIODS:
        raise CatalogError("duration_period 仅支持 month/year")
    duration_count = max(1, _int(data.get("duration_count") or default_duration_count, 1))
    currency = (_norm(data.get("currency")) or "").upper()
    if not currency:
        raise CatalogError("currency 不能为空")
    amount_cents = _nn_int(data.get("amount_cents"))

    bindings: dict[str, dict[str, Any]] = {}
    raw_bindings = data.get("channel_bindings") if isinstance(data.get("channel_bindings"), dict) else {}
    for key, raw in raw_bindings.items():
        bindings[str(key)] = _clean_binding(str(key), raw, amount_cents)

    payment_methods = [
        _norm(item) for item in (data.get("payment_methods") or []) if _norm(item)
    ] if isinstance(data.get("payment_methods"), list) else []
    if not payment_methods:
        payment_methods = sorted({b["payment_method"] for b in bindings.values() if b.get("payment_method")})

    return {
        "price_id": _str(data.get("price_id")),
        "plan_code": plan_code,
        "period": period,
        "duration_period": duration_period,
        "duration_count": duration_count,
        "currency": currency,
        "amount_cents": amount_cents,
        "lookup_key": _str(data.get("lookup_key")),
        "sellable": bool(data.get("sellable", False)),
        "version": max(0, _int(data.get("version"), 0)),
        "channel_bindings": bindings,
        "payment_methods": payment_methods,
        "effective_from": data.get("effective_from"),
    }


# ---------------------------------------------------------------------------
# plans 读写
# ---------------------------------------------------------------------------


async def list_plans(db) -> list[dict[str, Any]]:
    rows = [_strip_id(doc) for doc in await db[PLANS_COLLECTION].find({}).to_list(None)]
    rows.sort(key=lambda row: ((row.get("display") or {}).get("sort_order") or 0, row.get("plan_code") or ""))
    return rows


async def get_plan(db, plan_code: str) -> dict[str, Any] | None:
    doc = await db[PLANS_COLLECTION].find_one({"plan_code": _norm(plan_code)})
    return _strip_id(doc) if doc else None


async def upsert_plan(db, payload: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """新建/更新 plan 的价格归属与展示元数据(name/display 等)。

    catalog 不再定义积分/等级/可购性,故 upsert 不产生"发布后影响"提示;
    返回的 hints 恒为空,仅为保持接口形状(``{plan, impact_hints}``)不变。
    """
    code = _norm_code((payload or {}).get("plan_code"))
    if not code:
        raise CatalogError("plan_code 不合法(仅支持小写字母/数字/_/-)")
    existing = await db[PLANS_COLLECTION].find_one({"plan_code": code})
    plan = clean_plan(payload, existing)
    hints: list[str] = []
    if existing:
        await db[PLANS_COLLECTION].update_one({"plan_code": code}, {"$set": plan})
    else:
        plan["created_at"] = plan["updated_at"]
        await db[PLANS_COLLECTION].insert_one(dict(plan))
    return _strip_id(plan), hints


async def set_plan_status(db, plan_code: str, status: str) -> dict[str, Any]:
    code = _norm(plan_code)
    status = _norm(status)
    if status not in PLAN_STATUSES:
        raise CatalogError("status 仅支持 active/hidden/retired")
    existing = await db[PLANS_COLLECTION].find_one({"plan_code": code})
    if not existing:
        raise CatalogError(f"套餐不存在: {code}")
    await db[PLANS_COLLECTION].update_one({"plan_code": code}, {"$set": {"status": status, "updated_at": _now()}})
    plan = _strip_id(existing)
    plan["status"] = status
    return plan


# ---------------------------------------------------------------------------
# prices 读写与不可变约束
# ---------------------------------------------------------------------------


async def list_prices(db, plan_code: str = "") -> list[dict[str, Any]]:
    query = {"plan_code": _norm(plan_code)} if _norm(plan_code) else {}
    rows = [_strip_id(doc) for doc in await db[PRICES_COLLECTION].find(query).to_list(None)]
    rows.sort(key=lambda row: (
        row.get("plan_code") or "",
        PERIOD_ORDER.get(row.get("period"), 99),
        row.get("currency") or "",
        -_int(row.get("version"), 0),
    ))
    return rows


async def get_price(db, price_id: str) -> dict[str, Any] | None:
    doc = await db[PRICES_COLLECTION].find_one({"price_id": _str(price_id)})
    return _strip_id(doc) if doc else None


async def price_referenced_by_orders(db, price_id: str) -> bool:
    price_id = _str(price_id)
    if not price_id:
        return False
    if await db["payment_orders"].find_one({"price_id": price_id}):
        return True
    return bool(await db["payment_orders"].find_one({"price_snapshot.price_id": price_id}))


async def price_is_locked(db, price: dict[str, Any]) -> bool:
    """曾在售或被订单引用的 price,计费字段不可再修改。"""
    if bool(price.get("ever_sellable")) or bool(price.get("sellable")):
        return True
    return await price_referenced_by_orders(db, price.get("price_id") or "")


async def create_price(db, payload: dict[str, Any]) -> dict[str, Any]:
    if _nn_int((payload or {}).get("amount_cents")) <= 0:
        raise CatalogError("amount_cents 必须大于 0")
    price = clean_price(payload)
    plan = await db[PLANS_COLLECTION].find_one({"plan_code": price["plan_code"]})
    if not plan:
        raise CatalogError(f"套餐不存在,请先创建 billing_plans: {price['plan_code']}")

    siblings = [
        row for row in await db[PRICES_COLLECTION].find({"plan_code": price["plan_code"]}).to_list(None)
        if row.get("period") == price["period"] and row.get("currency") == price["currency"]
    ]
    if not price["version"]:
        price["version"] = max((_int(row.get("version"), 0) for row in siblings), default=0) + 1
    if not price["price_id"]:
        price["price_id"] = f"{price['plan_code']}_{price['period']}_{price['currency'].lower()}_v{price['version']}"
    if await db[PRICES_COLLECTION].find_one({"price_id": price["price_id"]}):
        raise CatalogError(f"price_id 已存在: {price['price_id']}(price 不可变,如需改价请新建版本)")

    if price["lookup_key"]:
        holder = next(
            (
                row for row in await db[PRICES_COLLECTION].find({"lookup_key": price["lookup_key"]}).to_list(None)
                if row.get("currency") == price["currency"]
            ),
            None,
        )
        if holder:
            raise CatalogError(
                f"lookup_key={price['lookup_key']}({price['currency']}) 已由 {holder.get('price_id')} 持有,"
                "请创建后调用 make-current 转移"
            )

    now = _now()
    price["ever_sellable"] = bool(price["sellable"])
    price["created_at"] = now
    price["updated_at"] = now
    if not price.get("effective_from"):
        price["effective_from"] = now
    await db[PRICES_COLLECTION].insert_one(dict(price))
    return _strip_id(price)


async def update_price(db, price_id: str, updates: dict[str, Any]) -> dict[str, Any]:
    """price 唯一的更新入口:曾在售/被引用的 price 仅允许改 sellable/lookup_key 等运营字段。"""
    price = await db[PRICES_COLLECTION].find_one({"price_id": _str(price_id)})
    if not price:
        raise CatalogError(f"价格不存在: {price_id}")
    updates = dict(updates or {})
    locked = await price_is_locked(db, price)
    changed_immutable = [
        field for field in IMMUTABLE_PRICE_FIELDS
        if field in updates and _jsonable(updates[field]) != _jsonable(price.get(field))
    ]
    if changed_immutable and locked:
        raise CatalogError(
            f"price {price.get('price_id')} 已在售或被订单引用,计费字段不可变: {', '.join(sorted(changed_immutable))};"
            "改价请新建 version+1 的 price 并 make-current"
        )
    allowed: dict[str, Any] = {}
    for field in MUTABLE_PRICE_FIELDS:
        if field in updates:
            allowed[field] = updates[field]
    if not locked:
        for field in changed_immutable:
            allowed[field] = updates[field]
    if "sellable" in allowed:
        allowed["sellable"] = bool(allowed["sellable"])
        if allowed["sellable"]:
            allowed["ever_sellable"] = True
    if "lookup_key" in allowed:
        allowed["lookup_key"] = _str(allowed["lookup_key"])
    allowed["updated_at"] = _now()
    await db[PRICES_COLLECTION].update_one({"price_id": price["price_id"]}, {"$set": allowed})
    return _strip_id({**price, **allowed})


async def archive_price(db, price_id: str) -> dict[str, Any]:
    """归档:仅下架(sellable=false),不清除 lookup_key、不影响存量订阅。"""
    return await update_price(db, price_id, {"sellable": False})


async def make_price_current(db, price_id: str) -> dict[str, Any]:
    """把 lookup_key 转移到该 price(成为在售版),同币种旧持有者自动下架。"""
    price = await db[PRICES_COLLECTION].find_one({"price_id": _str(price_id)})
    if not price:
        raise CatalogError(f"价格不存在: {price_id}")
    lookup_key = lookup_key_for(price.get("plan_code"), price.get("period"))
    now = _now()
    holders = await db[PRICES_COLLECTION].find({"lookup_key": lookup_key}).to_list(None)
    for holder in holders:
        if holder.get("price_id") == price.get("price_id") or holder.get("currency") != price.get("currency"):
            continue
        await db[PRICES_COLLECTION].update_one(
            {"price_id": holder["price_id"]},
            {"$set": {"lookup_key": "", "sellable": False, "updated_at": now}},
        )
    await db[PRICES_COLLECTION].update_one(
        {"price_id": price["price_id"]},
        {"$set": {"lookup_key": lookup_key, "sellable": True, "ever_sellable": True, "updated_at": now}},
    )
    return _strip_id({**price, "lookup_key": lookup_key, "sellable": True, "ever_sellable": True, "updated_at": now})


# ---------------------------------------------------------------------------
# 发布投影(物化)
# ---------------------------------------------------------------------------


def _current_price_rows(prices: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """当前在售版 = 持有 lookup_key 的 price(每 plan×period×currency 至多一条)。"""
    return [row for row in prices or [] if _str(row.get("lookup_key"))]


def _binding_to_channel_price_row(product_code: str, price: dict[str, Any], binding: dict[str, Any]) -> dict[str, Any]:
    return {
        "product_code": product_code,
        "payment_method": binding.get("payment_method") or "",
        "channel_code": binding.get("channel_code") or "",
        "account_code": binding.get("account_code") or "",
        "mode": binding.get("mode") or "amount_order",
        "currency": price.get("currency"),
        "amount_cents": _nn_int(binding.get("amount_cents", price.get("amount_cents"))),
        "pricing_strategy": binding.get("pricing_strategy") or "fixed",
        "base_currency": binding.get("base_currency") or "USD",
        "base_amount_cents": _nn_int(binding.get("base_amount_cents")),
        "external_product_id": binding.get("external_product_id") or "",
        "external_price_id": binding.get("external_price_id") or "",
        "discount_mode": binding.get("discount_mode") or "none",
        "discount_code": binding.get("discount_code") or "",
        "enabled": bool(binding.get("enabled", True)),
    }


def build_billing_config_projection(
    current_config: dict[str, Any] | None,
    plans: list[dict[str, Any]],
    prices: list[dict[str, Any]],
    plan_configs: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """由 catalog 物化生成 system_config.payment_billing_config。

    阶段B(D1:catalog 只管价格):套餐的"可购性/名称/是否退役"以 ``plan_configs``
    (套餐定义唯一真源,由管理端 PlansView 编辑)为准,catalog 的 ``billing_plans``
    仅负责"该 plan_code 归 catalog 管价格 + display(sort_order/badge/description)"。

    - currencies / payment_methods / channels / exchange_rate_provider 段原样保留;
    - credits_topup 商品及其渠道价原样保留(不属于 catalog 范畴);
    - catalog 管辖的订阅商品(plan 在 billing_plans 且该 plan×period 有 price 记录):
      * 商品是否出现(retired 移除)= catalog set_plan_status(retired) 或
        plan_configs[plan_code].lifecycle_status ∈ {retired, archived} 之一为真即移除;
      * 商品 ``enabled``(可购性)= 有在售价 且 未退役 且 plan_configs 允许自助购买
        (self_checkout_enabled 且 enabled),plan_configs 未收录的 plan 回退到 billing_plans;
      * 商品 ``name`` 取自 plan_configs(新建条目);已存在条目的文案字段保留原配置;
    - channel_prices 中 catalog 管辖的行全部由在售 price 的 channel_bindings 重新生成。
    """
    config = clean_billing_config(copy.deepcopy(current_config or {}))
    plans_by_code = {_norm(plan.get("plan_code")): plan for plan in plans or [] if _norm(plan.get("plan_code"))}
    plan_configs = plan_configs or {}

    def _plan_cfg(code: str) -> dict[str, Any] | None:
        cfg = plan_configs.get(code)
        return cfg if isinstance(cfg, dict) else None

    def _plan_retired(code: str) -> bool:
        """商品是否退役下架:catalog set_plan_status(retired) 或 plan_configs 生命周期退役,任一为真。"""
        plan = plans_by_code.get(code) or {}
        if _norm(plan.get("status")) == "retired":
            return True
        cfg = _plan_cfg(code)
        if cfg is not None and _norm(cfg.get("lifecycle_status")) in {"retired", "archived"}:
            return True
        return False

    def _plan_self_checkout(code: str) -> bool:
        """是否可自助购买:优先取 plan_configs(真源),未收录的 plan 回退 billing_plans。"""
        cfg = _plan_cfg(code)
        if cfg is not None:
            return bool(cfg.get("self_checkout_enabled")) and bool(cfg.get("enabled", True))
        plan = plans_by_code.get(code) or {}
        return bool(plan.get("self_checkout_enabled", True))

    def _plan_display_name(code: str) -> str:
        """套餐名以 plan_configs 为准,未收录时回退 billing_plans.name 再回退 plan_code。"""
        cfg = _plan_cfg(code)
        if cfg is not None and _str(cfg.get("name")):
            return _str(cfg.get("name"))
        plan = plans_by_code.get(code) or {}
        return _str(plan.get("name")) or code

    # catalog 管辖范围:出现过 price 记录的 (plan_code, period)
    governed = {(_norm(row.get("plan_code")), _norm(row.get("period"))) for row in prices or []}

    # 当前在售商品:plan 未退役(以 plan_configs/catalog 为准)且该 plan×period 存在持有 lookup_key 的 price
    product_prices: dict[str, list[dict[str, Any]]] = {}
    for row in _current_price_rows(prices):
        code = _norm(row.get("plan_code"))
        if code not in plans_by_code or _plan_retired(code):
            continue
        product_prices.setdefault(product_code_for(row.get("plan_code"), row.get("period")), []).append(row)

    def _is_governed_subscription(row: dict[str, Any]) -> bool:
        return (
            _norm(row.get("type")) == "subscription"
            and _norm(row.get("plan_code")) in plans_by_code
            and (_norm(row.get("plan_code")), _norm(row.get("billing_cycle"))) in governed
        )

    def _product_enabled(code: str, rows: list[dict[str, Any]]) -> bool:
        return bool(any(row.get("sellable") for row in rows) and _plan_self_checkout(code))

    original_products = list(config.get("products") or [])
    original_products_by_code = {row.get("code"): row for row in original_products}
    products: list[dict[str, Any]] = []
    for row in original_products:
        if not _is_governed_subscription(row):
            products.append(row)  # credits_topup 或 catalog 未收录的商品:原样保留
            continue
        code = row.get("code")
        if code not in product_prices:
            continue  # plan 退役 或该版本全部下架 → 从投影中移除
        rows = product_prices[code]
        plan_code = _norm(rows[0].get("plan_code"))
        updated = dict(row)
        # 可购性以 plan_configs.self_checkout 为准重算;名称等文案沿用原配置(可继续维护)
        updated["enabled"] = _product_enabled(plan_code, rows)
        products.append(updated)

    def _new_product_sort_key(code: str) -> tuple:
        rows = product_prices[code]
        plan = plans_by_code.get(_norm(rows[0].get("plan_code"))) or {}
        return (
            _int((plan.get("display") or {}).get("sort_order"), 0),
            _norm(rows[0].get("plan_code")),
            PERIOD_ORDER.get(_norm(rows[0].get("period")), 99),
        )

    for code in sorted((c for c in product_prices if c not in original_products_by_code), key=_new_product_sort_key):
        rows = product_prices[code]
        plan = plans_by_code[_norm(rows[0].get("plan_code"))]
        plan_code = _norm(plan.get("plan_code"))
        period = _norm(rows[0].get("period"))
        products.append({
            "code": code,
            "type": "subscription",
            "name": f"{_plan_display_name(plan_code)} {period}",
            "description": _str((plan.get("display") or {}).get("description")),
            "plan_code": plan_code,
            "billing_cycle": period,
            "enabled": _product_enabled(plan_code, rows),
            "sort_order": _int((plan.get("display") or {}).get("sort_order"), 0),
        })
    config["products"] = products

    channel_rows: list[dict[str, Any]] = []
    for row in config.get("channel_prices") or []:
        product = original_products_by_code.get(row.get("product_code"))
        if product is not None and not _is_governed_subscription(product):
            channel_rows.append(row)  # 非 catalog 管辖(如 credits_topup)原样保留
    product_order = {row.get("code"): index for index, row in enumerate(products)}
    for code in sorted(product_prices, key=lambda c: product_order.get(c, 999)):
        rows = sorted(product_prices[code], key=lambda r: (r.get("currency") or "", -_int(r.get("version"), 0)))
        for price in rows:
            for key in sorted(price.get("channel_bindings") or {}):
                binding = (price.get("channel_bindings") or {})[key]
                channel_rows.append(_binding_to_channel_price_row(code, price, binding))
    config["channel_prices"] = channel_rows

    return clean_billing_config(config)


# ---------------------------------------------------------------------------
# diff
# ---------------------------------------------------------------------------


def _jsonable(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


def _entry_diff(current: Any, projected: Any) -> dict[str, Any]:
    if not isinstance(current, dict) or not isinstance(projected, dict):
        current = current if isinstance(current, dict) else {"value": current}
        projected = projected if isinstance(projected, dict) else {"value": projected}
    changes: dict[str, Any] = {}
    for key in sorted(set(current) | set(projected)):
        before = _jsonable(current.get(key))
        after = _jsonable(projected.get(key))
        if before != after:
            changes[key] = {"from": before, "to": after}
    return changes


def _diff_keyed(current_map: dict[str, Any], projected_map: dict[str, Any]) -> dict[str, Any]:
    added = sorted(key for key in projected_map if key not in current_map)
    removed = sorted(key for key in current_map if key not in projected_map)
    changed: dict[str, Any] = {}
    for key in sorted(current_map):
        if key in projected_map:
            entry = _entry_diff(current_map[key], projected_map[key])
            if entry:
                changed[key] = entry
    return {"added": added, "removed": removed, "changed": changed}


def _channel_price_key(row: dict[str, Any]) -> str:
    return "|".join([
        _norm(row.get("product_code")),
        _norm(row.get("payment_method")),
        _norm(row.get("channel_code")),
        _norm(row.get("account_code")),
        (_norm(row.get("currency")) or "").upper(),
    ])


def diff_billing_config(current: dict[str, Any] | None, projected: dict[str, Any] | None) -> dict[str, Any]:
    current = dict(current or {})
    projected = dict(projected or {})

    def keyed(rows: Any, key_fn) -> dict[str, Any]:
        return {key_fn(row): row for row in (rows if isinstance(rows, list) else [])}

    by_code = lambda row: str(row.get("code") or "")
    return {
        "products": _diff_keyed(keyed(current.get("products"), by_code), keyed(projected.get("products"), by_code)),
        "channel_prices": _diff_keyed(
            keyed(current.get("channel_prices"), _channel_price_key),
            keyed(projected.get("channel_prices"), _channel_price_key),
        ),
        "currencies": _diff_keyed(keyed(current.get("currencies"), by_code), keyed(projected.get("currencies"), by_code)),
        "payment_methods": _diff_keyed(keyed(current.get("payment_methods"), by_code), keyed(projected.get("payment_methods"), by_code)),
        "channels": _diff_keyed(keyed(current.get("channels"), by_code), keyed(projected.get("channels"), by_code)),
        "exchange_rate_provider": _entry_diff(
            current.get("exchange_rate_provider") or {},
            projected.get("exchange_rate_provider") or {},
        ),
    }


def diff_is_empty(diff: Any) -> bool:
    if isinstance(diff, dict):
        if not diff:
            return True
        if set(diff) == {"from", "to"}:
            return False
        if set(diff) == {"added", "removed", "changed"}:
            return not diff["added"] and not diff["removed"] and diff_is_empty(diff["changed"])
        return all(diff_is_empty(value) for value in diff.values())
    return not diff


# ---------------------------------------------------------------------------
# 发布(dry-run / 正式)与审计
# ---------------------------------------------------------------------------


async def publish_catalog(db, *, operator: str = "", dry_run: bool = True) -> dict[str, Any]:
    """发布 catalog:**只把价格投影写回 payment_billing_config**,不再触碰 plan_configs。

    套餐定义(积分/有效期/刷新周期/等级)的唯一真源是 system_config.plan_configs,
    仅由管理端套餐配置页(PlansView)编辑;catalog 只负责"价格"(billing_prices)。
    历史上 catalog 会投影覆盖 plan_configs,导致与 PlansView 双写互相回滚——已移除。
    """
    plans = [_strip_id(doc) for doc in await db[PLANS_COLLECTION].find({}).to_list(None)]
    prices = [_strip_id(doc) for doc in await db[PRICES_COLLECTION].find({}).to_list(None)]
    if not plans:
        raise CatalogError("billing_plans 为空,请先执行 scripts/migrate_catalog_v1.py 迁移或创建套餐")

    billing_doc = await db["system_config"].find_one({"key": BILLING_CONFIG_KEY}) or {}
    current_billing = clean_billing_config(billing_doc.get("value") or {})

    # 套餐定义(可购性/名称/退役)真源 = system_config.plan_configs;catalog 只读不写。
    plan_configs_doc = await db["system_config"].find_one({"key": PLAN_CONFIGS_KEY}) or {}
    plan_configs = plan_configs_doc.get("value") or {}

    projected_billing = build_billing_config_projection(current_billing, plans, prices, plan_configs)

    diff = {
        "billing_config": diff_billing_config(current_billing, projected_billing),
    }
    result: dict[str, Any] = {
        "dry_run": dry_run,
        "has_changes": not diff_is_empty(diff),
        "diff": diff,
        "plan_count": len(plans),
        "price_count": len(prices),
    }
    if dry_run:
        return result

    now = _now()
    await db["system_config"].update_one(
        {"key": BILLING_CONFIG_KEY},
        {"$set": {"key": BILLING_CONFIG_KEY, "value": projected_billing, "updated_at": now}},
        upsert=True,
    )
    _BILLING_CONFIG_CACHE["billing_config"] = projected_billing

    logs = await db[PUBLISH_LOG_COLLECTION].find({}).to_list(None)
    snapshot_version = max((_int(row.get("snapshot_version"), 0) for row in logs), default=0) + 1
    await db[PUBLISH_LOG_COLLECTION].insert_one({
        "published_at": now,
        "operator": _str(operator),
        "diff_summary": _jsonable(diff),
        "snapshot_version": snapshot_version,
        "plan_count": len(plans),
        "price_count": len(prices),
    })
    result.update({"published_at": now, "snapshot_version": snapshot_version, "operator": _str(operator)})
    return result


async def list_publish_log(db, limit: int = 50) -> list[dict[str, Any]]:
    rows = [_strip_id(doc) for doc in await db[PUBLISH_LOG_COLLECTION].find({}).to_list(None)]
    rows.sort(key=lambda row: _int(row.get("snapshot_version"), 0), reverse=True)
    return rows[: max(1, min(200, _int(limit, 50)))]


# ---------------------------------------------------------------------------
# v1 迁移(幂等):现有 plan_configs + payment_billing_config → catalog
# ---------------------------------------------------------------------------


async def migrate_catalog_v1(db) -> dict[str, Any]:
    """从现有配置生成 billing_plans / billing_prices v1;已存在则跳过(幂等)。

    - 每个 plan_code×period×currency 一条 price,price_id=f"{plan}_{period}_{currency}_v1";
    - lookup_key=f"{plan}_{period}"(同 lookup_key 下按 currency 各持有一条在售版);
    - channel_bindings 由 payment_billing_config.channel_prices 按商品×币种归并;
    - sellable 取自 billing_options[cycle].enabled(与投影回读口径一致,保证零 diff)。
    """
    now = _now()
    plan_doc = await db["system_config"].find_one({"key": PLAN_CONFIGS_KEY}) or {}
    plan_configs = plan_doc.get("value") or {}
    billing_doc = await db["system_config"].find_one({"key": BILLING_CONFIG_KEY}) or {}
    billing = clean_billing_config(billing_doc.get("value") or {})

    rows_by_product: dict[str, list[dict[str, Any]]] = {}
    for row in billing.get("channel_prices") or []:
        rows_by_product.setdefault(row.get("product_code") or "", []).append(row)

    stats = {"plans_created": 0, "plans_skipped": 0, "prices_created": 0, "prices_skipped": 0}
    for code in sorted(plan_configs):
        cfg = plan_configs[code]
        if not isinstance(cfg, dict) or not _norm_code(code):
            continue
        code = _norm_code(code)
        existing_plan = await db[PLANS_COLLECTION].find_one({"plan_code": code})
        if existing_plan:
            stats["plans_skipped"] += 1
        else:
            paid = bool(cfg.get("paid"))
            plan = clean_plan({
                "plan_code": code,
                "name": cfg.get("name") or code,
                "rank": _int(cfg.get("rank"), 10 if paid else 0),
                "display": {
                    "description": _str(cfg.get("description")),
                    "sort_order": _int(cfg.get("sort_order"), 0),
                    "badge": _str(cfg.get("badge")),
                },
                "paid": paid,
                "status": "retired" if _norm(cfg.get("lifecycle_status")) == "archived" else "active",
                "plan_family": cfg.get("plan_family") if cfg.get("plan_family") in PLAN_FAMILIES else "base",
                "stackable": bool(cfg.get("stackable", False)),
                "self_checkout_enabled": bool(cfg.get("self_checkout_enabled", paid)),
                "auto_renew_supported": bool(cfg.get("auto_renew_supported", paid)),
                "paid_topup_enabled": bool(cfg.get("paid_topup_enabled", paid)),
                "legacy": dict(cfg),
            })
            plan["created_at"] = plan["updated_at"] = now
            await db[PLANS_COLLECTION].insert_one(dict(plan))
            stats["plans_created"] += 1

        for cycle in sorted(cfg.get("billing_options") or {}, key=lambda p: PERIOD_ORDER.get(_norm(p), 99)):
            option = (cfg.get("billing_options") or {}).get(cycle)
            if not isinstance(option, dict) or _norm(cycle) not in PRICE_PERIODS:
                continue
            cycle = _norm(cycle)
            product_code = product_code_for(code, cycle)
            product_rows = rows_by_product.get(product_code) or []
            if not product_rows:
                # 该 套餐:账期 在支付侧未配置渠道价格,不生成 0 元占位价
                stats["prices_skipped"] += 1
                continue
            currencies: list[str] = []
            for row in product_rows:
                if row.get("currency") not in currencies:
                    currencies.append(row.get("currency"))
            if not currencies:
                currencies = ["USD"]
            for currency in currencies:
                price_id = f"{code}_{cycle}_{str(currency).lower()}_v1"
                if await db[PRICES_COLLECTION].find_one({"price_id": price_id}):
                    stats["prices_skipped"] += 1
                    continue
                currency_rows = [row for row in product_rows if row.get("currency") == currency]
                amount_cents = next(
                    (_nn_int(row.get("amount_cents")) for row in currency_rows if row.get("enabled", True)),
                    _nn_int(currency_rows[0].get("amount_cents")) if currency_rows else 0,
                )
                bindings: dict[str, dict[str, Any]] = {}
                for row in currency_rows:
                    base_key = row.get("channel_code") or "channel"
                    key, suffix = base_key, 2
                    while key in bindings:
                        key = f"{base_key}#{suffix}"
                        suffix += 1
                    bindings[key] = {field: row.get(field) for field in BINDING_FIELDS}
                    bindings[key]["amount_cents"] = row.get("amount_cents")
                price = clean_price({
                    "price_id": price_id,
                    "plan_code": code,
                    "period": cycle,
                    "duration_period": option.get("duration_period"),
                    "duration_count": option.get("duration_count"),
                    "currency": currency,
                    "amount_cents": amount_cents,
                    "lookup_key": lookup_key_for(code, cycle),
                    "sellable": bool(option.get("enabled", True)),
                    "version": 1,
                    "channel_bindings": bindings,
                    "effective_from": now,
                })
                price["ever_sellable"] = bool(price["sellable"])
                price["created_at"] = now
                price["updated_at"] = now
                await db[PRICES_COLLECTION].insert_one(dict(price))
                stats["prices_created"] += 1
    return stats
