from typing import Any

from app.core.database import get_main_db


PAYMENT_RUNTIME_CONFIG_KEY = "payment_runtime_config"


async def load_payment_runtime_config() -> dict[str, Any]:
    doc = await get_main_db()["system_config"].find_one({"key": PAYMENT_RUNTIME_CONFIG_KEY})
    value = doc.get("value") if doc and isinstance(doc.get("value"), dict) else {}
    return {
        "callback_internal_key": str(value.get("callback_internal_key") or "").strip(),
        "service_url": str(value.get("service_url") or "").strip().rstrip("/"),
        "checkout_public_base_url": str(value.get("checkout_public_base_url") or "").strip().rstrip("/"),
    }


async def payment_callback_internal_key() -> str:
    config = await load_payment_runtime_config()
    return config["callback_internal_key"]
