"""Webhook 域路由 —— 渠道 webhook 入口 + 规范化事件领域分发。

dispatch_webhook_event 需复用 callback 域端点(subscription_callback/credits_topup_callback)完成履约,
故本模块单向 import callback(callback 不反向依赖,无环)。"""
from app.api.v1.payments._common import *  # noqa: F401,F403  复用计费域共享内核(工具/常量/鉴权/依赖)
from app.api.v1.payments.callback import subscription_callback, credits_topup_callback

router = APIRouter(tags=["payments"])


async def apply_subscription_status(db, event_type: str, obj: dict, raw_event: dict) -> dict:
    """订阅状态变更履约(provider 无关):取消/逾期/到期同步到用户订阅态。"""
    customer = obj.get("customer") or {}
    email = customer.get("email")
    subscription_id = obj.get("id") or ""
    if not email:
        return {"status": "ignored", "reason": "missing_customer_email"}
    # 仅当事件所属订阅确为用户"当前订阅"时,才回写用户级订阅态(auto_renew/expires/status)。
    # 升级/换渠道会创建新订阅并对旧订阅周期末取消,旧订阅随后的 scheduled_cancel/canceled/expired
    # 若无差别覆盖,会把当前(新)订阅的到期时间倒回旧值、误关自动续费、并把
    # latest_provider_subscription_id 倒回旧订阅 id,截断当前权益、破坏续费映射。
    # latest_provider_subscription_id 只由 subscription.paid 履约维护,状态事件不再改写它。
    user = await db["users"].find_one({"email": email})
    current_sub_id = str((user or {}).get("latest_provider_subscription_id") or "").strip()
    if not subscription_id or subscription_id != current_sub_id:
        return {
            "status": "ignored",
            "reason": "stale_subscription",
            "event_type": event_type,
            "subscription_id": subscription_id,
            "current_subscription_id": current_sub_id,
        }
    update: dict[str, Any] = {
        "latest_payment_customer_id": customer.get("id") or "",
        "updated_at": datetime.now(timezone.utc),
    }
    period_end = _dt_from_creem(obj.get("current_period_end_date"))
    if event_type in {"subscription.scheduled_cancel", "subscription.canceled"}:
        update["subscription_auto_renew"] = False
        if period_end:
            update["subscription_expires_at"] = period_end
            update["plan_expires_at"] = period_end
    elif event_type in {"subscription.past_due"}:
        update["subscription_status"] = "past_due"
    elif event_type in {"subscription.expired"}:
        update["subscription_status"] = "expired"
        if period_end:
            update["subscription_expires_at"] = period_end
            update["plan_expires_at"] = period_end
    result = await db["users"].update_one({"email": email}, {"$set": update})
    return {"status": "synced", "matched": bool(result.modified_count), "event_type": event_type}


async def _webhook_provider_accounts(provider: str) -> list[dict[str, Any]]:
    """列出 provider 下所有启用的渠道账号(webhook 验签与重放共用)。"""
    config = await load_billing_config()
    return [
        {**account, "provider_code": channel.get("provider_code"), "channel_code": channel.get("code")}
        for channel in config.get("channels") or []
        for account in channel.get("accounts") or []
        if channel.get("provider_code") == provider and channel.get("enabled", True) and account.get("enabled", True)
    ]


async def dispatch_webhook_event(db, profile: dict[str, Any], adapter, event: NormalizedWebhookEvent) -> dict:
    """规范化 webhook 事件的 provider 无关领域分发。

    渠道差异已由 adapter.normalize_webhook_event 抹平到 NormalizedWebhookEvent;这里只按领域
    事件类型调用统一的履约业务函数并做后处理。webhook 实时入口与失败重放共用本函数。
    """
    now = datetime.now(timezone.utc)
    if event.kind == WebhookEventKind.SUBSCRIPTION_PAYMENT:
        # 履约写库前快照用户(latest_provider_subscription_id 仍是旧订阅),供换订阅时取消旧代扣
        user_before = await db["users"].find_one({"email": event.subscription["user_email"]})
        user_before = dict(user_before) if user_before else None
        result = await subscription_callback(SubscriptionPaymentRequest(**event.subscription), None)
        if event.result_overrides:
            result = {**result, **event.result_overrides}
        if event.callback_event_updates:
            await db["payment_callback_events"].update_one(
                {"payment_event_id": event.subscription["payment_event_id"]},
                {"$set": {**event.callback_event_updates, "updated_at": now}},
            )
        if event.checkout:
            await _mark_checkout_completed(db, event.checkout, event.raw, result)
            await _best_effort_delete_upgrade_discount(profile, event.checkout)
        if result.get("status") == "applied":
            # 有代扣能力的当前渠道用自身 adapter 取消旧订阅;无代扣渠道(如 ZPay)传 None,由 helper 按旧渠道构建
            stale_adapter = adapter if adapter.supports_recurring else None
            await _best_effort_cancel_stale_provider_subscription(db, stale_adapter, user_before, event.new_subscription_id)
        if event.user_updates:
            await db["users"].update_one(
                {"email": event.subscription["user_email"]},
                {"$set": {**event.user_updates, "updated_at": now}},
            )
        return result

    if event.kind == WebhookEventKind.TOPUP:
        result = await credits_topup_callback(CreditTopupPaymentRequest(**event.topup), None)
        if event.result_overrides:
            result = {**result, **event.result_overrides}
        if event.callback_event_updates:
            await db["payment_callback_events"].update_one(
                {"payment_event_id": event.topup["payment_event_id"]},
                {"$set": {**event.callback_event_updates, "updated_at": now}},
            )
        if event.checkout:
            await _mark_checkout_completed(db, event.checkout, event.raw, result)
        return result

    if event.kind == WebhookEventKind.SUBSCRIPTION_STATUS:
        if not await _record_event(db, event.event_id, "provider_subscription_status", {
            "provider": event.provider, "raw_event": event.raw, "provider_event_type": event.provider_event_type,
        }):
            return {"status": "duplicate"}
        result = await apply_subscription_status(
            db, event.status_change["event_type"], event.status_change["object"], event.raw,
        )
        await _mark_event_applied(db, event.event_id, result)
        return result

    # IGNORED
    if not await _record_event(db, event.event_id, "provider_ignored", {
        "provider": event.provider, "raw_event": event.raw, "provider_event_type": event.provider_event_type,
    }):
        return {"status": "duplicate"}
    result = {"status": "ignored", "event_type": event.provider_event_type}
    await _mark_event_applied(db, event.event_id, result)
    return result


@router.api_route("/webhook/{provider}", methods=["GET", "POST"])
async def payment_provider_webhook(provider: str, request: Request):
    provider = _normalize_provider(provider)
    accounts = await _webhook_provider_accounts(provider)
    if not accounts:
        raise HTTPException(status_code=404, detail="支付 provider 未启用")
    raw_body = await request.body()
    db = get_main_db()
    profile = None
    adapter = None
    first_adapter = None
    last_error: HTTPException | None = None
    # 遍历该 provider 所有启用账号验签:渠道差异(验签体、签名位置)由 adapter 决定,入口 provider 无关
    for account in accounts:
        candidate_profile, candidate_adapter = await _payment_context_for_account(account)
        if first_adapter is None:
            first_adapter = candidate_adapter
        try:
            verify_body = candidate_adapter.webhook_verify_body(raw_body, request)
            candidate_adapter.verify_webhook_signature(verify_body, candidate_adapter.webhook_signature(request))
            profile, adapter = candidate_profile, candidate_adapter
            break
        except HTTPException as exc:
            last_error = exc
    if adapter is None or profile is None:
        # 验签失败:落一条 signature_ok=false 的记录(独立键空间,不占用真实事件 ID),按原行为拒绝
        try:
            ingest_event_id = first_adapter.webhook_event_id(raw_body, request)
            await webhook_ingest.ingest(
                db, provider, webhook_ingest.invalid_signature_event_id(ingest_event_id),
                first_adapter.webhook_ingest_raw(raw_body, request), False,
            )
        except Exception:
            logger.exception("记录验签失败 webhook 事件时出错: provider=%s", provider)
        raise last_error or HTTPException(status_code=401, detail="Invalid webhook signature")
    # 幂等摄取(先于 normalize,保证 normalize/处理失败的事件也留档可重放)→ 规范化 → 领域分发 → 回写
    ingest_event_id = adapter.webhook_event_id(raw_body, request)
    if await webhook_ingest.ingest(db, provider, ingest_event_id, adapter.webhook_ingest_raw(raw_body, request), True) == "duplicate":
        return PlainTextResponse(adapter.webhook_ack_text) if adapter.webhook_ack_text else {"status": "duplicate"}
    try:
        event = await adapter.normalize_webhook_event(db, raw_body, request)
        result = await dispatch_webhook_event(db, profile, adapter, event)
    except Exception as exc:
        await webhook_ingest.mark_failed(db, provider, ingest_event_id, webhook_ingest.error_text(exc))
        raise
    await webhook_ingest.mark_done(db, provider, ingest_event_id, result)
    return PlainTextResponse(adapter.webhook_ack_text) if adapter.webhook_ack_text else result
