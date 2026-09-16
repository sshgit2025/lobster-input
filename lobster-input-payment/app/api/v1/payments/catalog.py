"""目录域(Catalog)路由 —— 对客户端暴露在售渠道/套餐目录。"""
from app.api.v1.payments._common import *  # noqa: F401,F403  复用计费域共享内核(工具/常量/鉴权/依赖)

router = APIRouter(tags=["payments"])


@router.get("/catalog")
async def payment_provider_catalog(_: None = Security(verify_callback_key)):
    config = await load_billing_config()
    products = [p for p in config.get("products") or [] if p.get("enabled", True)]
    methods = [m for m in config.get("payment_methods") or [] if m.get("enabled", True)]
    active_accounts = {
        channel.get("code"): channel.get("active_account_code")
        for channel in config.get("channels") or []
        if channel.get("enabled", True)
    }
    product_rows = {}
    subscription_product_keys = []
    available_method_codes: set[str] = set()
    for product in products:
        price = default_price(config, product["code"]) or {}
        display_price_cents = int(price.get("display_amount_cents") or price.get("amount_cents") or 0)
        product_methods = [
            method for method in methods
            if any(
                price_row.get("product_code") == product["code"]
                and price_row.get("payment_method") == method.get("code")
                and price_row.get("enabled", True)
                and price_row.get("account_code") == active_accounts.get(price_row.get("channel_code"))
                for price_row in config.get("channel_prices") or []
            )
        ]
        if display_price_cents <= 0 or not product_methods:
            continue
        row = {
            **product,
            "price_cents": display_price_cents,
            "currency": "USD",
            "channel_prices": [
                materialize_channel_price(config, p) for p in config.get("channel_prices") or []
                if p.get("product_code") == product["code"]
                and p.get("enabled", True)
                and p.get("account_code") == active_accounts.get(p.get("channel_code"))
            ],
            "payment_methods": product_methods,
        }
        product_rows[product["code"]] = row
        for method in row["payment_methods"]:
            available_method_codes.add(method.get("code"))
        if product.get("type") == "subscription":
            subscription_product_keys.append(_subscription_product_key(product.get("plan_code"), product.get("billing_cycle")))
    topup = product_rows.get("credits_topup") or {}
    return {
        "active_provider": "lobster_pay",
        "providers": [{"code": "lobster_pay", "name": "Lobster Pay", "status": "active"}],
        "payment_methods": [method for method in methods if method.get("code") in available_method_codes],
        "products": product_rows,
        "subscriptions_enabled": any(p.get("type") == "subscription" for p in products),
        "subscription_product_keys": sorted(subscription_product_keys),
        "subscription_products": {
            _subscription_product_key(row.get("plan_code"), row.get("billing_cycle")): row
            for row in product_rows.values()
            if row.get("type") == "subscription"
        },
        "credits_topup": {
            "enabled": bool(topup),
            "amount": int(topup.get("topup_credits") or 0),
            "price_cents": int(topup.get("price_cents") or 0),
            "currency": topup.get("currency") or "",
            "product_code": topup.get("code") or "",
            "payment_methods": topup.get("payment_methods") or [],
        },
        "discount": {
            "supported": True,
            "default_enabled": any(
                price.get("channel_code") == "creem"
                and price.get("discount_mode") == "auto_apply"
                and price.get("discount_code")
                for price in config.get("channel_prices") or []
            ),
        },
    }


