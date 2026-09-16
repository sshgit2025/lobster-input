"""Apple IAP(App 内购买)接口。

与 Creem/ZPay 的 web checkout 闭环完全隔离的独立链路:
- POST /payments/apple/verify-transaction  内部签名接口,iOS 经 backend 转发提交 signedTransaction;
- POST /payments/apple/notifications       App Store Server Notifications V2 专用回调(JWS 验签即鉴权);
- GET  /payments/apple/products            内部签名接口,商品映射下发;
- GET/POST /payments/apple/admin/config    管理端配置读写。

权益发放复用 payments.subscription_callback / credits_topup_callback 的幂等逻辑,
幂等事件 ID 统一为 apple:{transactionId},与客户端提交、苹果服务器通知天然去重。
"""
import logging
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, HTTPException, Security
from pydantic import BaseModel, Field

from appstoreserverlibrary.models.JWSTransactionDecodedPayload import JWSTransactionDecodedPayload

from app.core.database import get_main_db
from app.services.apple_iap import (
    APPLE_PAYMENT_CHANNEL,
    APPLE_PROVIDER_CODE,
    apple_products_by_id,
    clean_apple_iap_config,
    load_apple_iap_config,
    masked_apple_iap_config,
    merge_existing_apple_secrets,
    ms_to_datetime,
    save_apple_iap_config,
    transaction_paid_cents,
    verify_notification,
    verify_signed_transaction,
)
from app.services.subscription_lifecycle import CREDIT_STATUS_ACTIVE
from app.services.webhook import ingest as webhook_ingest
from app.api.v1.schemas import CreditTopupPaymentRequest, SubscriptionPaymentRequest
from app.api.v1.payments import (
    CHARGE_TYPE_AUTO_RENEWAL,
    CHARGE_TYPE_MANUAL_PURCHASE,
    SETTLEMENT_FULL_PRICE,
    _downgrade_user_to_free,
    _event_exists,
    _mark_event_applied,
    _record_event,
    credits_topup_callback,
    subscription_callback,
    verify_callback_key,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/payments/apple", tags=["payments-apple"])

TXN_REASON_RENEWAL = "RENEWAL"
SUBSCRIPTIONS_COLLECTION = "apple_iap_subscriptions"

GRANT_NOTIFICATION_TYPES = {"SUBSCRIBED", "DID_RENEW", "OFFER_REDEEMED", "ONE_TIME_CHARGE"}
STATUS_NOTIFICATION_TYPES = {"DID_CHANGE_RENEWAL_STATUS", "EXPIRED", "GRACE_PERIOD_EXPIRED", "DID_FAIL_TO_RENEW"}
REFUND_NOTIFICATION_TYPES = {"REFUND", "REVOKE"}


class AppleVerifyTransactionRequest(BaseModel):
    user_email: str
    signed_transaction: str
    source: str = "purchase"  # purchase / restore / listener


class AppleNotificationRequest(BaseModel):
    signedPayload: str


class AppleIapConfigRequest(BaseModel):
    enabled: bool = False
    bundle_id: str = ""
    app_apple_id: int | None = None
    allow_sandbox: bool = True
    enable_online_checks: bool = False
    api_issuer_id: str = ""
    api_key_id: str = ""
    api_private_key: str = ""
    products: list[dict[str, Any]] = Field(default_factory=list)


def _event_id_for(txn: JWSTransactionDecodedPayload) -> str:
    return f"apple:{txn.transactionId}"


def _txn_environment(txn: JWSTransactionDecodedPayload) -> str:
    return str(txn.rawEnvironment or "").strip() or "Production"


def _txn_summary(txn: JWSTransactionDecodedPayload) -> dict[str, Any]:
    return {
        "transaction_id": txn.transactionId,
        "original_transaction_id": txn.originalTransactionId,
        "product_id": txn.productId,
        "purchase_date": ms_to_datetime(txn.purchaseDate),
        "expires_date": ms_to_datetime(txn.expiresDate),
        "revocation_date": ms_to_datetime(txn.revocationDate),
        "quantity": int(txn.quantity or 1),
        "transaction_reason": str(txn.rawTransactionReason or ""),
        "app_account_token": str(txn.appAccountToken or "").lower(),
        "storefront": str(txn.storefront or ""),
        "currency": str(txn.currency or ""),
        "price_milliunits": txn.price,
        "environment": _txn_environment(txn),
        "in_app_ownership_type": str(txn.rawInAppOwnershipType or ""),
    }


async def _resolve_user_email_for_txn(db, txn: JWSTransactionDecodedPayload) -> str:
    """服务器通知场景下把苹果交易映射回用户:优先订阅归属记录,其次 appAccountToken。"""
    record = await db[SUBSCRIPTIONS_COLLECTION].find_one({"original_transaction_id": txn.originalTransactionId})
    if record and record.get("user_email"):
        return record["user_email"]
    token = str(txn.appAccountToken or "").lower()
    if token:
        user = await db["users"].find_one({"apple_app_account_token": token})
        if user:
            return user["email"]
    return ""


async def _bind_transaction_owner(db, txn: JWSTransactionDecodedPayload, user_email: str, mapping: dict[str, Any]) -> None:
    """首个成功认领的用户与 originalTransactionId 绑定,防止他人重放 JWS 抢占权益。"""
    now = datetime.now(timezone.utc)
    existing = await db[SUBSCRIPTIONS_COLLECTION].find_one({"original_transaction_id": txn.originalTransactionId})
    if existing:
        if existing.get("user_email") != user_email:
            raise HTTPException(status_code=409, detail={"code": "APPLE_TRANSACTION_OWNED_BY_OTHER", "message": "该苹果交易已绑定其他账号"})
        await db[SUBSCRIPTIONS_COLLECTION].update_one(
            {"original_transaction_id": txn.originalTransactionId},
            {"$set": {
                "last_transaction_id": txn.transactionId,
                "apple_product_id": txn.productId,
                "expires_at": ms_to_datetime(txn.expiresDate),
                "environment": _txn_environment(txn),
                "updated_at": now,
            }},
        )
        return
    await db[SUBSCRIPTIONS_COLLECTION].update_one(
        {"original_transaction_id": txn.originalTransactionId},
        {"$setOnInsert": {
            "original_transaction_id": txn.originalTransactionId,
            "user_email": user_email,
            "apple_product_id": txn.productId,
            "kind": mapping.get("type"),
            "plan_code": mapping.get("plan_code") or "",
            "billing_cycle": mapping.get("billing_cycle") or "",
            "app_account_token": str(txn.appAccountToken or "").lower(),
            "auto_renew": True,
            "status": "active",
            "last_transaction_id": txn.transactionId,
            "expires_at": ms_to_datetime(txn.expiresDate),
            "environment": _txn_environment(txn),
            "created_at": now,
            "updated_at": now,
        }},
        upsert=True,
    )
    record = await db[SUBSCRIPTIONS_COLLECTION].find_one({"original_transaction_id": txn.originalTransactionId})
    if record and record.get("user_email") != user_email:
        raise HTTPException(status_code=409, detail={"code": "APPLE_TRANSACTION_OWNED_BY_OTHER", "message": "该苹果交易已绑定其他账号"})


async def _upsert_apple_order(db, txn: JWSTransactionDecodedPayload, user_email: str, mapping: dict[str, Any], result: dict[str, Any]) -> str:
    """为管理端订单页落一条 payment_orders 记录(幂等,以交易 ID 为订单号)。"""
    now = datetime.now(timezone.utc)
    order_id = f"apple_{txn.transactionId}"
    kind = mapping.get("type")
    product_code = (
        f"{mapping.get('plan_code')}_{mapping.get('billing_cycle')}"
        if kind == "subscription"
        else "credits_topup"
    )
    await db["payment_orders"].update_one(
        {"order_id": order_id},
        {"$setOnInsert": {
            "order_id": order_id,
            "user_email": user_email,
            "kind": kind,
            "product_code": product_code,
            "product_name": mapping.get("name") or txn.productId,
            "plan_code": mapping.get("plan_code") or "",
            "billing_cycle": mapping.get("billing_cycle") or "",
            "amount_cents": transaction_paid_cents(txn),
            "currency": str(txn.currency or "").upper(),
            "status": "paid",
            "provider": APPLE_PROVIDER_CODE,
            "payment_method": APPLE_PAYMENT_CHANNEL,
            "payment_channel": APPLE_PAYMENT_CHANNEL,
            "settlement_mode": SETTLEMENT_FULL_PRICE,
            "auto_renew": kind == "subscription",
            "apple_transaction_id": txn.transactionId,
            "apple_original_transaction_id": txn.originalTransactionId,
            "apple_product_id": txn.productId,
            "apple_environment": _txn_environment(txn),
            "paid_at": ms_to_datetime(txn.purchaseDate) or now,
            "paid_amount_cents": transaction_paid_cents(txn),
            "entitlement_result": result,
            "created_at": now,
            "updated_at": now,
        }},
        upsert=True,
    )
    return order_id


async def _sync_subscription_expiry_from_apple(db, txn: JWSTransactionDecodedPayload, user_email: str, event_id: str) -> None:
    """苹果侧到期时间是订阅权益的权威值,授予后回写覆盖本地按账期推算的到期时间。"""
    expires_at = ms_to_datetime(txn.expiresDate)
    if not expires_at:
        return
    await db["users"].update_one(
        {"email": user_email, "latest_payment_event_id": event_id},
        {"$set": {
            "subscription_expires_at": expires_at,
            "plan_expires_at": expires_at,
            "updated_at": datetime.now(timezone.utc),
        }},
    )


async def _apply_verified_transaction(
    db,
    txn: JWSTransactionDecodedPayload,
    *,
    user_email: str,
    source: str,
    raw_event: dict[str, Any],
) -> dict[str, Any]:
    """把一笔已验签的苹果交易转化为权益(幂等)。"""
    config = await load_apple_iap_config()
    mapping = apple_products_by_id(config).get(str(txn.productId or ""))
    if not mapping:
        return {"status": "ignored", "reason": "unknown_apple_product", "apple_product_id": txn.productId}
    if txn.revocationDate:
        return {"status": "ignored", "reason": "transaction_revoked", "transaction_id": txn.transactionId}
    if str(txn.rawInAppOwnershipType or "") == "FAMILY_SHARED":
        return {"status": "ignored", "reason": "family_shared_not_supported"}
    event_id = _event_id_for(txn)
    now = datetime.now(timezone.utc)
    if mapping["type"] == "subscription":
        expires_at = ms_to_datetime(txn.expiresDate)
        if expires_at and expires_at <= now:
            return {"status": "ignored", "reason": "transaction_expired", "expires_at": expires_at.isoformat()}
        await _bind_transaction_owner(db, txn, user_email, mapping)
        if await _event_exists(db, event_id):
            return {"status": "duplicate", "payment_event_id": event_id}
        is_renewal = str(txn.rawTransactionReason or "").upper() == TXN_REASON_RENEWAL
        result = await subscription_callback(
            SubscriptionPaymentRequest(
                payment_event_id=event_id,
                user_email=user_email,
                plan_code=mapping["plan_code"],
                billing_cycle=mapping["billing_cycle"],
                provider=APPLE_PROVIDER_CODE,
                settlement_mode=SETTLEMENT_FULL_PRICE,
                paid_amount_cents=transaction_paid_cents(txn),
                payment_order_id=f"apple_{txn.transactionId}",
                provider_payment_id=txn.originalTransactionId,
                payment_channel=APPLE_PAYMENT_CHANNEL,
                auto_renew=True,
                charge_type=CHARGE_TYPE_AUTO_RENEWAL if is_renewal else CHARGE_TYPE_MANUAL_PURCHASE,
                raw_event=raw_event,
            ),
            None,
        )
        if result.get("status") == "applied":
            await _sync_subscription_expiry_from_apple(db, txn, user_email, event_id)
    else:
        quantity = max(1, int(txn.quantity or 1))
        if await _event_exists(db, event_id):
            return {"status": "duplicate", "payment_event_id": event_id}
        result = await credits_topup_callback(
            CreditTopupPaymentRequest(
                payment_event_id=event_id,
                user_email=user_email,
                amount=int(mapping["topup_credits"]) * quantity,
                provider=APPLE_PROVIDER_CODE,
                raw_event=raw_event,
            ),
            None,
        )
    if result.get("status") == "applied":
        order_id = await _upsert_apple_order(db, txn, user_email, mapping, result)
        await db["payment_callback_events"].update_one(
            {"payment_event_id": event_id},
            {"$set": {
                "payment_order_id": order_id,
                "provider_payment_id": txn.originalTransactionId,
                "payment_channel": APPLE_PAYMENT_CHANNEL,
                "apple_transaction": _txn_summary(txn),
                "apple_source": source,
                "updated_at": datetime.now(timezone.utc),
            }},
        )
    return {**result, "payment_event_id": event_id, "apple_product_id": txn.productId, "kind": mapping["type"]}


@router.get("/products")
async def apple_products(_: None = Security(verify_callback_key)):
    config = await load_apple_iap_config()
    return {
        "enabled": bool(config.get("enabled")),
        "bundle_id": config.get("bundle_id") or "",
        "products": [dict(item) for item in config.get("products") or [] if item.get("enabled", True)],
    }


@router.post("/verify-transaction")
async def apple_verify_transaction(data: AppleVerifyTransactionRequest, _: None = Security(verify_callback_key)):
    db = get_main_db()
    user_email = data.user_email.strip().lower()
    if not user_email:
        raise HTTPException(status_code=400, detail="缺少用户邮箱")
    user = await db["users"].find_one({"email": user_email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    config = await load_apple_iap_config()
    txn = verify_signed_transaction(config, data.signed_transaction)
    # appAccountToken 与登录账号双向校验:交易若携带其他账号的 token,拒绝入账
    token = str(txn.appAccountToken or "").lower()
    if token:
        owner = await db["users"].find_one({"apple_app_account_token": token})
        if owner and owner.get("email") != user_email:
            raise HTTPException(status_code=409, detail={"code": "APPLE_TRANSACTION_OWNED_BY_OTHER", "message": "该苹果交易已绑定其他账号"})
    raw_event = {
        "provider": APPLE_PROVIDER_CODE,
        "channel": "client_verify",
        "source": data.source,
        "transaction": {k: (v.isoformat() if isinstance(v, datetime) else v) for k, v in _txn_summary(txn).items()},
    }
    result = await _apply_verified_transaction(db, txn, user_email=user_email, source=data.source, raw_event=raw_event)
    return result


@router.post("/notifications")
async def apple_notifications(data: AppleNotificationRequest):
    """App Store Server Notifications V2 专用回调。

    鉴权即 JWS 验签(证书链锚定苹果根证书),验签失败返回 401。
    处理失败但可重试的场景返回 5xx 触发苹果重试;业务性忽略一律 200,避免无效重试。
    入口处接入 webhook_events 幂等摄取管道(计费域重构阶段 0),事件 ID 为 notificationUUID。
    """
    db = get_main_db()
    config = await load_apple_iap_config()
    try:
        notification = verify_notification(config, data.signedPayload)
    except HTTPException:
        # 验签失败仍按现有行为拒绝,但落一条 signature_ok=false 的事件记录
        try:
            await webhook_ingest.ingest(
                db,
                APPLE_PROVIDER_CODE,
                webhook_ingest.invalid_signature_event_id(webhook_ingest.synthetic_event_id(data.signedPayload.encode("utf-8"))),
                {"signedPayload": data.signedPayload},
                False,
            )
        except Exception:
            logger.exception("记录 Apple 验签失败 webhook 事件时出错")
        raise
    notification_type = str(notification.rawNotificationType or "")
    subtype = str(notification.rawSubtype or "")
    notification_uuid = str(notification.notificationUUID or "")
    if notification_type == "TEST":
        return {"status": "ok", "notification_type": "TEST"}
    if not notification_uuid:
        raise HTTPException(status_code=400, detail="通知缺少 notificationUUID")
    ingest_raw = {
        "signedPayload": data.signedPayload,
        "notification_type": notification_type,
        "subtype": subtype,
        "notification_uuid": notification_uuid,
    }
    if await webhook_ingest.ingest(db, APPLE_PROVIDER_CODE, notification_uuid, ingest_raw, True) == "duplicate":
        # 重复事件跳过 handler,直接返回既有幂等应答
        return {"status": "duplicate"}
    try:
        result = await _process_apple_notification(db, config, notification, notification_type, subtype, notification_uuid)
    except Exception as exc:
        await webhook_ingest.mark_failed(db, APPLE_PROVIDER_CODE, notification_uuid, webhook_ingest.error_text(exc))
        raise
    await webhook_ingest.mark_done(db, APPLE_PROVIDER_CODE, notification_uuid, result)
    return result


async def replay_apple_notification_event(db, raw: dict[str, Any]) -> dict[str, Any]:
    """管理端 webhook 事件重放:用摄取记录里的 signedPayload 重新验签并执行既有处理逻辑。"""
    signed_payload = str((raw or {}).get("signedPayload") or "")
    if not signed_payload:
        raise HTTPException(status_code=400, detail="事件记录缺少 signedPayload,无法重放")
    config = await load_apple_iap_config()
    notification = verify_notification(config, signed_payload)
    notification_type = str(notification.rawNotificationType or "")
    subtype = str(notification.rawSubtype or "")
    notification_uuid = str(notification.notificationUUID or "")
    if notification_type == "TEST" or not notification_uuid:
        raise HTTPException(status_code=400, detail="该通知不具备可重放的业务载荷")
    return await _process_apple_notification(db, config, notification, notification_type, subtype, notification_uuid)


async def _process_apple_notification(
    db,
    config: dict[str, Any],
    notification,
    notification_type: str,
    subtype: str,
    notification_uuid: str,
) -> dict[str, Any]:
    """既有通知处理逻辑,原样保留(内部自带 payment_callback_events 幂等)。"""
    notif_event_id = f"apple_notif:{notification_uuid}"
    if await _event_exists(db, notif_event_id):
        return {"status": "duplicate"}

    signed_txn_info = notification.data.signedTransactionInfo if notification.data else None
    if not signed_txn_info:
        await _record_event(db, notif_event_id, "apple_notification", {
            "provider": APPLE_PROVIDER_CODE,
            "notification_type": notification_type,
            "subtype": subtype,
        })
        result = {"status": "ignored", "reason": "missing_transaction_info", "notification_type": notification_type}
        await _mark_event_applied(db, notif_event_id, result)
        return result

    txn = verify_signed_transaction(config, signed_txn_info)
    user_email = await _resolve_user_email_for_txn(db, txn)
    if not user_email and notification_type in GRANT_NOTIFICATION_TYPES:
        token = str(txn.appAccountToken or "").lower()
        # 找不到归属用户:客户端可能尚未完成首购上报,让苹果稍后重试
        logger.warning(
            "Apple 通知暂无法映射用户,等待重试: type=%s original_txn=%s token=%s",
            notification_type, txn.originalTransactionId, token or "-",
        )
        raise HTTPException(status_code=503, detail="user mapping not ready")

    raw_event = {
        "provider": APPLE_PROVIDER_CODE,
        "channel": "server_notification",
        "notification_type": notification_type,
        "subtype": subtype,
        "notification_uuid": notification_uuid,
        "transaction": {k: (v.isoformat() if isinstance(v, datetime) else v) for k, v in _txn_summary(txn).items()},
    }

    result: dict[str, Any]
    try:
        if notification_type in GRANT_NOTIFICATION_TYPES:
            result = await _apply_verified_transaction(db, txn, user_email=user_email, source="server_notification", raw_event=raw_event)
        elif notification_type in STATUS_NOTIFICATION_TYPES:
            result = await _handle_status_notification(db, notification_type, subtype, txn, user_email)
        elif notification_type in REFUND_NOTIFICATION_TYPES:
            result = await _handle_refund_notification(db, txn, user_email, raw_event)
        else:
            result = {"status": "ignored", "notification_type": notification_type, "subtype": subtype}
    except HTTPException as exc:
        # 业务性拒绝(如降级续订):记录后返回 200,避免苹果对确定性失败无限重试
        if exc.status_code >= 500:
            raise
        logger.warning("Apple 通知业务处理被拒绝: type=%s detail=%s", notification_type, exc.detail)
        result = {"status": "rejected", "notification_type": notification_type, "detail": exc.detail}

    await _record_event(db, notif_event_id, "apple_notification", {
        "provider": APPLE_PROVIDER_CODE,
        "user_email": user_email,
        "notification_type": notification_type,
        "subtype": subtype,
        "raw_event": raw_event,
    })
    await _mark_event_applied(db, notif_event_id, result)
    return result


def _is_current_apple_subscription(user: dict[str, Any] | None, txn: JWSTransactionDecodedPayload) -> bool:
    if not user:
        return False
    return (
        str(user.get("latest_payment_provider") or "") == APPLE_PROVIDER_CODE
        and str(user.get("latest_provider_payment_id") or "") == str(txn.originalTransactionId or "")
    )


async def _handle_status_notification(db, notification_type: str, subtype: str, txn: JWSTransactionDecodedPayload, user_email: str) -> dict[str, Any]:
    if not user_email:
        return {"status": "ignored", "reason": "user_mapping_missing", "notification_type": notification_type}
    now = datetime.now(timezone.utc)
    user = await db["users"].find_one({"email": user_email})
    subscription_update: dict[str, Any] = {"updated_at": now}
    user_update: dict[str, Any] = {}
    if notification_type == "DID_CHANGE_RENEWAL_STATUS":
        auto_renew = subtype == "AUTO_RENEW_ENABLED"
        subscription_update["auto_renew"] = auto_renew
        if _is_current_apple_subscription(user, txn):
            user_update["subscription_auto_renew"] = auto_renew
    elif notification_type in {"EXPIRED", "GRACE_PERIOD_EXPIRED"}:
        subscription_update["status"] = "expired"
        if _is_current_apple_subscription(user, txn):
            user_update["subscription_status"] = "expired"
    elif notification_type == "DID_FAIL_TO_RENEW":
        subscription_update["status"] = "past_due"
        if _is_current_apple_subscription(user, txn):
            user_update["subscription_status"] = "past_due"
    await db[SUBSCRIPTIONS_COLLECTION].update_one(
        {"original_transaction_id": txn.originalTransactionId},
        {"$set": subscription_update},
    )
    if user_update:
        user_update["updated_at"] = now
        await db["users"].update_one({"email": user_email}, {"$set": user_update})
    return {
        "status": "synced",
        "notification_type": notification_type,
        "subtype": subtype,
        "user_updated": bool(user_update),
    }


async def _handle_refund_notification(db, txn: JWSTransactionDecodedPayload, user_email: str, raw_event: dict[str, Any]) -> dict[str, Any]:
    """苹果退款/家庭共享撤销:吊销对应权益(退款动作由苹果完成,本服务只做业务回收)。"""
    original_event_id = _event_id_for(txn)
    refund_event_id = f"apple_refund:{txn.transactionId}"
    now = datetime.now(timezone.utc)
    if await _event_exists(db, refund_event_id):
        return {"status": "duplicate", "refund_event_id": refund_event_id}
    original_event = await db["payment_callback_events"].find_one({"payment_event_id": original_event_id})
    if not original_event:
        return {"status": "ignored", "reason": "original_event_not_found", "payment_event_id": original_event_id}
    business_result: dict[str, Any]
    if original_event.get("event_type") == "credits_topup":
        update_result = await db["credit_grants"].update_many(
            {
                "user_email": user_email,
                "credit_type": "paid_topup",
                "status": CREDIT_STATUS_ACTIVE,
                "metadata.payment_event_id": original_event_id,
            },
            {"$set": {"status": "expired", "expires_at": now, "expired_reason": "apple_refund", "updated_at": now}},
        )
        business_result = {"status": "applied", "scope": "credits_topup", "expired_grants": update_result.modified_count}
    else:
        user = await db["users"].find_one({"email": user_email})
        if user and user.get("latest_payment_event_id") == original_event_id:
            downgrade = await _downgrade_user_to_free(db, user_email, refund_event_id, now)
            business_result = {"status": "applied", "scope": "current_subscription", **{k: v for k, v in downgrade.items() if k != "credit_lifecycle"}}
        else:
            business_result = {"status": "not_required", "reason": "not_current_subscription"}
        await db[SUBSCRIPTIONS_COLLECTION].update_one(
            {"original_transaction_id": txn.originalTransactionId},
            {"$set": {"status": "revoked", "updated_at": now}},
        )
    amount_cents = transaction_paid_cents(txn)
    await db["payment_callback_events"].update_one(
        {"payment_event_id": original_event_id},
        {"$inc": {"refunded_cents": amount_cents}, "$set": {"refund_status": "refunded", "updated_at": now}},
    )
    await db["payment_orders"].update_one(
        {"order_id": f"apple_{txn.transactionId}"},
        {"$set": {"status": "refunded", "refund_status": "refunded", "refunded_amount_cents": amount_cents, "updated_at": now}},
    )
    await db["payment_refunds"].update_one(
        {"refund_id": refund_event_id},
        {"$setOnInsert": {
            "refund_id": refund_event_id,
            "order_id": f"apple_{txn.transactionId}",
            "user_email": user_email,
            "provider": APPLE_PROVIDER_CODE,
            "payment_channel": APPLE_PAYMENT_CHANNEL,
            "payment_event_id": original_event_id,
            "payment_order_id": f"apple_{txn.transactionId}",
            "provider_payment_id": txn.originalTransactionId,
            "refund_mode": "full",
            "amount_cents": amount_cents,
            "currency": str(txn.currency or "").upper(),
            "status": "refunded",
            "reason_code": "apple_platform_refund",
            "reason": "苹果平台退款/撤销",
            "revoke_entitlement": True,
            "business_result": business_result,
            "raw_event": raw_event,
            "created_at": now,
            "updated_at": now,
        }},
        upsert=True,
    )
    return {"status": "applied", "refund_event_id": refund_event_id, "business_result": business_result}


@router.get("/admin/config")
async def apple_admin_config(_: None = Security(verify_callback_key)):
    return masked_apple_iap_config(await load_apple_iap_config(refresh=True))


@router.post("/admin/config")
async def save_apple_admin_config(data: AppleIapConfigRequest, _: None = Security(verify_callback_key)):
    payload = data.model_dump() if hasattr(data, "model_dump") else data.dict()
    current = await load_apple_iap_config(refresh=True)
    payload = merge_existing_apple_secrets(payload, current)
    config = await save_apple_iap_config(clean_apple_iap_config(payload))
    return {"message": "Apple IAP 配置已保存", **masked_apple_iap_config(config)}
