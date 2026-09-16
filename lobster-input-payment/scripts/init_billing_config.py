import asyncio
from datetime import datetime, timezone
from typing import Any

import httpx

from app.core.database import close_db, connect_db, get_main_db
from app.services.billing_config import BILLING_CONFIG_KEY, clean_billing_config, default_billing_config, save_billing_config


def _norm(value: Any) -> str:
    return str(value or "").strip().lower()


def _str(value: Any) -> str:
    return str(value or "").strip()


def _int(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except Exception:
        return 0


def _list(value: Any) -> list[dict[str, Any]]:
    return value if isinstance(value, list) else []


def _old_account_code(account: dict[str, Any]) -> str:
    return _norm(account.get("code") or account.get("id") or account.get("account_code"))


def _account_from_old(account: dict[str, Any], provider_code: str) -> dict[str, Any]:
    code = _old_account_code(account)
    return {
        "code": code,
        "name": _str(account.get("name")) or code,
        "enabled": bool(account.get("enabled", True)),
        "environment": _norm(account.get("environment")) or "live",
        "merchant_id": _str(account.get("merchant_id") or account.get("pid")),
        "api_base_url": _str(account.get("api_base_url")),
        "api_key": _str(account.get("api_key")),
        "webhook_secret": _str(account.get("webhook_secret")),
        "dashboard_url": _str(account.get("dashboard_url")),
        "settlement_currency": _norm(account.get("settlement_currency") or ("cny" if provider_code == "zpay" else "usd")).upper(),
    }


def _find_price(old_prices: list[dict[str, Any]], product_code: str, currency: str) -> dict[str, Any]:
    wanted_currency = _norm(currency).upper()
    for price in old_prices:
        if _norm(price.get("product_code")) == product_code and _norm(price.get("currency")).upper() == wanted_currency:
            return price
    for price in old_prices:
        if _norm(price.get("product_code")) == product_code:
            return price
    return {}


def _build_channels(old_config: dict[str, Any]) -> list[dict[str, Any]]:
    accounts_by_provider: dict[str, list[dict[str, Any]]] = {"creem": [], "zpay": []}
    for account in _list(old_config.get("channel_accounts")):
        provider_code = _norm(account.get("provider_code") or account.get("provider") or account.get("channel_code"))
        if provider_code not in accounts_by_provider:
            continue
        normalized = _account_from_old(account, provider_code)
        if normalized["code"]:
            accounts_by_provider[provider_code].append(normalized)
    if not accounts_by_provider["zpay"]:
        accounts_by_provider["zpay"].append({
            "code": "zpay_live",
            "name": "ZPay 正式",
            "enabled": False,
            "environment": "live",
            "merchant_id": "2025082621264355",
            "api_base_url": "https://zpayz.cn",
            "api_key": "",
            "webhook_secret": "",
            "dashboard_url": "https://zpayz.cn",
            "settlement_currency": "CNY",
        })
    channels = []
    for code, name in (("creem", "Creem"), ("zpay", "ZPay")):
        accounts = accounts_by_provider[code]
        active = next((item["code"] for item in accounts if item.get("enabled", True)), "")
        channels.append({
            "code": code,
            "provider_code": code,
            "name": name,
            "enabled": code == "creem" or any(item.get("enabled", True) and item.get("api_key") for item in accounts),
            "active_account_code": active,
            "accounts": accounts,
        })
    return channels


def _build_channel_prices(new_config: dict[str, Any], old_config: dict[str, Any]) -> list[dict[str, Any]]:
    old_prices = _list(old_config.get("prices"))
    old_bindings = _list(old_config.get("channel_bindings"))
    products = {item["code"]: item for item in new_config.get("products") or []}
    channels = {item["code"]: item for item in new_config.get("channels") or []}
    rows: list[dict[str, Any]] = []
    for binding in old_bindings:
        product_code = _norm(binding.get("product_code"))
        if product_code not in products:
            continue
        channel_code = _norm(binding.get("channel_code") or binding.get("provider_code") or binding.get("provider") or "creem")
        if channel_code not in channels:
            continue
        account_code = _norm(binding.get("channel_account_code") or binding.get("account_code"))
        if not account_code:
            account_code = channels[channel_code].get("active_account_code") or ""
        method = _norm(binding.get("payment_method")) or ("wechat" if channel_code == "zpay" else "card")
        currency = _norm(binding.get("currency") or ("CNY" if channel_code == "zpay" else "USD")).upper()
        price = _find_price(old_prices, product_code, currency)
        mode = _norm(binding.get("mode")) or ("amount_order" if channel_code == "zpay" else "external_product")
        rows.append({
            "product_code": product_code,
            "payment_method": method,
            "channel_code": channel_code,
            "account_code": account_code,
            "mode": mode,
            "currency": currency,
            "amount_cents": _int(price.get("amount_cents") or binding.get("amount_cents")),
            "pricing_strategy": _norm(binding.get("pricing_strategy")) or "fixed",
            "base_currency": _norm(binding.get("base_currency") or price.get("base_currency") or "USD").upper(),
            "base_amount_cents": _int(binding.get("base_amount_cents") or price.get("base_amount_cents")),
            "external_product_id": _str(binding.get("external_product_id") or price.get("external_product_id")),
            "external_price_id": _str(binding.get("external_price_id") or price.get("external_price_id")),
            "enabled": bool(binding.get("enabled", True)),
        })
    if rows:
        return rows
    creem = channels.get("creem") or {}
    creem_account = creem.get("active_account_code") or ""
    for product_code in products:
        price = _find_price(old_prices, product_code, "USD")
        if not price:
            continue
        rows.append({
            "product_code": product_code,
            "payment_method": "card",
            "channel_code": "creem",
            "account_code": creem_account,
            "mode": "external_product",
            "currency": "USD",
            "amount_cents": _int(price.get("amount_cents")),
            "pricing_strategy": "fixed",
            "base_currency": "USD",
            "base_amount_cents": 0,
            "external_product_id": _str(price.get("external_product_id")),
            "external_price_id": _str(price.get("external_price_id")),
            "enabled": bool(price.get("enabled", True)),
        })
    return rows


def _ensure_zpay_prices(config: dict[str, Any]) -> dict[str, Any]:
    products = {item["code"]: item for item in config.get("products") or []}
    channels = {item["code"]: item for item in config.get("channels") or []}
    zpay = channels.get("zpay") or {}
    zpay_account = zpay.get("active_account_code") or next((item.get("code") for item in zpay.get("accounts") or tuple() if item.get("code")), "")
    if not zpay_account:
        return config
    prices = config.get("channel_prices") or []
    for product_code in products:
        exists = any(
            price.get("product_code") == product_code
            and price.get("payment_method") == "wechat"
            and price.get("channel_code") == "zpay"
            for price in prices
        )
        if exists:
            continue
        base = next((
            price for price in prices
            if price.get("product_code") == product_code and price.get("currency") == "USD" and price.get("amount_cents")
        ), None)
        if not base:
            continue
        base_amount = _int(base.get("amount_cents"))
        prices.append({
            "product_code": product_code,
            "payment_method": "wechat",
            "channel_code": "zpay",
            "account_code": zpay_account,
            "mode": "amount_order",
            "currency": "CNY",
            "amount_cents": int(round(base_amount / 0.138)),
            "pricing_strategy": "exchange_rate",
            "base_currency": "USD",
            "base_amount_cents": base_amount,
            "external_product_id": "",
            "external_price_id": "",
            "enabled": True,
        })
    config["channel_prices"] = prices
    return config


def _migrate_config(plan_configs: dict[str, Any], old_config: dict[str, Any]) -> dict[str, Any]:
    config = default_billing_config(plan_configs)
    products = config["products"]
    for product in _list(old_config.get("products")):
        product_code = _norm(product.get("code"))
        product_type = _norm(product.get("type"))
        if not product_code or product_type != "credits_topup":
            continue
        products.append({
            "code": product_code,
            "type": "credits_topup",
            "name": _str(product.get("name")) or product_code,
            "description": _str(product.get("description")),
            "topup_credits": _int(product.get("topup_credits") or product.get("credits")),
            "enabled": bool(product.get("enabled", True)),
            "sort_order": _int(product.get("sort_order")) or 900,
        })
    config["currencies"] = old_config.get("currencies") or config["currencies"]
    config["payment_methods"] = [
        method for method in (old_config.get("payment_methods") or config["payment_methods"])
        if _norm(method.get("code")) in {"card", "wechat"}
    ]
    for method in config["payment_methods"]:
        if _norm(method.get("code")) == "card":
            method["channel_code"] = "creem"
            method["currencies"] = method.get("currencies") or ["USD"]
        if _norm(method.get("code")) == "wechat":
            method["channel_code"] = "zpay"
            method["currencies"] = method.get("currencies") or ["CNY"]
    config["channels"] = old_config.get("channels") or _build_channels(old_config)
    config["channel_prices"] = old_config.get("channel_prices") or _build_channel_prices(config, old_config)
    config = _ensure_zpay_prices(config)
    config["exchange_rate_provider"] = old_config.get("exchange_rate_provider") or {
        "provider": "manual",
        "api_key": "",
        "base_currency": "USD",
        "refresh_hour": 3,
        "enabled": False,
    }
    return clean_billing_config(config)


async def _creem_products(account: dict[str, Any]) -> dict[str, dict[str, Any]]:
    api_key = account.get("api_key") or ""
    api_base_url = (account.get("api_base_url") or "").rstrip("/")
    if not api_key or not api_base_url:
        return {}
    async with httpx.AsyncClient(timeout=20.0) as client:
        response = await client.get(
            f"{api_base_url}/v1/products/search",
            headers={"User-Agent": "LobsterInputPayment/1.0", "x-api-key": api_key},
        )
    if response.status_code >= 400:
        print({"account": account.get("code"), "status": response.status_code, "body": response.text[:300]})
        return {}
    payload = response.json()
    items = payload.get("items") if isinstance(payload, dict) else payload
    return {str(item.get("id")): item for item in items or [] if isinstance(item, dict) and item.get("id")}


async def _sync_creem_amounts(config: dict[str, Any]) -> dict[str, Any]:
    products_by_account: dict[str, dict[str, dict[str, Any]]] = {}
    for channel in config.get("channels") or []:
        if channel.get("provider_code") != "creem":
            continue
        for account in channel.get("accounts") or []:
            products_by_account[account["code"]] = await _creem_products(account)
    for price in config.get("channel_prices") or []:
        if price.get("channel_code") != "creem" or price.get("mode") != "external_product":
            continue
        external = (products_by_account.get(price.get("account_code")) or {}).get(price.get("external_product_id"))
        if not external:
            continue
        price["amount_cents"] = _int(external.get("price") or price.get("amount_cents"))
        price["currency"] = _norm(external.get("currency") or price.get("currency") or "USD").upper()
    return config


async def main() -> None:
    await connect_db()
    try:
        db = get_main_db()
        plan_doc = await db["system_config"].find_one({"key": "plan_configs"})
        billing_doc = await db["system_config"].find_one({"key": BILLING_CONFIG_KEY})
        old_config = (billing_doc or {}).get("value") or {}
        config = _migrate_config((plan_doc or {}).get("value") or {}, old_config)
        config = await _sync_creem_amounts(config)
        saved = await save_billing_config(config)
        await db["system_config"].update_one(
            {"key": BILLING_CONFIG_KEY},
            {"$set": {"initialized_at": datetime.now(timezone.utc)}},
        )
        print({
            "ok": True,
            "products": len(saved.get("products") or []),
            "currencies": len(saved.get("currencies") or []),
            "methods": len(saved.get("payment_methods") or []),
            "channels": len(saved.get("channels") or []),
            "channel_prices": len(saved.get("channel_prices") or []),
        })
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
