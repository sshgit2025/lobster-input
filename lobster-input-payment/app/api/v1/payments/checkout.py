"""结算域(Checkout)路由 —— 订阅结算/报价/加购结算。"""
from app.api.v1.payments._common import *  # noqa: F401,F403  复用计费域共享内核(工具/常量/鉴权/依赖)

router = APIRouter(tags=["payments"])


@router.post("/checkout/subscription")
async def create_subscription_checkout(
    data: CreateSubscriptionCheckoutRequest,
    _: None = Security(verify_callback_key),
):
    db = get_main_db()
    config = await load_billing_config()
    plan_code = _normalize_plan_code(data.plan_code)
    if not plan_code or plan_code != data.plan_code:
        raise HTTPException(status_code=400, detail="套餐代码不合法")
    settlement_mode = _normalize_settlement_mode(data.settlement_mode)
    user = await db["users"].find_one({"email": data.user_email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    if not await _client_subscription_module_enabled(db):
        raise HTTPException(status_code=403, detail="客户端订阅入口已关闭")
    plan_configs = (await db["system_config"].find_one({"key": "plan_configs"}) or {}).get("value", {})
    plan_doc = _clean_plan_config(plan_code, plan_configs.get(plan_code, {}))
    if not _can_self_checkout(plan_doc):
        raise HTTPException(status_code=400, detail="该套餐不可由用户支付购买")
    now = datetime.now(timezone.utc)
    active_plan_code = _active_plan_code(user)
    active_plan_doc = _clean_plan_config(active_plan_code, plan_configs.get(active_plan_code, {}))
    billing_option = (plan_doc.get("billing_options") or {}).get(data.billing_cycle)
    if not billing_option or billing_option.get("enabled") is False:
        raise HTTPException(status_code=400, detail="支付方式不合法或未启用")
    duration_count = max(1, int(billing_option.get("duration_count") or 1))
    duration_period = billing_option.get("duration_period") if billing_option.get("duration_period") in {"month", "year"} else "month"
    target_months = _duration_months(duration_period, duration_count)
    _reject_duplicate_or_downgrade_checkout(user, active_plan_doc, plan_doc, target_months, now)
    product_code = _normalize_plan_code(data.product_code) or f"{plan_code}_{data.billing_cycle}".lower()
    product = products_by_code(config).get(product_code)
    if not product or product.get("type") != "subscription" or product.get("plan_code") != plan_code or product.get("billing_cycle") != data.billing_cycle:
        raise HTTPException(status_code=400, detail="该套餐未配置支付商品")
    try:
        method, binding, account = resolve_binding(config, product_code, data.payment_method, data.currency)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    price = binding
    profile, adapter = await _payment_context_for_account(account)
    provider = _active_provider_code(profile)
    product_id = binding.get("external_product_id") or ""
    if binding.get("mode") == "external_product" and not product_id:
        raise HTTPException(status_code=400, detail="该支付渠道未配置外部商品 ID")
    # 结算模式与应付金额由服务端权威计算，客户端传入的 settlement_mode 仅做合法性校验
    pricing = await _resolve_checkout_pricing(
        db, config,
        user=user, active_code=active_plan_code, active_plan_doc=active_plan_doc,
        target_code=plan_code, target_plan_doc=plan_doc,
        billing_cycle=data.billing_cycle, duration_count=duration_count, duration_period=duration_period,
        method=method, binding=binding, now=now,
    )
    settlement_mode = pricing["settlement_mode"]
    payable_cents = int(pricing["payable_cents"])
    # 自动续费按渠道能力收敛:无代扣能力的渠道(如 zpay)恒关闭;见 docs/auto-renewal-strategy.md。
    # 读 provider capability 而非硬编码渠道名,接入新的无/有代扣渠道无需改此处。
    auto_renew = bool(data.auto_renew) and provider_capability(provider, "supports_recurring")
    request_id = f"lobster_sub_{uuid4().hex}"
    discount_code = _checkout_discount_code(binding, provider, data.discount_code)
    order_id = f"ord_{uuid4().hex}"
    # Creem 固定价商品升级补差价:动态建一次性折扣券,券额=未用抵扣,用户结账只付差价。
    # 建券失败则诚实回退全价,并在履约时登记「待人工 Dashboard 补退」台账(见 _auto_refund_previous_subscription)。
    upgrade_discount: dict[str, Any] = {}
    if (
        provider_capability(provider, "supports_discount_codes")
        and binding.get("mode") == "external_product"
        and pricing.get("credit_realization") == "discount"
        and settlement_mode == SETTLEMENT_PRORATED_DIFFERENCE
        and int(pricing["credit_cents"]) > 0
        and product_id
    ):
        # Creem 折扣码上限 14 字符:UPG(3) + 10 位 hex = 13,足够短时唯一
        proration_code = f"UPG{secrets.token_hex(5).upper()}"
        expiry_iso = (now + timedelta(minutes=CREEM_UPGRADE_DISCOUNT_TTL_MINUTES)).strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            minted = await adapter.create_discount(
                code=proration_code,
                amount_cents=int(pricing["credit_cents"]),
                currency=price.get("currency") or binding.get("currency") or "USD",
                applies_to_product_ids=[product_id],
                expiry_date=expiry_iso,
                max_redemptions=1,
                name=f"proration {plan_code} {proration_code}",  # Creem name 上限 40 字符
            )
            discount_code = minted.get("code") or proration_code
            upgrade_discount = {
                "provider": "creem",
                "discount_id": minted.get("discount_id") or "",
                "discount_code": discount_code,
                "amount_cents": int(pricing["credit_cents"]),
                "single_use": True,
                "expires_at": expiry_iso,
                "status": "issued",
            }
        except HTTPException as exc:
            logger.warning(
                "[upgrade] Creem 补差价折扣创建失败,回退全价+人工补退 order=%s: %s",
                order_id, getattr(exc, "detail", exc),
            )
            settlement_mode = SETTLEMENT_FULL_PRICE
            payable_cents = int(pricing["list_price_cents"])
            upgrade_discount = {
                "provider": "creem",
                "status": "mint_failed",
                "owed_cents": int(pricing["credit_cents"]),
            }
    metadata = {
        "kind": "subscription",
        "order_id": order_id,
        "user_email": data.user_email,
        "product_code": product_code,
        "plan_code": plan_code,
        "billing_cycle": data.billing_cycle,
        "settlement_mode": settlement_mode,
        "auto_renew": str(auto_renew).lower(),
    }
    checkout_payload = {
        "product_id": product_id,
        "request_id": request_id,
        "user_email": data.user_email,
        "success_url": _provider_return_url(provider, request_id),
        "notify_url": _provider_webhook_url(provider),
        "product_name": product.get("name") or product_code,
        "amount_cents": payable_cents,
        "currency": price.get("currency") or binding.get("currency") or "",
        "payment_method": method.get("code"),
        "discount_code": discount_code,
        "metadata": metadata,
    }
    try:
        checkout = await adapter.create_checkout(**checkout_payload)
    except HTTPException as exc:
        if not _is_auto_discount(binding, provider, data.discount_code, discount_code) or not _is_creem_discount_product_error(exc):
            raise
        discount_code = ""
        checkout_payload["discount_code"] = ""
        checkout = await adapter.create_checkout(**checkout_payload)
    now = datetime.now(timezone.utc)
    order_doc = {
        "order_id": order_id,
        "user_email": data.user_email,
        "kind": "subscription",
        "product_code": product_code,
        "product_name": product.get("name") or product_code,
        "plan_code": plan_code,
        "billing_cycle": data.billing_cycle,
        "amount_cents": payable_cents,
        "list_price_cents": int(pricing["list_price_cents"]),
        "upgrade_credit_cents": int(pricing["credit_cents"]),
        "change_mode": pricing["change_mode"],
        "currency": price.get("currency") or binding.get("currency") or "",
        "status": "pending_payment",
        "provider": provider,
        "payment_method": method.get("code"),
        "payment_channel": account.get("code"),
        "settlement_mode": settlement_mode,
        "auto_renew": auto_renew,
        "upgrade_discount": upgrade_discount,
        "created_at": now,
        "updated_at": now,
    }
    await db["payment_orders"].insert_one(order_doc)
    doc = {
        "attempt_id": request_id,
        "order_id": order_id,
        "request_id": request_id,
        "checkout_id": checkout.get("id"),
        "checkout_url": checkout.get("checkout_url"),
        "provider": provider,
        "payment_method": method.get("code"),
        "payment_channel": account.get("code"),
        "kind": "subscription",
        "status": "pending",
        "user_email": data.user_email,
        "product_code": product_code,
        "plan_code": plan_code,
        "billing_cycle": data.billing_cycle,
        "settlement_mode": settlement_mode,
        "auto_renew": auto_renew,
        "product_id": product_id,
        "discount_code": discount_code,
        "upgrade_discount": upgrade_discount,
        "raw_checkout": checkout,
        "created_at": now,
        "updated_at": now,
    }
    await db["payment_checkout_sessions"].insert_one(doc)
    await db["payment_attempts"].insert_one(dict(doc))
    return {
        "provider": provider,
        "request_id": request_id,
        "order_id": order_id,
        "checkout_id": checkout.get("id"),
        "checkout_url": checkout.get("checkout_url"),
        "status": checkout.get("status", "pending"),
        "product_id": product_id,
        "product_code": product_code,
        "plan_code": plan_code,
        "billing_cycle": data.billing_cycle,
        "payment_method": method.get("code"),
        "discount_code": discount_code,
        "settlement_mode": settlement_mode,
        "amount_cents": payable_cents,
        "list_price_cents": int(pricing["list_price_cents"]),
        "upgrade_credit_cents": int(pricing["credit_cents"]),
        "currency": price.get("currency") or binding.get("currency") or "",
    }


@router.post("/quote/subscription-options")
async def quote_subscription_options(
    data: SubscriptionQuoteRequest,
    _: None = Security(verify_callback_key),
):
    """按用户当前订阅态给出每个 套餐:账期 的可购性与应付金额(升级为补差价)。"""
    db = get_main_db()
    config = await load_billing_config()
    user = await db["users"].find_one({"email": data.user_email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    now = datetime.now(timezone.utc)
    plan_configs = (await db["system_config"].find_one({"key": "plan_configs"}) or {}).get("value", {})
    active_code = _active_plan_code(user)
    active_plan_doc = _clean_plan_config(active_code, plan_configs.get(active_code, {}))
    active_paid = _active_paid_subscription(user, active_plan_doc, now)
    active_cycle, _ = _active_billing_cycle_months(user, active_plan_doc)
    options: dict[str, dict[str, Any]] = {}
    for product in (config.get("products") or []):
        if product.get("type") != "subscription" or product.get("enabled") is False:
            continue
        plan_code = _normalize_plan_code(product.get("plan_code") or "")
        cycle = str(product.get("billing_cycle") or "").strip().lower()
        if not plan_code or not cycle:
            continue
        plan_doc = _clean_plan_config(plan_code, plan_configs.get(plan_code, {}))
        if not _can_self_checkout(plan_doc):
            continue
        option = (plan_doc.get("billing_options") or {}).get(cycle)
        if not option or option.get("enabled") is False:
            continue
        duration_count = max(1, int(option.get("duration_count") or 1))
        duration_period = option.get("duration_period") if option.get("duration_period") in {"month", "year"} else "month"
        target_months = _duration_months(duration_period, duration_count)
        resolved = None
        try:
            resolved = resolve_binding(config, product.get("code") or "", data.payment_method, data.currency)
        except ValueError:
            # 未指定支付方式时逐个尝试已启用支付方式，确保有默认报价
            if not data.payment_method:
                for candidate in (config.get("payment_methods") or []):
                    if candidate.get("enabled", True) is False:
                        continue
                    try:
                        resolved = resolve_binding(config, product.get("code") or "", candidate.get("code") or "", data.currency)
                        break
                    except ValueError:
                        continue
        if not resolved:
            continue
        method, binding, _account = resolved
        key = f"{plan_code}:{cycle}"
        reason = _checkout_block_reason(user, active_plan_doc, plan_doc, target_months, now)
        if reason:
            options[key] = {
                "purchasable": False,
                "blocked_reason": reason,
                "settlement_mode": SETTLEMENT_FULL_PRICE,
                "list_price_cents": int(binding.get("amount_cents") or 0),
                "credit_cents": 0,
                "payable_cents": int(binding.get("amount_cents") or 0),
                "currency": str(binding.get("currency") or "").upper(),
            }
            continue
        pricing = await _resolve_checkout_pricing(
            db, config,
            user=user, active_code=active_code, active_plan_doc=active_plan_doc,
            target_code=plan_code, target_plan_doc=plan_doc,
            billing_cycle=cycle, duration_count=duration_count, duration_period=duration_period,
            method=method, binding=binding, now=now,
        )
        options[key] = {"purchasable": True, "blocked_reason": None, **pricing}
    return {
        "active_plan_code": active_code if active_paid else "",
        "active_billing_cycle": active_cycle if active_paid else "",
        "options": options,
    }


@router.post("/checkout/credits-topup")
async def create_credits_topup_checkout(
    data: CreateCreditTopupCheckoutRequest,
    _: None = Security(verify_callback_key),
):
    config = await load_billing_config()
    product_code = _normalize_plan_code(data.product_code) or "credits_topup"
    product = products_by_code(config).get(product_code)
    if not product or product.get("type") != "credits_topup":
        raise HTTPException(status_code=503, detail="加购商品未配置")
    topup_credits = int(product.get("topup_credits") or 0)
    if topup_credits <= 0:
        raise HTTPException(status_code=503, detail="加购积分数量未配置")
    try:
        method, binding, account = resolve_binding(config, product_code, data.payment_method, data.currency)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    profile, adapter = await _payment_context_for_account(account)
    provider = _active_provider_code(profile)
    topup_product_id = binding.get("external_product_id") or ""
    if binding.get("mode") == "external_product" and not topup_product_id:
        raise HTTPException(status_code=503, detail="加购支付商品 ID 未配置")
    price = binding
    db = get_main_db()
    user = await db["users"].find_one({"email": data.user_email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    if not await _client_subscription_module_enabled(db):
        raise HTTPException(status_code=403, detail="客户端订阅入口已关闭")
    now = datetime.now(timezone.utc)
    await CreditGrantLifecycleCoordinator(db).refresh_for_user(data.user_email, now)
    plan_code = _active_plan_code(user)
    plan_configs = (await db["system_config"].find_one({"key": "plan_configs"}) or {}).get("value", {})
    plan_doc = _clean_plan_config(plan_code, plan_configs.get(plan_code, {}))
    expires_at = _normalize_dt(user.get("subscription_expires_at") or user.get("plan_expires_at"))
    if not _is_paid_plan(plan_doc) or not plan_doc.get("paid_topup_enabled", True) or not expires_at or expires_at <= now:
        raise HTTPException(status_code=400, detail="仅有效付费套餐用户允许加购积分")
    if _plan_remaining(user) > 0:
        raise HTTPException(status_code=400, detail="当前套餐积分仍有剩余，不能加购")
    request_id = f"lobster_topup_{uuid4().hex}"
    order_id = f"ord_{uuid4().hex}"
    discount_code = (data.discount_code or "").strip()
    metadata = {
        "kind": "credits_topup",
        "order_id": order_id,
        "user_email": data.user_email,
        "product_code": product_code,
        "amount": str(topup_credits),
        "subscription_plan_code": plan_code,
    }
    checkout = await adapter.create_checkout(
        product_id=topup_product_id,
        request_id=request_id,
        user_email=data.user_email,
        success_url=_provider_return_url(provider, request_id),
        notify_url=_provider_webhook_url(provider),
        product_name=product.get("name") or product_code,
        amount_cents=int(price.get("amount_cents") or 0),
        currency=price.get("currency") or binding.get("currency") or "",
        payment_method=method.get("code"),
        discount_code=discount_code,
        metadata=metadata,
    )
    order_doc = {
        "order_id": order_id,
        "user_email": data.user_email,
        "kind": "credits_topup",
        "product_code": product_code,
        "product_name": product.get("name") or product_code,
        "amount": topup_credits,
        "amount_cents": int(price.get("amount_cents") or 0),
        "currency": price.get("currency") or binding.get("currency") or "",
        "status": "pending_payment",
        "provider": provider,
        "payment_method": method.get("code"),
        "payment_channel": account.get("code"),
        "created_at": now,
        "updated_at": now,
    }
    await db["payment_orders"].insert_one(order_doc)
    doc = {
        "attempt_id": request_id,
        "order_id": order_id,
        "request_id": request_id,
        "checkout_id": checkout.get("id"),
        "checkout_url": checkout.get("checkout_url"),
        "provider": provider,
        "payment_method": method.get("code"),
        "payment_channel": account.get("code"),
        "kind": "credits_topup",
        "status": "pending",
        "user_email": data.user_email,
        "product_code": product_code,
        "amount": topup_credits,
        "product_id": topup_product_id,
        "discount_code": discount_code,
        "raw_checkout": checkout,
        "created_at": now,
        "updated_at": now,
    }
    await db["payment_checkout_sessions"].insert_one(doc)
    await db["payment_attempts"].insert_one(dict(doc))
    return {
        "provider": provider,
        "request_id": request_id,
        "order_id": order_id,
        "checkout_id": checkout.get("id"),
        "checkout_url": checkout.get("checkout_url"),
        "status": checkout.get("status", "pending"),
        "product_id": topup_product_id,
        "product_code": product_code,
        "amount": topup_credits,
        "payment_method": method.get("code"),
        "discount_code": discount_code,
    }


