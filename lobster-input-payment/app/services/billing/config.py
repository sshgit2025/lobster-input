from datetime import datetime, timezone
from typing import Any

from cachetools import TTLCache

from app.core.database import get_main_db


BILLING_CONFIG_KEY = "payment_billing_config"
CONFIG_CACHE_TTL_SECONDS = 60
_CONFIG_CACHE: TTLCache[str, dict[str, Any]] = TTLCache(maxsize=1, ttl=CONFIG_CACHE_TTL_SECONDS)


# 渠道能力(代扣/折扣/portal/order_mode 等)已由各 PaymentProviderAdapter 子类的 capability
# 类属性声明(见 payment_providers/base.py),不再需要此处的静态渠道表(原 CHANNEL_PROVIDER_DEFS
# 未被 clean/load 消费,为死配置,已删除)。
DISCOUNT_MODES = {"none", "auto_apply"}


def _norm(value: Any) -> str:
    return str(value or "").strip().lower()


def _str(value: Any) -> str:
    return str(value or "").strip()


def _bool(value: Any, default: bool = True) -> bool:
    if value is None:
        return default
    return bool(value)


def _non_negative_int(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except Exception:
        return 0


def _float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except Exception:
        return default


def _billing_product_key(plan_code: str, billing_cycle: str) -> str:
    return f"{_norm(plan_code)}_{_norm(billing_cycle)}"


def _default_method_for_currency(currency: str) -> str:
    return "wechat" if _norm(currency) in {"cny", "rmb"} else "card"


def _product_from_plan(code: str, plan: dict[str, Any], cycle: str, option: dict[str, Any]) -> dict[str, Any]:
    product_code = _billing_product_key(code, cycle)
    return {
        "code": product_code,
        "type": "subscription",
        "name": f"{plan.get('name') or code} {cycle}",
        "description": "",
        "plan_code": _norm(code),
        "billing_cycle": _norm(cycle),
        "enabled": bool(option.get("enabled", True)) and bool(plan.get("self_checkout_enabled", False)),
        "sort_order": int(plan.get("sort_order", 0) or 0),
    }


def default_billing_config(plan_configs: dict[str, Any] | None = None) -> dict[str, Any]:
    products: list[dict[str, Any]] = []
    for plan_code, plan in sorted((plan_configs or {}).items(), key=lambda row: int((row[1] or {}).get("sort_order", 0) or 0)):
        if not isinstance(plan, dict) or not plan.get("paid") or not plan.get("self_checkout_enabled", False):
            continue
        for cycle, option in (plan.get("billing_options") or {}).items():
            if isinstance(option, dict) and option.get("enabled") is not False:
                products.append(_product_from_plan(plan_code, plan, cycle, option))
    return clean_billing_config({
        "products": products,
        "currencies": [
            {"code": "USD", "name": "美元", "symbol": "$", "rate_to_usd": 1, "rate_source": "fixed", "auto_update": False, "enabled": True},
            {"code": "CNY", "name": "人民币", "symbol": "¥", "rate_to_usd": 0.138, "rate_source": "manual", "auto_update": False, "enabled": True},
        ],
        "payment_methods": [
            {"code": "card", "name": "银行卡", "description": "Visa / Mastercard", "enabled": True, "sort_order": 10, "currencies": ["USD"], "channel_code": "creem"},
            {"code": "wechat", "name": "微信支付", "description": "中国大陆用户推荐", "enabled": False, "sort_order": 20, "currencies": ["CNY"], "channel_code": "zpay"},
        ],
        "channels": [
            {"code": "creem", "provider_code": "creem", "name": "Creem", "enabled": True, "active_account_code": "", "accounts": []},
            {"code": "zpay", "provider_code": "zpay", "name": "ZPay", "enabled": False, "active_account_code": "", "accounts": []},
        ],
        "channel_prices": [],
        "exchange_rate_provider": {"provider": "manual", "api_key": "", "base_currency": "USD", "refresh_hour": 3, "enabled": False},
    })


def clean_billing_config(value: Any) -> dict[str, Any]:
    data = value if isinstance(value, dict) else {}

    products = []
    seen_products: set[str] = set()
    for raw in data.get("products") if isinstance(data.get("products"), list) else []:
        if not isinstance(raw, dict):
            continue
        code = _norm(raw.get("code"))
        product_type = _norm(raw.get("type"))
        if not code or code in seen_products or product_type not in {"subscription", "credits_topup"}:
            continue
        row = {
            "code": code,
            "type": product_type,
            "name": _str(raw.get("name")) or code,
            "description": _str(raw.get("description")),
            "enabled": _bool(raw.get("enabled"), True),
            "sort_order": int(raw.get("sort_order", 0) or 0),
        }
        if product_type == "subscription":
            row["plan_code"] = _norm(raw.get("plan_code"))
            row["billing_cycle"] = _norm(raw.get("billing_cycle"))
        else:
            row["topup_credits"] = _non_negative_int(raw.get("topup_credits") or raw.get("credits"))
        products.append(row)
        seen_products.add(code)

    currencies = []
    seen_currencies: set[str] = set()
    for raw in data.get("currencies") if isinstance(data.get("currencies"), list) else []:
        if not isinstance(raw, dict):
            continue
        code = _norm(raw.get("code")).upper()
        if not code or code in seen_currencies:
            continue
        rate = _float(raw.get("rate_to_usd"), 1.0 if code == "USD" else 0.0)
        currencies.append({
            "code": code,
            "name": _str(raw.get("name")) or code,
            "symbol": _str(raw.get("symbol")),
            "rate_to_usd": 1.0 if code == "USD" else max(0.0, rate),
            "rate_source": _norm(raw.get("rate_source")) or ("fixed" if code == "USD" else "manual"),
            "auto_update": False if code == "USD" else bool(raw.get("auto_update", False)),
            "enabled": _bool(raw.get("enabled"), True),
            "updated_at": raw.get("updated_at"),
        })
        seen_currencies.add(code)
    if "USD" not in seen_currencies:
        currencies.insert(0, {"code": "USD", "name": "美元", "symbol": "$", "rate_to_usd": 1.0, "rate_source": "fixed", "auto_update": False, "enabled": True, "updated_at": None})
        seen_currencies.add("USD")

    methods = []
    seen_methods: set[str] = set()
    for raw in data.get("payment_methods") if isinstance(data.get("payment_methods"), list) else []:
        if not isinstance(raw, dict):
            continue
        code = _norm(raw.get("code"))
        if not code or code in seen_methods:
            continue
        currencies_for_method = [
            _norm(item).upper()
            for item in raw.get("currencies", [])
            if _norm(item).upper() in seen_currencies
        ] if isinstance(raw.get("currencies"), list) else []
        methods.append({
            "code": code,
            "name": _str(raw.get("name")) or code,
            "description": _str(raw.get("description")),
            "enabled": _bool(raw.get("enabled"), True),
            "sort_order": int(raw.get("sort_order", 0) or 0),
            "currencies": currencies_for_method,
            "channel_code": _norm(raw.get("channel_code")),
        })
        seen_methods.add(code)

    channels = []
    seen_channels: set[str] = set()
    for raw in data.get("channels") if isinstance(data.get("channels"), list) else []:
        if not isinstance(raw, dict):
            continue
        code = _norm(raw.get("code"))
        provider_code = _norm(raw.get("provider_code"))
        if not code or not provider_code or code in seen_channels:
            continue
        accounts = []
        seen_accounts: set[str] = set()
        for account in raw.get("accounts") if isinstance(raw.get("accounts"), list) else []:
            if not isinstance(account, dict):
                continue
            account_code = _norm(account.get("code"))
            if not account_code or account_code in seen_accounts:
                continue
            accounts.append({
                "code": account_code,
                "name": _str(account.get("name")) or account_code,
                "enabled": _bool(account.get("enabled"), True),
                "environment": _norm(account.get("environment")) or "live",
                "merchant_id": _str(account.get("merchant_id") or account.get("pid")),
                "api_base_url": _str(account.get("api_base_url")),
                "api_key": _str(account.get("api_key")),
                "webhook_secret": _str(account.get("webhook_secret")),
                "dashboard_url": _str(account.get("dashboard_url")),
                "settlement_currency": (_norm(account.get("settlement_currency")) or "usd").upper(),
            })
            seen_accounts.add(account_code)
        active = _norm(raw.get("active_account_code"))
        if active not in seen_accounts:
            first_enabled = next((item["code"] for item in accounts if item.get("enabled", True)), "")
            active = first_enabled
        channels.append({
            "code": code,
            "provider_code": provider_code,
            "name": _str(raw.get("name")) or code,
            "enabled": _bool(raw.get("enabled"), True),
            "active_account_code": active,
            "accounts": accounts,
        })
        seen_channels.add(code)

    channel_prices = []
    seen_prices: set[tuple[str, str, str, str]] = set()
    for raw in data.get("channel_prices") if isinstance(data.get("channel_prices"), list) else []:
        if not isinstance(raw, dict):
            continue
        product_code = _norm(raw.get("product_code"))
        method = _norm(raw.get("payment_method"))
        channel_code = _norm(raw.get("channel_code"))
        account_code = _norm(raw.get("account_code"))
        currency = _norm(raw.get("currency")).upper()
        if not product_code or product_code not in seen_products or not method or method not in seen_methods or not channel_code or channel_code not in seen_channels or currency not in seen_currencies:
            continue
        key = (product_code, method, channel_code, account_code, currency)
        if key in seen_prices:
            continue
        mode = _norm(raw.get("mode")) or "amount_order"
        if mode not in {"external_product", "amount_order"}:
            mode = "amount_order"
        pricing_strategy = _norm(raw.get("pricing_strategy")) or "fixed"
        if pricing_strategy not in {"fixed", "exchange_rate"}:
            pricing_strategy = "fixed"
        discount_mode = _norm(raw.get("discount_mode")) or "none"
        if discount_mode not in DISCOUNT_MODES:
            discount_mode = "none"
        channel_prices.append({
            "product_code": product_code,
            "payment_method": method,
            "channel_code": channel_code,
            "account_code": account_code,
            "mode": mode,
            "currency": currency,
            "amount_cents": _non_negative_int(raw.get("amount_cents")),
            "pricing_strategy": pricing_strategy,
            "base_currency": (_norm(raw.get("base_currency")) or "usd").upper(),
            "base_amount_cents": _non_negative_int(raw.get("base_amount_cents")),
            "external_product_id": _str(raw.get("external_product_id")),
            "external_price_id": _str(raw.get("external_price_id")),
            "discount_mode": discount_mode,
            "discount_code": _str(raw.get("discount_code")) if discount_mode == "auto_apply" else "",
            "enabled": _bool(raw.get("enabled"), True),
        })
        seen_prices.add(key)

    exchange = data.get("exchange_rate_provider") if isinstance(data.get("exchange_rate_provider"), dict) else {}
    return {
        "products": products,
        "currencies": currencies,
        "payment_methods": methods,
        "channels": channels,
        "channel_prices": channel_prices,
        "exchange_rate_provider": {
            "provider": _norm(exchange.get("provider")) or "manual",
            "api_key": _str(exchange.get("api_key")),
            "base_currency": (_norm(exchange.get("base_currency")) or "usd").upper(),
            "refresh_hour": min(23, max(0, int(exchange.get("refresh_hour", 3) or 3))),
            "enabled": bool(exchange.get("enabled", False)),
            "last_refreshed_at": exchange.get("last_refreshed_at"),
        },
    }


async def load_billing_config(*, refresh: bool = False) -> dict[str, Any]:
    cache_key = "billing_config"
    if not refresh:
        cached = _CONFIG_CACHE.get(cache_key)
        if cached is not None:
            return dict(cached)
    db = get_main_db()
    doc = await db["system_config"].find_one({"key": BILLING_CONFIG_KEY})
    if doc:
        config = clean_billing_config(doc.get("value"))
    else:
        plan_doc = await db["system_config"].find_one({"key": "plan_configs"})
        config = default_billing_config((plan_doc or {}).get("value") or {})
        await save_billing_config(config, refresh=False)
    _CONFIG_CACHE[cache_key] = config
    return dict(config)


async def save_billing_config(value: dict[str, Any], *, refresh: bool = True) -> dict[str, Any]:
    config = clean_billing_config(value)
    await get_main_db()["system_config"].update_one(
        {"key": BILLING_CONFIG_KEY},
        {"$set": {"key": BILLING_CONFIG_KEY, "value": config, "updated_at": datetime.now(timezone.utc)}},
        upsert=True,
    )
    if refresh:
        _CONFIG_CACHE["billing_config"] = config
    return config


def products_by_code(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["code"]: item for item in config.get("products") or []}


def currencies_by_code(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["code"]: item for item in config.get("currencies") or []}


def methods_by_code(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["code"]: item for item in config.get("payment_methods") or []}


def channels_by_code(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["code"]: item for item in config.get("channels") or []}


def active_account(channel: dict[str, Any]) -> dict[str, Any] | None:
    active = _norm(channel.get("active_account_code"))
    for account in channel.get("accounts") or []:
        if account.get("code") == active and account.get("enabled", True):
            return account
    return next((account for account in channel.get("accounts") or [] if account.get("enabled", True)), None)


def _channel_price_rows(config: dict[str, Any], product_code: str = "") -> list[dict[str, Any]]:
    product_code = _norm(product_code)
    rows = [item for item in config.get("channel_prices") or [] if item.get("enabled", True)]
    if product_code:
        rows = [item for item in rows if item.get("product_code") == product_code]
    return rows


def price_to_usd_cents(config: dict[str, Any], amount_cents: int, currency: str) -> int:
    currency_row = currencies_by_code(config).get(_norm(currency).upper()) or {}
    rate = float(currency_row.get("rate_to_usd") or 0)
    if _norm(currency).upper() == "USD":
        rate = 1.0
    if rate <= 0:
        return 0
    return int(round(int(amount_cents or 0) * rate))


def price_from_usd_cents(config: dict[str, Any], usd_cents: int, currency: str) -> int:
    currency_code = _norm(currency).upper()
    if currency_code == "USD":
        return int(usd_cents or 0)
    currency_row = currencies_by_code(config).get(currency_code) or {}
    rate = float(currency_row.get("rate_to_usd") or 0)
    if rate <= 0:
        return 0
    return int(round(int(usd_cents or 0) / rate))


def materialize_channel_price(config: dict[str, Any], row: dict[str, Any]) -> dict[str, Any]:
    price = dict(row or {})
    currency = price.get("currency") or ""
    amount_cents = int(price.get("amount_cents") or 0)
    if price.get("pricing_strategy") == "exchange_rate":
        base_amount = int(price.get("base_amount_cents") or 0)
        base_currency = price.get("base_currency") or "USD"
        if base_amount > 0:
            usd_cents = price_to_usd_cents(config, base_amount, base_currency)
            converted = price_from_usd_cents(config, usd_cents, currency)
            if converted > 0:
                amount_cents = converted
                price["amount_cents"] = converted
    price["display_amount_cents"] = price_to_usd_cents(config, amount_cents, currency)
    return price


def default_price(config: dict[str, Any], product_code: str, currency: str = "") -> dict[str, Any] | None:
    rows = _channel_price_rows(config, product_code)
    if currency:
        wanted = _norm(currency).upper()
        match = next((row for row in rows if row.get("currency") == wanted), None)
        if match:
            return materialize_channel_price(config, match)
    usd = next((row for row in rows if row.get("currency") == "USD"), None)
    if usd:
        return materialize_channel_price(config, usd)
    first = rows[0] if rows else None
    if not first:
        return None
    return materialize_channel_price(config, first)


def resolve_binding(config: dict[str, Any], product_code: str, payment_method: str, currency: str = "") -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    product_code = _norm(product_code)
    payment_method = _norm(payment_method) or _default_method_for_currency(currency)
    method = methods_by_code(config).get(payment_method)
    if not method or not method.get("enabled", True):
        raise ValueError("支付方式未启用")
    channel_code = _norm(method.get("channel_code"))
    channel = channels_by_code(config).get(channel_code)
    if not channel or not channel.get("enabled", True):
        raise ValueError("支付渠道未启用")
    account = active_account(channel)
    if not account:
        raise ValueError("支付渠道未选择激活账号")
    rows = [
        item for item in _channel_price_rows(config, product_code)
        if item.get("payment_method") == payment_method
        and item.get("channel_code") == channel_code
        and item.get("account_code") == account.get("code")
    ]
    if currency:
        wanted = _norm(currency).upper()
        rows = [item for item in rows if item.get("currency") == wanted] or rows
    if not rows:
        raise ValueError("该商品未配置当前渠道价格")
    return method, materialize_channel_price(config, rows[0]), {**account, "provider_code": channel.get("provider_code"), "channel_code": channel.get("code"), "channel_name": channel.get("name")}
