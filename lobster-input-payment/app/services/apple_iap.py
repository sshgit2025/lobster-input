"""Apple IAP(App 内购买)配置与 JWS 验签服务。

职责:
- 管理 apple_iap_config(system_config 独立文档,与 payment_billing_config 完全隔离);
- 基于 Apple 官方 app-store-server-library 对 signedTransaction / signedPayload
  做完整证书链验签(信任锚为仓库内固化的 Apple 根证书);
- 提供 Apple productId -> 套餐/积分商品 的映射查询。

该模块不写用户权益,权益发放统一走 app.api.v1.payments 的既有幂等回调逻辑。
"""
import logging
from pathlib import Path
from datetime import datetime, timezone
from typing import Any

from cachetools import TTLCache
from fastapi import HTTPException

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.JWSTransactionDecodedPayload import JWSTransactionDecodedPayload
from appstoreserverlibrary.models.ResponseBodyV2DecodedPayload import ResponseBodyV2DecodedPayload
from appstoreserverlibrary.signed_data_verifier import (
    SignedDataVerifier,
    VerificationException,
    VerificationStatus,
)

from app.core.database import get_main_db

logger = logging.getLogger(__name__)

APPLE_IAP_CONFIG_KEY = "apple_iap_config"
APPLE_PROVIDER_CODE = "apple"
APPLE_PAYMENT_CHANNEL = "apple_iap"
APPLE_SECRET_FIELDS = {"api_private_key"}
APPLE_SECRET_PLACEHOLDER = "__configured__"
APPLE_PRODUCT_TYPES = {"subscription", "credits_topup"}

CONFIG_CACHE_TTL_SECONDS = 60
_CONFIG_CACHE: TTLCache[str, dict[str, Any]] = TTLCache(maxsize=1, ttl=CONFIG_CACHE_TTL_SECONDS)
_VERIFIER_CACHE: TTLCache[tuple, SignedDataVerifier] = TTLCache(maxsize=8, ttl=300)

_CERTS_DIR = Path(__file__).resolve().parent.parent / "resources" / "apple_root_certs"
_ROOT_CERTIFICATES: list[bytes] = []


def _load_root_certificates() -> list[bytes]:
    global _ROOT_CERTIFICATES
    if not _ROOT_CERTIFICATES:
        certs = [path.read_bytes() for path in sorted(_CERTS_DIR.glob("*.cer"))]
        if not certs:
            raise RuntimeError(f"Apple 根证书缺失: {_CERTS_DIR}")
        _ROOT_CERTIFICATES = certs
    return _ROOT_CERTIFICATES


def _str(value: Any) -> str:
    return str(value or "").strip()


def _norm(value: Any) -> str:
    return _str(value).lower()


def _bool(value: Any, default: bool) -> bool:
    if value is None:
        return default
    return bool(value)


def _non_negative_int(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except Exception:
        return 0


def default_apple_iap_config() -> dict[str, Any]:
    return clean_apple_iap_config({})


def clean_apple_iap_config(value: Any) -> dict[str, Any]:
    data = value if isinstance(value, dict) else {}
    products: list[dict[str, Any]] = []
    seen_products: set[str] = set()
    for raw in data.get("products") if isinstance(data.get("products"), list) else []:
        if not isinstance(raw, dict):
            continue
        apple_product_id = _str(raw.get("apple_product_id"))
        product_type = _norm(raw.get("type"))
        if not apple_product_id or apple_product_id in seen_products or product_type not in APPLE_PRODUCT_TYPES:
            continue
        row: dict[str, Any] = {
            "apple_product_id": apple_product_id,
            "type": product_type,
            "name": _str(raw.get("name")) or apple_product_id,
            "enabled": _bool(raw.get("enabled"), True),
            "sort_order": _non_negative_int(raw.get("sort_order")),
        }
        if product_type == "subscription":
            row["plan_code"] = _norm(raw.get("plan_code"))
            row["billing_cycle"] = _norm(raw.get("billing_cycle")) or "monthly"
            if not row["plan_code"]:
                continue
        else:
            row["topup_credits"] = _non_negative_int(raw.get("topup_credits"))
            if row["topup_credits"] <= 0:
                continue
        products.append(row)
        seen_products.add(apple_product_id)

    app_apple_id = None
    try:
        raw_app_apple_id = data.get("app_apple_id")
        if raw_app_apple_id not in (None, "", 0, "0"):
            app_apple_id = int(raw_app_apple_id)
    except (TypeError, ValueError):
        app_apple_id = None

    return {
        "enabled": _bool(data.get("enabled"), False),
        "bundle_id": _str(data.get("bundle_id")),
        "app_apple_id": app_apple_id,
        "allow_sandbox": _bool(data.get("allow_sandbox"), True),
        "enable_online_checks": _bool(data.get("enable_online_checks"), False),
        # App Store Server API 凭证(预留:交易查询/退款历史等主动查询能力)
        "api_issuer_id": _str(data.get("api_issuer_id")),
        "api_key_id": _str(data.get("api_key_id")),
        "api_private_key": _str(data.get("api_private_key")),
        "products": products,
    }


def masked_apple_iap_config(config: dict[str, Any]) -> dict[str, Any]:
    masked = clean_apple_iap_config(config)
    for field in APPLE_SECRET_FIELDS:
        masked[f"{field}_configured"] = bool(masked.get(field))
        masked[field] = APPLE_SECRET_PLACEHOLDER if masked.get(field) else ""
    return masked


def merge_existing_apple_secrets(payload: dict[str, Any], current: dict[str, Any]) -> dict[str, Any]:
    merged = dict(payload if isinstance(payload, dict) else {})
    for field in APPLE_SECRET_FIELDS:
        value = _str(merged.get(field))
        if not value or value == APPLE_SECRET_PLACEHOLDER:
            merged[field] = _str(current.get(field))
    return merged


async def load_apple_iap_config(*, refresh: bool = False) -> dict[str, Any]:
    cache_key = "apple_iap_config"
    if not refresh:
        cached = _CONFIG_CACHE.get(cache_key)
        if cached is not None:
            return dict(cached)
    doc = await get_main_db()["system_config"].find_one({"key": APPLE_IAP_CONFIG_KEY})
    config = clean_apple_iap_config((doc or {}).get("value")) if doc else default_apple_iap_config()
    _CONFIG_CACHE[cache_key] = config
    return dict(config)


async def save_apple_iap_config(value: dict[str, Any]) -> dict[str, Any]:
    config = clean_apple_iap_config(value)
    await get_main_db()["system_config"].update_one(
        {"key": APPLE_IAP_CONFIG_KEY},
        {"$set": {"key": APPLE_IAP_CONFIG_KEY, "value": config, "updated_at": datetime.now(timezone.utc)}},
        upsert=True,
    )
    _CONFIG_CACHE["apple_iap_config"] = config
    return config


def apple_products_by_id(config: dict[str, Any], *, enabled_only: bool = True) -> dict[str, dict[str, Any]]:
    return {
        item["apple_product_id"]: item
        for item in config.get("products") or []
        if not enabled_only or item.get("enabled", True)
    }


def _build_verifier(config: dict[str, Any], environment: Environment) -> SignedDataVerifier:
    bundle_id = _str(config.get("bundle_id"))
    app_apple_id = config.get("app_apple_id")
    cache_key = (environment.value, bundle_id, app_apple_id, bool(config.get("enable_online_checks")))
    verifier = _VERIFIER_CACHE.get(cache_key)
    if verifier is None:
        verifier = SignedDataVerifier(
            _load_root_certificates(),
            bool(config.get("enable_online_checks")),
            environment,
            bundle_id,
            app_apple_id,
        )
        _VERIFIER_CACHE[cache_key] = verifier
    return verifier


def _candidate_environments(config: dict[str, Any]) -> list[Environment]:
    environments: list[Environment] = []
    # 生产验签需要 app_apple_id(App Store Connect 的 App 数字 ID)
    if config.get("app_apple_id"):
        environments.append(Environment.PRODUCTION)
    if config.get("allow_sandbox", True):
        environments.append(Environment.SANDBOX)
    if not environments:
        raise HTTPException(status_code=503, detail="Apple IAP 验签环境未配置(缺少 app_apple_id 且沙盒已禁用)")
    return environments


def _require_ready(config: dict[str, Any]) -> None:
    if not config.get("enabled"):
        raise HTTPException(status_code=403, detail="Apple IAP 未启用")
    if not _str(config.get("bundle_id")):
        raise HTTPException(status_code=503, detail="Apple IAP 未配置 bundle_id")


def verify_signed_transaction(config: dict[str, Any], signed_transaction: str) -> JWSTransactionDecodedPayload:
    """按 生产 -> 沙盒 顺序验签 signedTransaction,返回解码后的交易载荷。"""
    _require_ready(config)
    last_error: VerificationException | None = None
    for environment in _candidate_environments(config):
        try:
            return _build_verifier(config, environment).verify_and_decode_signed_transaction(signed_transaction)
        except VerificationException as exc:
            last_error = exc
            if exc.status != VerificationStatus.INVALID_ENVIRONMENT:
                break
    status = last_error.status.name if last_error else "UNKNOWN"
    logger.warning("Apple signedTransaction 验签失败: %s", status)
    raise HTTPException(status_code=400, detail={"code": "APPLE_VERIFICATION_FAILED", "status": status})


def verify_notification(config: dict[str, Any], signed_payload: str) -> ResponseBodyV2DecodedPayload:
    """按 生产 -> 沙盒 顺序验签 App Store Server Notifications V2 signedPayload。"""
    _require_ready(config)
    last_error: VerificationException | None = None
    for environment in _candidate_environments(config):
        try:
            return _build_verifier(config, environment).verify_and_decode_notification(signed_payload)
        except VerificationException as exc:
            last_error = exc
            if exc.status != VerificationStatus.INVALID_ENVIRONMENT:
                break
    status = last_error.status.name if last_error else "UNKNOWN"
    logger.warning("Apple 服务器通知验签失败: %s", status)
    raise HTTPException(status_code=401, detail={"code": "APPLE_NOTIFICATION_VERIFICATION_FAILED", "status": status})


def decode_transaction_from_notification(config: dict[str, Any], signed_transaction_info: str) -> JWSTransactionDecodedPayload:
    """通知体内嵌的 signedTransactionInfo 与顶层 signedPayload 同链路签名,复用同一验签逻辑。"""
    return verify_signed_transaction(config, signed_transaction_info)


def ms_to_datetime(value: Any) -> datetime | None:
    try:
        ms = int(value)
    except (TypeError, ValueError):
        return None
    if ms <= 0:
        return None
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc)


def transaction_paid_cents(txn: JWSTransactionDecodedPayload) -> int:
    """JWS 交易载荷中的 price 单位为币种的千分位(milliunits),换算为分。"""
    try:
        price = int(txn.price) if txn.price is not None else 0
    except (TypeError, ValueError):
        price = 0
    return max(0, price // 10)
