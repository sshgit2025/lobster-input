import asyncio
from datetime import datetime, timezone
from typing import Any

import httpx

from app.core.database import close_db, connect_db
from app.services.billing_config import load_billing_config, save_billing_config


def _norm(value: Any) -> str:
    return str(value or "").strip().lower()


def _float(value: Any) -> float:
    try:
        return float(value)
    except Exception:
        return 0.0


async def _fetch_tianapi_rate(client: httpx.AsyncClient, api_key: str, currency: str) -> float:
    response = await client.get(
        "https://apis.tianapi.com/fxrate/index",
        params={"key": api_key, "fromcoin": currency, "tocoin": "USD", "money": 1},
    )
    response.raise_for_status()
    payload = response.json()
    if int(payload.get("code") or 0) != 200:
        raise RuntimeError(str(payload.get("msg") or payload))
    return _float((payload.get("result") or {}).get("money"))


async def _fetch_jisuapi_rate(client: httpx.AsyncClient, api_key: str, currency: str) -> float:
    response = await client.get(
        "https://api.jisuapi.com/exchange/convert",
        params={"appkey": api_key, "from": currency, "to": "USD", "amount": 1},
    )
    response.raise_for_status()
    payload = response.json()
    if int(payload.get("status") or -1) != 0:
        raise RuntimeError(str(payload.get("msg") or payload))
    return _float((payload.get("result") or {}).get("rate"))


async def _fetch_rate(client: httpx.AsyncClient, provider: str, api_key: str, currency: str) -> float:
    if provider == "tianapi":
        return await _fetch_tianapi_rate(client, api_key, currency)
    if provider == "jisuapi":
        return await _fetch_jisuapi_rate(client, api_key, currency)
    raise RuntimeError(f"暂不支持自动刷新汇率源: {provider}")


async def main() -> None:
    await connect_db()
    try:
        config = await load_billing_config(refresh=True)
        provider = config.get("exchange_rate_provider") or {}
        provider_code = _norm(provider.get("provider"))
        api_key = str(provider.get("api_key") or "").strip()
        if not provider.get("enabled") or provider_code == "manual":
            print({"ok": True, "skipped": "exchange provider disabled"})
            return
        if not api_key:
            raise RuntimeError("汇率源 API Key 未配置")
        updated = []
        async with httpx.AsyncClient(timeout=20.0) as client:
            for currency in config.get("currencies") or []:
                code = str(currency.get("code") or "").strip().upper()
                if code == "USD" or not currency.get("enabled", True) or not currency.get("auto_update", False):
                    continue
                rate = await _fetch_rate(client, provider_code, api_key, code)
                if rate <= 0:
                    raise RuntimeError(f"{code} 汇率返回值无效")
                currency["rate_to_usd"] = rate
                currency["rate_source"] = provider_code
                currency["updated_at"] = datetime.now(timezone.utc).isoformat()
                updated.append({"code": code, "rate_to_usd": rate})
        provider["last_refreshed_at"] = datetime.now(timezone.utc).isoformat()
        config["exchange_rate_provider"] = provider
        await save_billing_config(config)
        print({"ok": True, "updated": updated})
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
