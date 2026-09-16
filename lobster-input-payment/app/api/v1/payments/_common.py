"""支付计费域共享内核(payments 包)。

集中放置:全部第三方/服务层导入、模块常量、回调鉴权 verify_callback_key、
以及所有与具体路由无关的领域工具函数(定价/退款/发放/事件幂等/渠道上下文等)。
各路由子模块统一 `from app.api.v1.payments._common import *` 复用,避免相互 import 形成环。
唯一例外:dispatch_webhook_event 因需回调 subscription/credits 端点,置于 webhook.py。
"""
import calendar
from html import escape
import hmac
import json
import logging
import re
import secrets
import time
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from hashlib import sha256
from typing import Any
from urllib.parse import quote
from uuid import uuid4

import httpx
from fastapi import APIRouter, Header, HTTPException, Request, Security
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.security.api_key import APIKeyHeader
from pydantic import BaseModel, Field
from pymongo.errors import DuplicateKeyError

from app.core.config import settings
from app.core.database import get_main_db
from app.services.billing.enums import (
    CHARGE_TYPE_AUTO_RENEWAL,
    CHARGE_TYPE_MANUAL_PURCHASE,
    CHARGE_TYPE_SCHEDULED_DOWNGRADE,
    CHARGE_TYPES,
    SETTLEMENT_FULL_PRICE,
    SETTLEMENT_MODES,
    SETTLEMENT_PRORATED_DIFFERENCE,
)
from app.services.payment_providers import build_payment_provider_adapter, provider_capability
from app.services.payment_providers.webhook import NormalizedWebhookEvent, WebhookEventKind
from app.services.runtime_config import payment_callback_internal_key
from app.services.billing.config import (
    clean_billing_config,
    default_price,
    load_billing_config,
    materialize_channel_price,
    products_by_code,
    resolve_binding,
    save_billing_config,
)
from app.services.subscription_lifecycle import CREDIT_STATUS_ACTIVE, CreditGrantLifecycleCoordinator, FREE_PLAN_CODE
from app.services.webhook import ingest as webhook_ingest
from app.api.v1.schemas import (
    BillingConfigRequest,
    CancelRenewalRequest,
    CreateCreditTopupCheckoutRequest,
    CreateSubscriptionCheckoutRequest,
    CreditTopupPaymentRequest,
    ManualRefundRequest,
    SubscriptionPaymentRequest,
    SubscriptionPortalRequest,
    SubscriptionQuoteRequest,
)

logger = logging.getLogger(__name__)

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

# Creem 固定价商品升级补差价折扣券有效期(分钟):对齐结账会话典型 24h 寿命,
# 避免用户在支付页久留后券先过期;防复用依靠 max_redemptions=1 + 限定商品,不靠短过期。
CREEM_UPGRADE_DISCOUNT_TTL_MINUTES = 24 * 60
PLAN_CODE_RE = re.compile(r"^[A-Za-z0-9_-]+$")



SECRET_FIELDS = {"api_key", "webhook_secret"}
SECRET_PLACEHOLDER = "__configured__"
REFUND_REASON_LABELS = {
    "customer_request": "用户主动申请",
    "duplicate_purchase": "重复购买",
    "payment_error": "支付异常",
    "service_issue": "服务不可用或体验问题",
    "fraud_risk": "风控或异常订单",
    "admin_adjustment": "管理员调整",
    "other": "其他",
}


def _masked_billing_config(config: dict[str, Any]) -> dict[str, Any]:
    masked = json.loads(json.dumps(config))
    exchange = masked.get("exchange_rate_provider") or {}
    if exchange.get("api_key"):
        exchange["api_key"] = SECRET_PLACEHOLDER
        exchange["api_key_configured"] = True
    else:
        exchange["api_key_configured"] = False
    for channel in masked.get("channels") or []:
        for account in channel.get("accounts") or []:
            for field in SECRET_FIELDS:
                account[field] = SECRET_PLACEHOLDER if account.get(field) else ""
                account[f"{field}_configured"] = bool(account[field])
    return masked


def _merge_existing_channel_secrets(payload: dict[str, Any], current: dict[str, Any]) -> dict[str, Any]:
    current_exchange = current.get("exchange_rate_provider") if isinstance(current.get("exchange_rate_provider"), dict) else {}
    payload_exchange = payload.get("exchange_rate_provider") if isinstance(payload.get("exchange_rate_provider"), dict) else {}
    if str(payload_exchange.get("api_key") or "").strip() in {"", SECRET_PLACEHOLDER}:
        payload_exchange["api_key"] = current_exchange.get("api_key") or ""
    payload["exchange_rate_provider"] = payload_exchange

    current_accounts = {}
    for channel in current.get("channels") or []:
        if not isinstance(channel, dict):
            continue
        channel_code = str(channel.get("code") or "").strip().lower()
        for account in channel.get("accounts") or []:
            if isinstance(account, dict):
                current_accounts[(channel_code, str(account.get("code") or "").strip().lower())] = account
    for channel in payload.get("channels") or []:
        if not isinstance(channel, dict):
            continue
        channel_code = str(channel.get("code") or "").strip().lower()
        for account in channel.get("accounts") or []:
            if not isinstance(account, dict):
                continue
            existing = current_accounts.get((channel_code, str(account.get("code") or "").strip().lower())) or {}
            for field in SECRET_FIELDS:
                value = str(account.get(field) or "").strip()
                if not value or value == SECRET_PLACEHOLDER:
                    account[field] = existing.get(field) or ""
    return payload


async def verify_callback_key(
    request: Request,
    api_key: str = Security(api_key_header),
    x_callback_timestamp: str = Header(..., alias="X-Callback-Timestamp"),
    x_callback_signature: str = Header(..., alias="X-Callback-Signature"),
) -> None:
    expected = await payment_callback_internal_key()
    if not expected or not hmac.compare_digest(api_key, expected):
        raise HTTPException(status_code=401, detail="Invalid payment callback key")
    try:
        ts = int(x_callback_timestamp)
    except ValueError:
        raise HTTPException(status_code=401, detail="Invalid payment callback timestamp")
    if abs(int(time.time()) - ts) > 300:
        raise HTTPException(status_code=401, detail="Payment callback signature expired")
    body = await request.body()
    payload = b"\n".join([
        request.method.upper().encode("utf-8"),
        request.url.path.encode("utf-8"),
        request.url.query.encode("utf-8"),
        x_callback_timestamp.encode("utf-8"),
        body,
    ])
    expected_signature = hmac.new(expected.encode("utf-8"), payload, sha256).hexdigest()
    if not hmac.compare_digest(x_callback_signature, expected_signature):
        raise HTTPException(status_code=401, detail="Invalid payment callback signature")


def _add_period(start: datetime, period: str, count: int = 1) -> datetime:
    count = max(1, int(count or 1))
    if period == "none":
        # "none" = 有效期内不做周期性积分刷新(一次性额度,对齐 backend add_period)。
        # 返回远期,使 period_end 被套餐有效期(expires_at)截断,积分刷新在有效期内永不触发。
        # 此前缺此分支时 reset_period=none 会 fallthrough 按月,导致限时套餐每月错误刷新积分。
        return _add_months(start, 1200)
    if period == "day":
        return start + timedelta(days=count)
    if period == "week":
        return start + timedelta(weeks=count)
    if period == "year":
        return _add_months(start, count * 12)
    return _add_months(start, count)


def _add_months(start: datetime, months: int) -> datetime:
    month = start.month - 1 + months
    year = start.year + month // 12
    month = month % 12 + 1
    day = min(start.day, calendar.monthrange(year, month)[1])
    return start.replace(year=year, month=month, day=day)


def _normalize_dt(dt):
    if not dt:
        return None
    if isinstance(dt, str):
        # 兼容后端内部接口(grant_paid)经 HTTP JSON 返回的 ISO 字符串
        try:
            dt = datetime.fromisoformat(dt.replace("Z", "+00:00"))
        except ValueError:
            return None
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt


def _normalize_plan_code(code: str) -> str:
    value = str(code or "").strip().lower()
    return value if PLAN_CODE_RE.match(value) else ""


def _normalize_provider(provider: str | None) -> str:
    return (provider or "unknown").strip().lower() or "unknown"


def _normalize_settlement_mode(mode: str | None) -> str:
    normalized = (mode or SETTLEMENT_FULL_PRICE).strip().lower()
    if normalized not in SETTLEMENT_MODES:
        raise HTTPException(status_code=400, detail="不支持的结算方式")
    return normalized


def _normalize_charge_type(charge_type: str | None) -> str:
    value = (charge_type or CHARGE_TYPE_MANUAL_PURCHASE).strip().lower()
    if value not in CHARGE_TYPES:
        raise HTTPException(status_code=400, detail="不支持的扣费类型")
    return value


def _account_profile(account: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": account.get("code"),
        "provider_code": account.get("provider_code"),
        "channel_code": account.get("channel_code"),
        "name": account.get("name"),
        "enabled": account.get("enabled", True),
        "environment": account.get("environment"),
        "merchant_id": account.get("merchant_id"),
        "api_base_url": account.get("api_base_url"),
        "api_key": account.get("api_key"),
        "webhook_secret": account.get("webhook_secret"),
    }


async def _payment_context_for_account(account: dict[str, Any]) -> tuple[dict[str, Any], Any]:
    profile = _account_profile(account)
    return profile, build_payment_provider_adapter(profile)


def _active_provider_account(config: dict[str, Any], provider_code: str) -> dict[str, Any] | None:
    """取指定 provider 当前启用渠道的 active 账号(补齐 provider_code/channel_code)。"""
    provider_code = _normalize_provider(provider_code)
    for channel in config.get("channels") or []:
        if _normalize_provider(channel.get("provider_code")) != provider_code or channel.get("enabled", True) is False:
            continue
        active_code = channel.get("active_account_code")
        for candidate in channel.get("accounts") or []:
            if candidate.get("code") == active_code and candidate.get("enabled", True):
                return {**candidate, "provider_code": provider_code, "channel_code": channel.get("code")}
    return None


def _active_provider_code(profile: dict[str, Any]) -> str:
    return _normalize_provider(profile.get("provider_code"))


def _subscription_product_key(plan_code: str, billing_cycle: str) -> str:
    return f"{plan_code}:{billing_cycle}".lower()


def _checkout_discount_code(binding: dict[str, Any], provider: str, requested: str | None = None) -> str:
    requested_code = (requested or "").strip()
    if requested_code:
        return requested_code
    if not provider_capability(provider, "supports_discount_codes"):
        return ""
    if (binding.get("discount_mode") or "none") != "auto_apply":
        return ""
    return (binding.get("discount_code") or "").strip()


def _is_auto_discount(binding: dict[str, Any], provider: str, requested: str | None, discount_code: str) -> bool:
    return bool(
        discount_code
        and not (requested or "").strip()
        and provider_capability(provider, "supports_discount_codes")
        and (binding.get("discount_mode") or "none") == "auto_apply"
    )


def _is_creem_discount_product_error(exc: HTTPException) -> bool:
    detail = exc.detail if isinstance(exc.detail, dict) else {}
    body = str(detail.get("creem_body") or detail.get("message") or exc.detail or "")
    return exc.status_code == 502 and "Discount cannot be applied to the product" in body


def _provider_return_url(provider: str, request_id: str = "") -> str:
    url = f"{settings.PUBLIC_BASE_URL.rstrip('/')}/api/v1/payments/{provider}/return"
    return f"{url}?request_id={quote(request_id)}" if request_id else url


def _provider_webhook_url(provider: str) -> str:
    return f"{settings.PUBLIC_BASE_URL.rstrip('/')}/api/v1/payments/webhook/{provider}"


def _dt_from_creem(value: Any) -> datetime | None:
    if not value:
        return None
    if isinstance(value, datetime):
        return _normalize_dt(value)
    text = str(value).replace("Z", "+00:00")
    try:
        return _normalize_dt(datetime.fromisoformat(text))
    except ValueError:
        return None


def _active_plan_code(user: dict) -> str:
    return user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier") or FREE_PLAN_CODE


def _clean_plan_config(code: str, cfg: dict | None) -> dict:
    code = _normalize_plan_code(code)
    row = dict(cfg or {})
    row["code"] = code
    paid = bool(row.get("paid", bool(code) and code not in {"trial", "free"}))
    row["paid"] = paid
    enabled = bool(row.get("enabled", True))
    row["enabled"] = enabled
    row["rank"] = int(row.get("rank", 0 if not paid else 10) or 0)
    row["credits"] = max(0, int(row.get("credits", 0) or 0))
    row["reset_period"] = row.get("reset_period") if row.get("reset_period") in {"none", "week", "month", "year"} else "month"
    row["validity_period"] = row.get("validity_period") if row.get("validity_period") in {"day", "week", "month", "year", "forever"} else ("month" if paid else "forever")
    row["validity_count"] = 0 if row["validity_period"] == "forever" else max(1, int(row.get("validity_count") or 1))
    row["plan_family"] = row.get("plan_family") if row.get("plan_family") in {"base", "addon"} else "base"
    row["stackable"] = bool(row.get("stackable", False))
    row["self_checkout_enabled"] = bool(row.get("self_checkout_enabled", paid))
    row["auto_renew_supported"] = bool(row.get("auto_renew_supported", paid))
    row["paid_topup_enabled"] = bool(row.get("paid_topup_enabled", paid))
    lifecycle = (row.get("lifecycle_status") or ("active" if enabled else "archived")).strip().lower()
    row["lifecycle_status"] = lifecycle if lifecycle in {"active", "archived"} else "active"
    row["billing_options"] = row.get("billing_options") or {}
    return row


def _is_paid_plan(plan: dict | None) -> bool:
    return bool((plan or {}).get("paid", False))


def _can_self_checkout(plan: dict | None) -> bool:
    p = _clean_plan_config((plan or {}).get("code", ""), plan or {})
    return (
        p["paid"]
        and p["enabled"]
        and p["lifecycle_status"] == "active"
        and p["plan_family"] == "base"
        and not p["stackable"]
        and p["self_checkout_enabled"]
    )


def _duration_months(period: str | None, count: int | None) -> int:
    count = max(1, int(count or 1))
    return count * 12 if period == "year" else count


def _can_replace_immediately(active_plan_doc: dict, target_plan_doc: dict) -> bool:
    return int((target_plan_doc or {}).get("rank", 0) or 0) >= int((active_plan_doc or {}).get("rank", 0) or 0)


def _active_paid_subscription(user: dict, plan_doc: dict, now: datetime) -> bool:
    expires_at = _normalize_dt(user.get("subscription_expires_at") or user.get("plan_expires_at"))
    return bool(_is_paid_plan(plan_doc) and expires_at and expires_at > now)


def _active_billing_cycle_months(user: dict, active_plan_doc: dict) -> tuple[str, int]:
    active_cycle = str(user.get("subscription_billing_cycle") or "").strip().lower()
    active_option = (active_plan_doc.get("billing_options") or {}).get(active_cycle) if active_cycle else None
    months = _duration_months(
        active_option.get("duration_period") if active_option else None,
        active_option.get("duration_count") if active_option else None,
    )
    return active_cycle, months


BLOCK_REASON_DUPLICATE = "duplicate_purchase"
BLOCK_REASON_LOWER_TIER = "lower_tier"
BLOCK_REASON_CYCLE_DOWNGRADE = "cycle_downgrade"
CHECKOUT_BLOCK_MESSAGES = {
    BLOCK_REASON_DUPLICATE: "当前有效套餐不能重复购买",
    BLOCK_REASON_LOWER_TIER: "当前有效套餐不支持降级购买低等级套餐",
    BLOCK_REASON_CYCLE_DOWNGRADE: "账期不支持缩短：年付等长账期套餐不可改为更短账期，可到期后再调整",
}


def _checkout_block_reason(
    user: dict,
    active_plan_doc: dict,
    target_plan_doc: dict,
    target_months: int,
    now: datetime,
) -> str | None:
    """套餐有效优先级 = (等级 rank, 账期时长)，购买仅允许严格向上变更。

    - 同套餐更长账期(月付→年付)为补差价升级，放行；
    - 同套餐同账期为重复购买、更短账期为降级(年付不可改月付)，拒绝；
    - 更高等级套餐要求账期不缩短(年付用户仅可升级年付及以上账期)，放行；
    - 低于当前等级一律拒绝(不允许先买高等级月付再转买低等级年付)。
    """
    if not _active_paid_subscription(user, active_plan_doc, now):
        return None
    active_rank = int((active_plan_doc or {}).get("rank", 0) or 0)
    target_rank = int((target_plan_doc or {}).get("rank", 0) or 0)
    if target_rank < active_rank:
        return BLOCK_REASON_LOWER_TIER
    _, active_months = _active_billing_cycle_months(user, active_plan_doc)
    if target_rank == active_rank:
        same_plan = (target_plan_doc or {}).get("code") == (active_plan_doc or {}).get("code")
        if same_plan and target_months > active_months:
            return None
        if same_plan and target_months < active_months:
            return BLOCK_REASON_CYCLE_DOWNGRADE
        return BLOCK_REASON_DUPLICATE
    if target_months < active_months:
        return BLOCK_REASON_CYCLE_DOWNGRADE
    return None


def _reject_duplicate_or_downgrade_checkout(
    user: dict,
    active_plan_doc: dict,
    target_plan_doc: dict,
    target_months: int,
    now: datetime,
) -> None:
    reason = _checkout_block_reason(user, active_plan_doc, target_plan_doc, target_months, now)
    if reason:
        raise HTTPException(status_code=400, detail=CHECKOUT_BLOCK_MESSAGES[reason])


def _resolve_change_mode(
    user: dict,
    active_code: str,
    active_plan_doc: dict,
    target_code: str,
    target_plan_doc: dict,
    target_billing_cycle: str,
    target_duration_count: int,
    target_duration_period: str,
) -> str:
    if active_code == target_code:
        active_cycle = user.get("subscription_billing_cycle")
        if active_cycle == target_billing_cycle:
            return "renew"
        active_option = (active_plan_doc.get("billing_options") or {}).get(active_cycle or "")
        active_months = _duration_months(
            active_option.get("duration_period") if active_option else None,
            active_option.get("duration_count") if active_option else None,
        )
        target_months = _duration_months(target_duration_period, target_duration_count)
        if not active_cycle and target_months <= active_months:
            return "renew"
        if target_months > active_months:
            return "cycle_upgrade"
        raise HTTPException(status_code=400, detail="同套餐账期降级必须排队到期后扣费")
    if not _can_replace_immediately(active_plan_doc, target_plan_doc):
        raise HTTPException(status_code=400, detail="支付回调不支持立即降级")
    return "activate_now"


def _dump_model(data: BaseModel) -> dict:
    if hasattr(data, "model_dump"):
        return data.model_dump()
    return data.dict()


async def _event_exists(db, event_id: str) -> bool:
    return await db["payment_callback_events"].find_one({"payment_event_id": event_id}) is not None


async def _backend_internal_call(path: str, payload: dict) -> dict:
    """调业务后端内部端点(HMAC 签名,格式匹配 backend verify_internal_api_key)。

    P3 权益收敛:支付履约的权益写入统一调后端 EntitlementService.grant_paid/grant_paid_topup,
    payment 不再直写主库 users/credit_grants 订阅权益。失败抛异常,由 webhook 入口 mark_failed 可重放,
    后端 grant_paid 幂等键 payment_event_id 保证重放不重复授予。
    """
    key = settings.BACKEND_INTERNAL_KEY
    base_url = settings.BACKEND_INTERNAL_URL
    if not key or not base_url:
        raise HTTPException(status_code=503, detail="后端内部调用未配置(BACKEND_INTERNAL_URL/KEY)")
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False, default=str).encode("utf-8")
    ts = str(int(time.time()))
    # 签名 payload 与 backend verify_internal_api_key 一致:METHOD\npath\nquery(空)\nts\nbody
    sig_payload = b"\n".join([b"POST", path.encode("utf-8"), b"", ts.encode("utf-8"), body])
    signature = hmac.new(key.encode("utf-8"), sig_payload, sha256).hexdigest()
    headers = {
        "X-API-Key": key,
        "X-Internal-Timestamp": ts,
        "X-Internal-Signature": signature,
        "Content-Type": "application/json",
    }
    async with httpx.AsyncClient(timeout=20.0) as client:
        resp = await client.post(base_url.rstrip("/") + path, content=body, headers=headers)
    if resp.status_code >= 400:
        raise HTTPException(status_code=502, detail={
            "message": "后端权益授予失败", "backend_status": resp.status_code, "backend_body": resp.text[:500],
        })
    return resp.json()


async def _grant_paid_backend(payload: dict) -> dict:
    return await _backend_internal_call("/api/v1/config/plan-admin/grant-paid", payload)


async def _grant_paid_topup_backend(payload: dict) -> dict:
    return await _backend_internal_call("/api/v1/config/plan-admin/grant-paid-topup", payload)


async def _record_event(db, event_id: str, event_type: str, payload: dict) -> bool:
    try:
        await db["payment_callback_events"].insert_one({
            "payment_event_id": event_id,
            "event_type": event_type,
            "status": "processing",
            **payload,
            "created_at": datetime.now(timezone.utc),
            "updated_at": datetime.now(timezone.utc),
        })
        return True
    except DuplicateKeyError:
        return False


async def _mark_event_applied(db, event_id: str, result: dict) -> None:
    await db["payment_callback_events"].update_one(
        {"payment_event_id": event_id},
        {"$set": {"status": "applied", "result": result, "updated_at": datetime.now(timezone.utc)}},
    )


async def _latest_subscription_payment_event(db, user: dict, active_code: str, active_plan_doc: dict) -> dict | None:
    if not _is_paid_plan(active_plan_doc):
        return None
    payment_event_id = user.get("latest_payment_event_id")
    if payment_event_id:
        event = await db["payment_callback_events"].find_one({
            "payment_event_id": payment_event_id,
            "event_type": "subscription",
            "status": "applied",
        })
        if event:
            return event
    cursor = db["payment_callback_events"].find({
        "user_email": user.get("email"),
        "plan_code": active_code,
        "event_type": "subscription",
        "status": "applied",
    }).sort("updated_at", -1).limit(1)
    rows = await cursor.to_list(length=1)
    return rows[0] if rows else None


def _unused_refund_amount(event: dict, now: datetime) -> int:
    result = event.get("result") or {}
    price_cents = int(event.get("price_cents") or result.get("price_cents") or 0)
    refunded_cents = int(event.get("refunded_cents") or 0)
    refundable_cents = max(0, price_cents - refunded_cents)
    if refundable_cents <= 0:
        return 0
    started_at = (
        result.get("entitlement_started_at")
        or result.get("subscription_started_at")
        or event.get("created_at")
    )
    expires_at = result.get("entitlement_expires_at") or result.get("subscription_expires_at")
    started_at = _normalize_dt(started_at)
    expires_at = _normalize_dt(expires_at)
    if not started_at or not expires_at:
        return 0
    total_seconds = max(1, int((expires_at - started_at).total_seconds()))
    remaining_seconds = max(0, int((expires_at - now).total_seconds()))
    if remaining_seconds <= 0:
        return 0
    prorated = int(price_cents * remaining_seconds / total_seconds)
    return min(refundable_cents, max(0, prorated))


async def _auto_refund_previous_subscription(
    db,
    *,
    payment_event_id: str,
    user_email: str,
    settlement_mode: str,
    change_mode: str,
    previous_event: dict | None,
    now: datetime,
) -> dict:
    if settlement_mode != SETTLEMENT_FULL_PRICE:
        return {"status": "not_required", "reason": "prorated_difference"}
    if change_mode not in {"activate_now", "cycle_upgrade"}:
        return {"status": "not_required", "reason": change_mode}
    if not previous_event:
        return {"status": "not_required", "reason": "missing_previous_payment"}
    amount = _unused_refund_amount(previous_event, now)
    if amount <= 0:
        return {"status": "not_required", "reason": "no_refundable_balance"}
    price_cents = int(previous_event.get("price_cents") or (previous_event.get("result") or {}).get("price_cents") or 0)
    refunded_cents = int(previous_event.get("refunded_cents") or 0)
    refundable_cents = max(0, price_cents - refunded_cents)
    original_id = previous_event["payment_event_id"]
    refund_event_id = f"auto_refund:{payment_event_id}:{original_id}"
    existing = await db["subscription_refund_events"].find_one({"refund_event_id": refund_event_id})
    if existing:
        return {
            "status": "duplicate",
            "refund_event_id": refund_event_id,
            "original_payment_event_id": original_id,
            "provider": existing.get("provider"),
            "amount_cents": existing.get("amount_cents"),
        }
    provider = _normalize_provider(previous_event.get("provider"))
    # 到这里说明是「全价升级」的兜底路径:正常升级已改为结账补差价(ZPay 直接付差价、
    # Creem 动态折扣券),不会走到这里。只有 Creem 建券失败回退全价时才命中。
    # Creem 无程序化退款 API,不能伪造「已退款」,登记为待人工在 Dashboard 补退 + 告警,
    # 且绝不 $inc refunded_cents(钱尚未真正退回)。
    refund_doc = {
        "refund_event_id": refund_event_id,
        "refund_order_id": refund_event_id,
        "provider_refund_id": "",
        "original_payment_event_id": original_id,
        "original_payment_order_id": previous_event.get("payment_order_id") or original_id,
        "original_provider_payment_id": previous_event.get("provider_payment_id") or "",
        "provider": provider,
        "user_email": user_email,
        "plan_code": previous_event.get("plan_code"),
        "amount_cents": amount,
        "status": "pending_manual_refund",
        "revoke_entitlement": False,
        "raw_event": {
            "reason": "subscription_upgrade_full_price_fallback",
            "new_payment_event_id": payment_event_id,
            "note": "补差价折扣未生效,需人工在渠道后台按此金额退回原渠道",
        },
        "created_at": now,
        "updated_at": now,
    }
    await db["subscription_refund_events"].insert_one(dict(refund_doc))
    # 同时登记到 payment_refunds(管理端退款列表 admin_refunds 仅查该集合),使这笔"已收全价、
    # 待人工补退"的欠款在后台可见,避免只存在于日志和无 UI 的 subscription_refund_events 而漏退。
    # upsert 幂等,字段对齐 payment_refunds schema。
    await db["payment_refunds"].update_one(
        {"refund_id": refund_event_id},
        {"$setOnInsert": {
            "refund_id": refund_event_id,
            "order_id": previous_event.get("payment_order_id") or original_id,
            "user_email": user_email,
            "provider": provider,
            "payment_channel": "",
            "payment_event_id": original_id,
            "payment_order_id": previous_event.get("payment_order_id") or original_id,
            "provider_payment_id": previous_event.get("provider_payment_id") or "",
            "refund_mode": "manual",
            "amount_cents": amount,
            "refundable_cents_before": amount,
            "currency": "",
            "status": "pending_manual_refund",
            "reason_code": "upgrade_full_price_fallback",
            "reason_note": "补差价折扣未生效，需人工在渠道后台按此金额退回原渠道",
            "revoke_entitlement": False,
            "plan_code": previous_event.get("plan_code"),
            "calculation": {},
            "created_at": now,
            "updated_at": now,
        }},
        upsert=True,
    )
    await db["payment_callback_events"].update_one(
        {"payment_event_id": original_id},
        {
            "$inc": {"pending_manual_refund_cents": amount},
            "$set": {
                "refund_status": "pending_manual_refund",
                "updated_at": now,
            },
        },
    )
    logger.warning(
        "[upgrade][需人工补退] user=%s provider=%s 原单=%s 应退未用金额=%d分,请在渠道后台手动退回原渠道",
        user_email, provider, original_id, amount,
    )
    refund_doc.pop("_id", None)
    return {
        "status": "pending_manual_refund",
        "refund_event_id": refund_event_id,
        "original_payment_event_id": original_id,
        "provider": provider,
        "amount_cents": amount,
    }


async def _active_plan_price_cents(
    config: dict,
    user: dict,
    active_code: str,
    active_plan_doc: dict,
    method: dict,
    currency: str,
    refunded_cents: int = 0,
) -> int | None:
    """当前套餐在其当前账期、同支付方式/币种下的目录价(分),作为补差价折算基准。"""
    active_cycle, _ = _active_billing_cycle_months(user, active_plan_doc)
    if not active_cycle:
        return None
    try:
        _, active_binding, _ = resolve_binding(config, f"{active_code}_{active_cycle}".lower(), method.get("code") or "", currency)
    except ValueError:
        return None
    if str(active_binding.get("currency") or "").upper() != currency:
        return None
    return max(0, int(active_binding.get("amount_cents") or 0) - int(refunded_cents or 0))


async def _upgrade_credit_cents(
    db,
    config: dict,
    *,
    user: dict,
    active_code: str,
    active_plan_doc: dict,
    previous_event: dict | None,
    method: dict,
    currency: str,
    now: datetime,
) -> int | None:
    """升级补差价时当前套餐未用价值的抵扣金额；无法可靠计算时返回 None(回退全价)。

    折算策略(从精确到稳健):
      1) 有历史支付事件：按其权益窗口 + 实付金额(无则当前套餐目录价)按剩余时间比例折算；
      2) 无历史事件(自动续费 / 后台分配 / 事件缺失):按「当前订阅周期剩余时间 × 当前套餐
         目录价」折算 —— 补差价不依赖能否翻出历史支付事件,避免续费用户被误收全价。
    """
    # 1) 历史支付事件精确折算 —— 仅当该事件的权益窗口确实覆盖当前时刻才采用。
    #    自动续费用户会翻到一笔陈旧的原始购买事件(窗口已过期),此时不能返回 0,
    #    而应落到下面「按当前订阅周期折算」的兜底,否则会被误收全价。
    if previous_event:
        result = previous_event.get("result") or {}
        started_at = _normalize_dt(
            result.get("entitlement_started_at")
            or result.get("subscription_started_at")
            or previous_event.get("created_at")
        )
        expires_at = _normalize_dt(result.get("entitlement_expires_at") or result.get("subscription_expires_at"))
        if started_at and expires_at and started_at <= now < expires_at:
            refunded_cents = int(previous_event.get("refunded_cents") or 0)
            basis = None
            order = await db["payment_orders"].find_one({"order_id": previous_event.get("payment_order_id") or ""})
            if order and str(order.get("currency") or "").upper() == currency:
                basis = max(0, _int_cents(order.get("paid_amount_cents") or order.get("amount_cents")) - refunded_cents)
            if basis is None:
                basis = await _active_plan_price_cents(config, user, active_code, active_plan_doc, method, currency, refunded_cents)
            if basis is not None:
                total_seconds = max(1, int((expires_at - started_at).total_seconds()))
                remaining_seconds = max(0, int((expires_at - now).total_seconds()))
                return min(basis, max(0, int(basis * remaining_seconds / total_seconds)))

    # 2) 兜底:当前订阅周期剩余时间 × 当前套餐目录价(无历史支付事件时)
    expires_at = _normalize_dt(user.get("subscription_expires_at") or user.get("plan_expires_at"))
    if not expires_at or expires_at <= now:
        return None
    _, months = _active_billing_cycle_months(user, active_plan_doc)
    if not months:
        return None
    period_start = _add_months(expires_at, -int(months))
    basis = await _active_plan_price_cents(config, user, active_code, active_plan_doc, method, currency)
    if basis is None:
        return None
    total_seconds = max(1, int((expires_at - period_start).total_seconds()))
    remaining_seconds = min(max(0, int((expires_at - now).total_seconds())), total_seconds)
    return min(basis, max(0, int(basis * remaining_seconds / total_seconds)))


async def _resolve_checkout_pricing(
    db,
    config: dict,
    *,
    user: dict,
    active_code: str,
    active_plan_doc: dict,
    target_code: str,
    target_plan_doc: dict,
    billing_cycle: str,
    duration_count: int,
    duration_period: str,
    method: dict,
    binding: dict,
    now: datetime,
) -> dict:
    """服务端权威定价：升级购买按补差价结算，其余按全价结算。

    补差价的实现按渠道下单能力区分(credit_realization)：
      - amount_order(如 ZPay)：直接把应付金额设为差价下单，realization=amount；
      - external_product(如 Creem 固定价商品)：无法改金额，用一次性折扣券把差价减掉，
        realization=discount，由结账层动态建券实现。
    """
    list_price_cents = int(binding.get("amount_cents") or 0)
    currency = str(binding.get("currency") or "").upper()
    pricing = {
        "change_mode": "new",
        "settlement_mode": SETTLEMENT_FULL_PRICE,
        "list_price_cents": list_price_cents,
        "credit_cents": 0,
        "payable_cents": list_price_cents,
        "currency": currency,
        "credit_realization": "none",
    }
    if not _active_paid_subscription(user, active_plan_doc, now):
        return pricing
    change_mode = _resolve_change_mode(
        user, active_code, active_plan_doc, target_code, target_plan_doc,
        billing_cycle, duration_count, duration_period,
    )
    pricing["change_mode"] = change_mode
    if change_mode not in {"cycle_upgrade", "activate_now"}:
        return pricing
    previous_event = await _latest_subscription_payment_event(db, user, active_code, active_plan_doc)
    credit = await _upgrade_credit_cents(
        db, config,
        user=user, active_code=active_code, active_plan_doc=active_plan_doc,
        previous_event=previous_event, method=method, currency=currency, now=now,
    )
    if credit is None:
        return pricing
    credit = min(credit, max(0, list_price_cents - 1))
    if credit <= 0:
        return pricing
    pricing["settlement_mode"] = SETTLEMENT_PRORATED_DIFFERENCE
    pricing["credit_cents"] = credit
    pricing["payable_cents"] = max(1, list_price_cents - credit)
    pricing["credit_realization"] = "discount" if binding.get("mode") == "external_product" else "amount"
    return pricing


def _available_grant_match(email: str, credit_type: str, now: datetime) -> dict:
    type_filter = {"credit_type": credit_type}
    if credit_type == "bonus":
        type_filter = {"$or": [{"credit_type": "bonus"}, {"credit_type": {"$exists": False}}]}
    return {
        "user_email": email,
        "status": CREDIT_STATUS_ACTIVE,
        "$and": [
            type_filter,
            {"$or": [{"expires_at": None}, {"expires_at": {"$gt": now}}]},
        ],
    }


async def _grant_remaining(db, email: str, credit_type: str, now: datetime) -> int:
    pipeline = [
        {"$match": _available_grant_match(email, credit_type, now)},
        {"$project": {"remaining": {"$subtract": ["$amount_total", "$amount_used"]}}},
        {"$match": {"remaining": {"$gt": 0}}},
        {"$group": {"_id": None, "total": {"$sum": "$remaining"}}},
    ]
    data = await db["credit_grants"].aggregate(pipeline).to_list(length=1)
    return int(data[0]["total"]) if data else 0


async def _total_remaining(db, user: dict, now: datetime) -> int:
    plan_total = int(user.get("plan_credits_total", user.get("credits_total", 0)) or 0)
    plan_used = int(user.get("plan_credits_used", user.get("credits_used", 0)) or 0)
    bonus = await _grant_remaining(db, user["email"], "bonus", now)
    topup = await _grant_remaining(db, user["email"], "paid_topup", now)
    return max(0, plan_total - plan_used) + bonus + topup


def _plan_remaining(user: dict) -> int:
    plan_total = int(user.get("plan_credits_total", user.get("credits_total", 0)) or 0)
    plan_used = int(user.get("plan_credits_used", user.get("credits_used", 0)) or 0)
    return max(0, plan_total - plan_used)


REFUND_MODE_FULL = "full"
REFUND_MODE_PARTIAL = "partial"
REFUND_MODE_PRORATED = "prorated"
REFUND_MODES = {REFUND_MODE_FULL, REFUND_MODE_PARTIAL, REFUND_MODE_PRORATED}
REFUND_SUCCESS_STATUSES = {"processing", "refunded", "partially_refunded"}


def _int_cents(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError):
        return 0


def _ratio(value: int, total: int) -> Decimal:
    if total <= 0:
        return Decimal("1")
    return max(Decimal("0"), min(Decimal("1"), Decimal(value) / Decimal(total)))


def _round_cents(amount: Decimal) -> int:
    return max(0, int(amount.quantize(Decimal("1"), rounding=ROUND_HALF_UP)))


def _refund_reason(data: ManualRefundRequest) -> dict:
    code = re.sub(r"[^a-z0-9_]", "", (data.reason_code or "").strip().lower()) or "admin_adjustment"
    if code not in REFUND_REASON_LABELS:
        code = "other"
    note = (data.reason_note or data.reason or "").strip()
    label = REFUND_REASON_LABELS[code]
    return {
        "reason_code": code,
        "reason_label": label,
        "reason_note": note,
        "reason": f"{label}：{note}" if note else label,
    }


async def _refunded_amount_for_order(db, order_id: str) -> int:
    rows = await db["payment_refunds"].find({"order_id": order_id, "status": {"$in": list(REFUND_SUCCESS_STATUSES)}}).to_list(length=200)
    return sum(_int_cents(row.get("amount_cents")) for row in rows)


async def _original_payment_event_for_order(db, order: dict) -> dict | None:
    event_types = ["subscription", "credits_topup"] if order.get("kind") != "credits_topup" else ["credits_topup"]
    query = {
        "payment_order_id": order.get("order_id"),
        "event_type": {"$in": event_types},
        "status": "applied",
    }
    event = await db["payment_callback_events"].find_one(query, sort=[("updated_at", -1), ("created_at", -1)])
    if event:
        return event
    provider_payment_id = order.get("provider_payment_id") or order.get("checkout_id")
    if provider_payment_id:
        return await db["payment_callback_events"].find_one(
            {"provider_payment_id": provider_payment_id, "event_type": {"$in": event_types}, "status": "applied"},
            sort=[("updated_at", -1), ("created_at", -1)],
        )
    return None


def _event_subscription_dates(event: dict) -> tuple[datetime | None, datetime | None]:
    result = event.get("result") or {}
    started_at = _normalize_dt(result.get("entitlement_started_at") or result.get("subscription_started_at") or event.get("created_at"))
    expires_at = _normalize_dt(result.get("entitlement_expires_at") or result.get("subscription_expires_at"))
    return started_at, expires_at


async def _subscription_credit_remaining_ratio(db, event: dict, user: dict | None) -> Decimal:
    if user and user.get("latest_payment_event_id") == event.get("payment_event_id"):
        total = _int_cents(user.get("plan_credits_total") or user.get("credits_total"))
        used = _int_cents(user.get("plan_credits_used") or user.get("credits_used"))
        return _ratio(max(0, total - used), total)
    grants = await db["credit_grants"].find({"metadata.payment_event_id": event.get("payment_event_id")}).to_list(length=20)
    total = sum(_int_cents(row.get("amount_total")) for row in grants)
    used = sum(_int_cents(row.get("amount_used")) for row in grants)
    return _ratio(max(0, total - used), total) if total > 0 else Decimal("1")


async def _topup_credit_remaining_ratio(db, event: dict) -> Decimal:
    grants = await db["credit_grants"].find({"metadata.payment_event_id": event.get("payment_event_id"), "credit_type": "paid_topup"}).to_list(length=20)
    total = sum(_int_cents(row.get("amount_total")) for row in grants)
    used = sum(_int_cents(row.get("amount_used")) for row in grants)
    return _ratio(max(0, total - used), total) if total > 0 else Decimal("0")


async def _prorated_refund_amount(db, order: dict, event: dict | None, refundable: int, now: datetime) -> tuple[int, dict]:
    if not event:
        return 0, {"reason": "missing_payment_event"}
    if event.get("event_type") == "credits_topup":
        credit_ratio = await _topup_credit_remaining_ratio(db, event)
        amount = _round_cents(Decimal(refundable) * credit_ratio)
        return min(refundable, amount), {"credit_remaining_ratio": str(credit_ratio)}
    user = await db["users"].find_one({"email": order.get("user_email")})
    started_at, expires_at = _event_subscription_dates(event)
    if started_at and expires_at and expires_at > started_at:
        total_seconds = max(1, int((expires_at - started_at).total_seconds()))
        remaining_seconds = max(0, int((expires_at - now).total_seconds()))
        time_ratio = _ratio(remaining_seconds, total_seconds)
    else:
        time_ratio = Decimal("0")
    credit_ratio = await _subscription_credit_remaining_ratio(db, event, user)
    refund_ratio = min(time_ratio, credit_ratio)
    amount = _round_cents(Decimal(refundable) * refund_ratio)
    return min(refundable, amount), {
        "time_remaining_ratio": str(time_ratio),
        "credit_remaining_ratio": str(credit_ratio),
        "refund_ratio": str(refund_ratio),
    }


async def _resolve_refund_amount(db, order: dict, data: ManualRefundRequest, event: dict | None, now: datetime) -> tuple[int, int, dict]:
    paid_amount = _int_cents(order.get("paid_amount_cents") or order.get("amount_cents"))
    already_refunded = await _refunded_amount_for_order(db, order["order_id"])
    refundable = max(0, paid_amount - already_refunded)
    mode = (data.refund_mode or REFUND_MODE_FULL).strip().lower()
    if mode not in REFUND_MODES:
        raise HTTPException(status_code=400, detail="不支持的退款模式")
    if refundable <= 0:
        raise HTTPException(status_code=400, detail="订单已无可退金额")
    calc_detail = {"mode": mode, "paid_amount_cents": paid_amount, "already_refunded_cents": already_refunded}
    if mode == REFUND_MODE_FULL:
        return refundable, refundable, calc_detail
    if mode == REFUND_MODE_PARTIAL:
        amount = _int_cents(data.amount_cents)
        if amount <= 0:
            raise HTTPException(status_code=400, detail="部分退款必须填写退款金额")
        if amount > refundable:
            raise HTTPException(status_code=400, detail="退款金额超过可退余额")
        return amount, refundable, calc_detail
    amount, detail = await _prorated_refund_amount(db, order, event, refundable, now)
    if amount <= 0:
        raise HTTPException(status_code=400, detail="按比例计算后无可退金额")
    return amount, refundable, {**calc_detail, **detail}


def _channel_account_for_order(config: dict, order: dict) -> dict:
    provider = _normalize_provider(order.get("provider"))
    account_code = str(order.get("payment_channel") or "").strip().lower()
    for channel in config.get("channels") or []:
        if _normalize_provider(channel.get("provider_code")) != provider:
            continue
        for account in channel.get("accounts") or []:
            if str(account.get("code") or "").strip().lower() == account_code:
                return {**account, "provider_code": channel.get("provider_code"), "channel_code": channel.get("code")}
    raise HTTPException(status_code=400, detail="订单对应支付渠道账号不存在")


async def _downgrade_user_to_free(db, user_email: str, refund_event_id: str, now: datetime) -> dict:
    free_config = _clean_plan_config(FREE_PLAN_CODE, ((await db["system_config"].find_one({"key": "plan_configs"}) or {}).get("value", {}) or {}).get(FREE_PLAN_CODE, {}))
    expires_at = None if free_config.get("validity_period") == "forever" else _add_period(now, free_config.get("validity_period"), int(free_config.get("validity_count") or 1))
    await db["users"].update_one({"email": user_email}, {"$set": {
        "tier": FREE_PLAN_CODE,
        "plan_code": FREE_PLAN_CODE,
        "subscription_plan_code": FREE_PLAN_CODE,
        "subscription_status": "refunded",
        "subscription_auto_renew": False,
        "subscription_expires_at": expires_at,
        "plan_expires_at": expires_at,
        "plan_started_at": now,
        "plan_current_period_start": now,
        "plan_current_period_end": expires_at,
        "plan_credits_total": 0,
        "plan_credits_used": 0,
        "credits_total": 0,
        "credits_used": 0,
        "credits_reset_at": expires_at,
        "latest_payment_event_id": None,
        "latest_payment_provider": None,
        "latest_payment_at": None,
        "latest_payment_order_id": None,
        "latest_provider_payment_id": None,
        "latest_provider_subscription_id": None,
        "latest_payment_customer_id": None,
        "last_refund_event_id": refund_event_id,
        "updated_at": now,
    }})
    lifecycle = await CreditGrantLifecycleCoordinator(db).apply_subscription_activation(user_email, FREE_PLAN_CODE, expires_at, now)
    return {"plan_code": FREE_PLAN_CODE, "expires_at": expires_at, "credit_lifecycle": lifecycle}


async def _apply_refund_business_effects(db, order: dict, event: dict | None, refund_doc: dict, now: datetime) -> dict:
    if not refund_doc.get("revoke_entitlement") or not event:
        return {"status": "not_required"}
    user_email = order.get("user_email") or event.get("user_email")
    if not user_email:
        return {"status": "ignored", "reason": "missing_user_email"}
    if event.get("event_type") == "credits_topup":
        result = await db["credit_grants"].update_many(
            {"user_email": user_email, "credit_type": "paid_topup", "status": CREDIT_STATUS_ACTIVE, "metadata.payment_event_id": event.get("payment_event_id")},
            {"$set": {"status": "expired", "expires_at": now, "expired_reason": "payment_refund", "updated_at": now}},
        )
        return {"status": "applied", "scope": "credits_topup", "expired_grants": result.modified_count}
    user = await db["users"].find_one({"email": user_email})
    if user and user.get("latest_payment_event_id") == event.get("payment_event_id"):
        downgrade = await _downgrade_user_to_free(db, user_email, refund_doc["refund_id"], now)
        return {"status": "applied", "scope": "current_subscription", **downgrade}
    return {"status": "not_required", "reason": "not_current_subscription"}


def _provider_subscription_id(order: dict, event: dict | None, user: dict | None) -> str:
    if user and user.get("latest_payment_event_id") == (event or {}).get("payment_event_id"):
        value = str(user.get("latest_provider_subscription_id") or "").strip()
        if value:
            return value
    raw = (event or {}).get("raw_event") or {}
    obj = raw.get("object") if isinstance(raw, dict) else {}
    if isinstance(obj, dict):
        return str(obj.get("id") or obj.get("subscription_id") or "").strip()
    return ""


async def _client_subscription_module_enabled(db) -> bool:
    doc = await db["system_config"].find_one({"key": "show_subscription_module_enabled"})
    if doc and isinstance(doc.get("value"), bool):
        return doc["value"]
    return True


async def _mark_checkout_completed(db, checkout: dict | None, raw_event: dict, result: dict) -> None:
    if not checkout:
        return
    update = {
            "status": "completed",
            "completed_at": datetime.now(timezone.utc),
            "raw_completed_event": raw_event,
            "result": result,
            "updated_at": datetime.now(timezone.utc),
        }
    await db["payment_checkout_sessions"].update_one(
        {"request_id": checkout["request_id"]},
        {"$set": update},
    )
    await db["payment_attempts"].update_one(
        {"request_id": checkout["request_id"]},
        {"$set": update},
    )
    if checkout.get("order_id"):
        await db["payment_orders"].update_one(
            {"order_id": checkout["order_id"]},
            {"$set": {
                "status": "paid",
                "paid_at": datetime.now(timezone.utc),
                "paid_amount_cents": result.get("paid_amount_cents") or result.get("price_cents") or 0,
                "raw_completed_event": raw_event,
                "entitlement_result": result,
                "updated_at": datetime.now(timezone.utc),
            }},
        )


async def _best_effort_delete_upgrade_discount(profile: dict[str, Any], checkout: dict | None) -> None:
    """升级支付完成后清理动态折扣券。非关键:券已被 max_redemptions=1 + 短过期锁定,失败仅记日志。"""
    disc = (checkout or {}).get("upgrade_discount") or {}
    discount_id = disc.get("discount_id")
    if not discount_id or disc.get("provider") != "creem":
        return
    try:
        adapter = build_payment_provider_adapter(profile)
        await adapter.delete_discount(discount_id)
    except Exception as exc:  # noqa: BLE001 - 清理失败不影响主流程
        logger.info("[upgrade] 折扣券清理失败(不影响,券已单次+过期锁定) id=%s: %s", discount_id, exc)


async def _best_effort_cancel_stale_provider_subscription(db, adapter, user, new_subscription_id) -> None:
    """新订阅履约覆盖 latest_provider_subscription_id 之前,周期末取消旧的 Creem 代扣订阅。

    结构性缺口修复:升级/换渠道购买时旧 Creem 订阅仍在渠道侧继续代扣,会造成双重扣费。
    - 同一订阅的自动续费扣款(new_subscription_id == 旧值)不是换订阅,不得误取消;
    - user 必须是履约写库前的用户快照(此时 latest_* 字段还是旧订阅的);
    - best-effort:渠道异常仅告警不阻断履约,留待人工在渠道后台处理;
    - adapter 传 None 时(如 ZPay 履约路径无 creem adapter)从计费配置构建。
    """
    old_subscription_id = str((user or {}).get("latest_provider_subscription_id") or "").strip()
    old_provider = _normalize_provider((user or {}).get("latest_payment_provider"))
    new_id = str(new_subscription_id or "").strip()
    if not old_subscription_id or old_subscription_id == new_id or not provider_capability(old_provider, "supports_recurring"):
        return
    email = (user or {}).get("email") or ""
    try:
        if adapter is None:
            config = await load_billing_config()
            account = _active_provider_account(config, old_provider)
            if not account:
                logger.warning(
                    "[subscription][需人工处理] %s 渠道未配置,旧订阅无法取消 email=%s subscription_id=%s",
                    old_provider, email, old_subscription_id,
                )
                return
            _profile, adapter = await _payment_context_for_account(account)
        await adapter.cancel_subscription(old_subscription_id, mode="scheduled")
        await db["subscription_events"].insert_one({
            "event_type": "stale_subscription_cancelled",
            "email": email,
            "provider": "creem",
            "subscription_id": old_subscription_id,
            "new_subscription_id": new_id,
            "channel_sync": "ok",
            "created_at": datetime.now(timezone.utc),
        })
    except Exception as exc:  # noqa: BLE001 - 取消旧订阅失败不阻断新订阅履约
        detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
        logger.warning(
            "[subscription][需人工处理] 旧 Creem 订阅取消失败,可能双重扣费 email=%s subscription_id=%s: %s",
            email, old_subscription_id, detail,
        )




# 导出全部非 dunder 模块级名字(含下划线工具),供各路由子模块星号导入复用。
__all__ = [__n for __n in list(globals()) if not __n.startswith("__")]
