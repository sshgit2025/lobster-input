"""订阅管理域路由 —— 自助管理页 portal / 取消自动续费。"""
from app.api.v1.payments._common import *  # noqa: F401,F403  复用计费域共享内核(工具/常量/鉴权/依赖)

router = APIRouter(tags=["payments"])


@router.post("/portal/subscription")
async def subscription_manage_portal(
    data: SubscriptionPortalRequest,
    _: None = Security(verify_callback_key),
):
    """平台托管自动续费渠道(Creem)的用户自助管理页链接;zpay 无此概念返回 400。"""
    db = get_main_db()
    user = await db["users"].find_one({"email": data.user_email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    provider = _normalize_provider(user.get("latest_payment_provider"))
    customer_id = str(user.get("latest_payment_customer_id") or "").strip()
    if not provider_capability(provider, "supports_customer_portal") or not customer_id:
        raise HTTPException(status_code=400, detail="当前订阅渠道不支持自助管理页：微信/支付宝为手动续费，到期后再次购买即可")
    config = await load_billing_config()
    account = _active_provider_account(config, provider)
    if not account:
        raise HTTPException(status_code=503, detail="订阅渠道未配置")
    _profile, adapter = await _payment_context_for_account(account)
    portal_url = await adapter.customer_portal_link(customer_id)
    return {"portal_url": portal_url, "provider": provider}


@router.post("/subscription/cancel-renewal")
async def cancel_subscription_renewal(
    data: CancelRenewalRequest,
    _: None = Security(verify_callback_key),
):
    """取消自动续费(周期末生效,权益保留到 subscription_expires_at)。

    - Creem 订阅同步做渠道 scheduled 取消,阻断下一次代扣;
    - 渠道取消失败不阻断:用户取消意图优先,本地 auto_renew 仍置 False,
      channel_sync="failed" + 告警日志留待人工在渠道后台处理;
    - zpay 等无代扣渠道(无渠道订阅 id)只改本地开关,channel_sync="skipped"。
    """
    db = get_main_db()
    user = await db["users"].find_one({"email": data.user_email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    now = datetime.now(timezone.utc)
    effective_until = _normalize_dt(user.get("subscription_expires_at") or user.get("plan_expires_at"))
    if not bool(user.get("subscription_auto_renew")):
        return {"status": "already_cancelled", "effective_until": effective_until}
    provider = _normalize_provider(user.get("latest_payment_provider"))
    # Apple IAP 订阅的续费由 Apple 权威管理:只能在 App Store 取消,Apple 会经
    # server notification(AUTO_RENEW_DISABLED)回同步本地 auto_renew。此处若擅自
    # 置 False 会造成「本地已取消/Apple 照扣」的状态分裂,故明确拒绝、不改任何状态。
    if provider == "apple":
        return {"status": "apple_managed", "effective_until": effective_until}
    subscription_id = str(user.get("latest_provider_subscription_id") or "").strip()
    channel_sync = "skipped"
    if provider_capability(provider, "supports_recurring") and subscription_id:
        try:
            config = await load_billing_config()
            account = _active_provider_account(config, provider)
            if not account:
                raise HTTPException(status_code=503, detail="订阅渠道未配置")
            _profile, adapter = await _payment_context_for_account(account)
            await adapter.cancel_subscription(subscription_id, mode="scheduled")
            channel_sync = "ok"
        except Exception as exc:  # noqa: BLE001 - 渠道失败不阻断用户取消意图
            channel_sync = "failed"
            detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
            logger.warning(
                "[cancel-renewal][需人工处理] Creem 渠道取消失败,本地已关闭自动续费 email=%s subscription_id=%s: %s",
                data.user_email, subscription_id, detail,
            )
    await db["users"].update_one(
        {"email": data.user_email},
        {"$set": {"subscription_auto_renew": False, "updated_at": now}},
    )
    await db["subscription_events"].insert_one({
        "event_type": "cancel_renewal",
        "email": data.user_email,
        "provider": provider,
        "subscription_id": subscription_id,
        "channel_sync": channel_sync,
        "created_at": now,
    })
    return {"status": "cancelled", "effective_until": effective_until, "channel_sync": channel_sync}


