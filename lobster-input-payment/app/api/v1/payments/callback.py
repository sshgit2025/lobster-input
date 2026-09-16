"""支付回调域路由 —— 订阅回调 / 加购回调(内部签名,幂等履约)。"""
from app.api.v1.payments._common import *  # noqa: F401,F403  复用计费域共享内核(工具/常量/鉴权/依赖)

router = APIRouter(tags=["payments"])


@router.post("/callback/subscription")
async def subscription_callback(data: SubscriptionPaymentRequest, _: None = Security(verify_callback_key)):
    db = get_main_db()
    if await _event_exists(db, data.payment_event_id):
        return {"status": "duplicate"}
    plan_code = _normalize_plan_code(data.plan_code)
    if not plan_code or plan_code != data.plan_code:
        raise HTTPException(status_code=400, detail="套餐代码不合法")
    provider = _normalize_provider(data.provider)
    settlement_mode = _normalize_settlement_mode(data.settlement_mode)
    charge_type = _normalize_charge_type(data.charge_type)
    plan_configs = (await db["system_config"].find_one({"key": "plan_configs"}) or {}).get("value", {})
    plan_doc = _clean_plan_config(plan_code, plan_configs.get(plan_code, {}))
    if not _can_self_checkout(plan_doc):
        raise HTTPException(status_code=400, detail="该套餐不可由用户支付购买")
    billing_option = (plan_doc.get("billing_options") or {}).get(data.billing_cycle)
    if not billing_option or billing_option.get("enabled") is False:
        raise HTTPException(status_code=400, detail="支付方式不合法或未启用")
    duration_count = max(1, int(billing_option.get("duration_count") or 1))
    duration_period = billing_option.get("duration_period") if billing_option.get("duration_period") in {"month", "year"} else "month"
    price_cents = 0 if data.paid_amount_cents is None else int(data.paid_amount_cents)
    paid_amount = price_cents
    if paid_amount < 0:
        raise HTTPException(status_code=400, detail="支付金额不能为负数")
    user = await db["users"].find_one({"email": data.user_email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    now = datetime.now(timezone.utc)
    await CreditGrantLifecycleCoordinator(db).refresh_for_user(data.user_email, now)
    active = _active_plan_code(user)
    active_expires_at = _normalize_dt(user.get("subscription_expires_at") or user.get("plan_expires_at"))
    if active_expires_at and active_expires_at <= now:
        active = FREE_PLAN_CODE
    active_plan_doc = _clean_plan_config(active, plan_configs.get(active, {}))
    change_mode = _resolve_change_mode(user, active, active_plan_doc, plan_code, plan_doc, data.billing_cycle, duration_count, duration_period)
    previous_event = await _latest_subscription_payment_event(db, user, active, active_plan_doc)
    event_payload = {
        **_dump_model(data),
        "provider": provider,
        "settlement_mode": settlement_mode,
        "price_cents": price_cents,
        "paid_amount_cents": paid_amount,
        "payment_order_id": data.payment_order_id or data.payment_event_id,
        "provider_payment_id": data.provider_payment_id or "",
        "payment_channel": data.payment_channel or "",
        "from_plan_code": active,
        "plan_code": plan_code,
        "charge_type": charge_type,
    }
    # P3 权益收敛:先调后端 EntitlementService.grant_paid 授予权益(后端为唯一权益写入方),再记录事件。
    # 顺序保证 backend 失败时事件未记录→webhook 可重放;backend 幂等(payment_event_id)保证重投不重复授予。
    # payment 不再直写 users/credit_grants 订阅权益,只保留验签/记账/订单/退款/渠道职责。
    grant = await _grant_paid_backend({
        "email": data.user_email, "plan_code": plan_code, "billing_cycle": data.billing_cycle,
        "duration_count": duration_count, "duration_period": duration_period, "change_mode": change_mode,
        "auto_renew": bool(data.auto_renew), "paid_amount_cents": paid_amount, "provider": provider,
        "provider_payment_id": data.provider_payment_id or "",
        "payment_order_id": data.payment_order_id or data.payment_event_id,
        "payment_event_id": data.payment_event_id, "charge_type": charge_type,
    })
    if grant.get("status") == "duplicate":
        _u2 = await db["users"].find_one({"email": data.user_email})
        entitle_expires = _normalize_dt((_u2 or {}).get("subscription_expires_at")) or now
        entitle_started = now
    else:
        entitle_expires = _normalize_dt(grant.get("subscription_expires_at")) or now
        entitle_started = _normalize_dt(grant.get("entitlement_started_at")) or now

    if not await _record_event(db, data.payment_event_id, "subscription", event_payload):
        return {"status": "duplicate"}

    if change_mode == "renew":
        base = entitle_started
        expires_at = entitle_expires
        # 权益已由后端 grant_paid(renew:延期不重置积分)授予;payment 只补建续费订单(收入闭环)
        # 续费订单补建(收入闭环):平台托管自动续费(Creem 代扣、未来 Stripe/PayPal 等)无客户端
        # checkout,不经下单流程建订单,会导致续费收入不进 payment_orders(管理端订单列表/收入对账/
        # 退款入口均以该集合为准)。对这类续费(charge_type=auto_renewal)补建一条 paid 订单,幂等
        # (order_id 派生自事件,webhook 重投不重复),使所有托管续费渠道统一进入订单闭环;手动续费
        # (charge_type=manual_purchase)已由 checkout 流程建单,不在此补。
        if charge_type == CHARGE_TYPE_AUTO_RENEWAL:
            renew_order_id = "ord_renew_" + data.payment_event_id.replace(":", "_")
            await db["payment_orders"].update_one(
                {"order_id": renew_order_id},
                {"$setOnInsert": {
                    "order_id": renew_order_id,
                    "user_email": data.user_email,
                    "kind": "subscription",
                    "plan_code": plan_code,
                    "billing_cycle": data.billing_cycle,
                    "amount_cents": paid_amount,
                    "list_price_cents": paid_amount,
                    "upgrade_credit_cents": 0,
                    "change_mode": "renew",
                    "charge_type": charge_type,
                    "currency": "",
                    "status": "paid",
                    "provider": provider,
                    "payment_channel": data.payment_channel or "",
                    "payment_event_id": data.payment_event_id,
                    "payment_order_id": data.payment_order_id or data.payment_event_id,
                    "provider_payment_id": data.provider_payment_id or "",
                    "settlement_mode": settlement_mode,
                    "paid_at": now,
                    "created_at": now,
                    "updated_at": now,
                }},
                upsert=True,
            )
        result = {
            "status": "applied",
            "change_mode": "renew",
            "price_cents": price_cents,
            "paid_amount_cents": paid_amount,
            "subscription_expires_at": expires_at,
            "entitlement_started_at": base,
            "entitlement_expires_at": expires_at,
            "upgrade_refund": {"status": "not_required", "reason": "renew"},
            "charge_type": charge_type,
        }
        await _mark_event_applied(db, data.payment_event_id, result)
        return result

    # 权益已由后端 grant_paid(change_mode=非 renew:换套餐并重置周期积分)授予;payment 只做升级退款(订单/退款侧)
    expires_at = entitle_expires
    upgrade_refund = await _auto_refund_previous_subscription(
        db,
        payment_event_id=data.payment_event_id,
        user_email=data.user_email,
        settlement_mode=settlement_mode,
        change_mode=change_mode,
        previous_event=previous_event,
        now=now,
    )
    result = {
        "status": "applied",
        "change_mode": change_mode,
        "price_cents": price_cents,
        "paid_amount_cents": paid_amount,
        "subscription_started_at": now,
        "subscription_expires_at": expires_at,
        "entitlement_started_at": now,
        "entitlement_expires_at": expires_at,
        "upgrade_refund": upgrade_refund,
        "charge_type": charge_type,
    }
    await _mark_event_applied(db, data.payment_event_id, result)
    return result


@router.post("/callback/credits-topup")
async def credits_topup_callback(data: CreditTopupPaymentRequest, _: None = Security(verify_callback_key)):
    db = get_main_db()
    if await _event_exists(db, data.payment_event_id):
        return {"status": "duplicate"}
    if data.amount <= 0:
        raise HTTPException(status_code=400, detail="加购积分必须大于 0")
    user = await db["users"].find_one({"email": data.user_email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    now = datetime.now(timezone.utc)
    await CreditGrantLifecycleCoordinator(db).refresh_for_user(data.user_email, now)
    plan_code = _active_plan_code(user)
    plan_configs = (await db["system_config"].find_one({"key": "plan_configs"}) or {}).get("value", {})
    plan_doc = _clean_plan_config(plan_code, plan_configs.get(plan_code, {}))
    expires_at = _normalize_dt(user.get("subscription_expires_at") or user.get("plan_expires_at"))
    if not _is_paid_plan(plan_doc) or not plan_doc.get("paid_topup_enabled", True) or not expires_at:
        raise HTTPException(status_code=400, detail="仅付费套餐用户允许加购积分")
    if expires_at <= now:
        raise HTTPException(status_code=400, detail="订阅已到期，不能加购积分")
    if _plan_remaining(user) > 0:
        raise HTTPException(status_code=400, detail="当前套餐积分仍有剩余，不能加购")
    # P3 权益收敛:先调后端 grant_paid_topup 授予加购积分(后端为唯一权益写入方),再记录事件。
    # 失败可重放、后端幂等(payment_event_id)防重复授予;payment 不再直写 credit_grants。
    grant = await _grant_paid_topup_backend({
        "email": data.user_email, "amount": int(data.amount), "expires_at": expires_at.isoformat(),
        "provider": data.provider or "", "payment_event_id": data.payment_event_id, "plan_code": plan_code,
    })
    if not await _record_event(db, data.payment_event_id, "credits_topup", _dump_model(data)):
        return {"status": "duplicate"}
    result = {
        "status": "applied",
        "credit_type": "paid_topup",
        "amount": data.amount,
        "expires_at": expires_at,
        "expires_at_source": "subscription_expires_at",
        "grant_id": grant.get("grant_id", ""),
    }
    await _mark_event_applied(db, data.payment_event_id, result)
    return result


