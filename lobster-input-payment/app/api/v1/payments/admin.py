"""管理域(Admin)路由 —— 计费配置/折扣态/订单/交易/退款(含手动退款)。"""
from app.api.v1.payments._common import *  # noqa: F401,F403  复用计费域共享内核(工具/常量/鉴权/依赖)

router = APIRouter(tags=["payments"])


@router.get("/admin/config")
async def admin_billing_config(_: None = Security(verify_callback_key)):
    return _masked_billing_config(await load_billing_config())


@router.post("/admin/config")
async def save_admin_billing_config(data: BillingConfigRequest, _: None = Security(verify_callback_key)):
    payload = data.model_dump() if hasattr(data, "model_dump") else data.dict()
    current = await load_billing_config(refresh=True)
    payload = _merge_existing_channel_secrets(payload, current)
    config = await save_billing_config(payload)
    return {"message": "计费配置已保存", **_masked_billing_config(config)}


@router.get("/admin/discounts/status")
async def admin_discount_status(_: None = Security(verify_callback_key)):
    config = await load_billing_config(refresh=True)
    now = datetime.now(timezone.utc)
    rows = []
    channels = {channel.get("code"): channel for channel in config.get("channels") or []}
    accounts = {
        (channel.get("code"), account.get("code")): account
        for channel in config.get("channels") or []
        for account in channel.get("accounts") or []
    }
    products = products_by_code(config)
    seen_codes: dict[tuple[str, str], dict[str, Any]] = {}
    for price in config.get("channel_prices") or []:
        channel = channels.get(price.get("channel_code")) or {}
        if channel.get("provider_code") != "creem":
            continue
        code = (price.get("discount_code") or "").strip()
        if price.get("discount_mode") != "auto_apply" and not code:
            continue
        account = accounts.get((price.get("channel_code"), price.get("account_code"))) or {}
        product = products.get(price.get("product_code")) or {}
        row = {
            "product_code": price.get("product_code"),
            "product_name": product.get("name") or price.get("product_code"),
            "channel_code": channel.get("code"),
            "account_code": account.get("code"),
            "account_name": account.get("name"),
            "environment": account.get("environment"),
            "discount_mode": price.get("discount_mode") or "none",
            "discount_code": code,
            "configured": bool(code),
            "valid": False,
            "expired": False,
            "expires_at": None,
            "checked_at": now.isoformat(),
        }
        if not code:
            rows.append({**row, "reason": "empty_code"})
            continue
        cache_key = (price.get("account_code") or "", code)
        cached = seen_codes.get(cache_key)
        if cached:
            rows.append({**row, **cached})
            continue
        try:
            profile, adapter = await _payment_context_for_account({**account, "provider_code": "creem", "channel_code": channel.get("code")})
            if not adapter.supports_discount_codes:
                status_row = {"reason": "unsupported_provider"}
            else:
                status = await adapter.discount_by_code(code)
                expires_at = status.get("expires_at") or status.get("valid_until")
                expires_dt = _dt_from_creem(expires_at)
                expired = bool(expires_dt and expires_dt <= now)
                status_row = {
                    **{k: v for k, v in status.items() if k != "raw"},
                    "discount_code": status.get("discount_code") or code,
                    "valid": bool(status.get("valid")) and not expired,
                    "expired": expired,
                    "expires_at": expires_dt.isoformat() if expires_dt else expires_at,
                }
        except Exception as exc:
            status_row = {"reason": "query_failed", "error": str(exc)}
        seen_codes[cache_key] = status_row
        rows.append({**row, **status_row})
    return {"items": rows, "checked_at": now.isoformat()}


@router.get("/admin/orders")
async def admin_orders(
    page: int = 1,
    page_size: int = 20,
    status: str = "",
    email: str = "",
    _: None = Security(verify_callback_key),
):
    db = get_main_db()
    query: dict[str, Any] = {}
    if status:
        query["status"] = status
    if email:
        query["user_email"] = {"$regex": re.escape(email), "$options": "i"}
    page = max(1, int(page or 1))
    page_size = min(100, max(1, int(page_size or 20)))
    total = await db["payment_orders"].count_documents(query)
    rows = await db["payment_orders"].find(query, {"raw_event": 0}).sort("created_at", -1).skip((page - 1) * page_size).limit(page_size).to_list(length=page_size)
    for row in rows:
        row["_id"] = str(row["_id"])
    return {"items": rows, "total": total, "page": page, "page_size": page_size}


@router.get("/admin/orders/{order_id}")
async def admin_order_detail(order_id: str, _: None = Security(verify_callback_key)):
    db = get_main_db()
    order = await db["payment_orders"].find_one({"order_id": order_id})
    if not order:
        raise HTTPException(status_code=404, detail="订单不存在")
    attempts = await db["payment_attempts"].find({"order_id": order_id}).sort("created_at", -1).to_list(length=50)
    transactions = await db["payment_transactions"].find({"order_id": order_id}).sort("created_at", -1).to_list(length=50)
    refunds = await db["payment_refunds"].find({"order_id": order_id}).sort("created_at", -1).to_list(length=50)
    for rows in ([order], attempts, transactions, refunds):
        for row in rows:
            row["_id"] = str(row["_id"])
    return {"order": order, "attempts": attempts, "transactions": transactions, "refunds": refunds}


@router.get("/admin/transactions")
async def admin_transactions(
    page: int = 1,
    page_size: int = 20,
    provider: str = "",
    email: str = "",
    _: None = Security(verify_callback_key),
):
    db = get_main_db()
    query: dict[str, Any] = {}
    if provider:
        query["provider"] = provider
    if email:
        query["user_email"] = {"$regex": re.escape(email), "$options": "i"}
    page = max(1, int(page or 1))
    page_size = min(100, max(1, int(page_size or 20)))
    total = await db["payment_callback_events"].count_documents(query)
    rows = await db["payment_callback_events"].find(query).sort("created_at", -1).skip((page - 1) * page_size).limit(page_size).to_list(length=page_size)
    for row in rows:
        row["_id"] = str(row["_id"])
    return {"items": rows, "total": total, "page": page, "page_size": page_size}


@router.get("/admin/refunds")
async def admin_refunds(
    page: int = 1,
    page_size: int = 20,
    status: str = "",
    email: str = "",
    _: None = Security(verify_callback_key),
):
    db = get_main_db()
    query: dict[str, Any] = {}
    if status:
        query["status"] = status
    if email:
        query["user_email"] = {"$regex": re.escape(email), "$options": "i"}
    page = max(1, int(page or 1))
    page_size = min(100, max(1, int(page_size or 20)))
    total = await db["payment_refunds"].count_documents(query)
    rows = await db["payment_refunds"].find(query).sort("created_at", -1).skip((page - 1) * page_size).limit(page_size).to_list(length=page_size)
    for row in rows:
        row["_id"] = str(row["_id"])
    return {"items": rows, "total": total, "page": page, "page_size": page_size}


@router.get("/admin/refunds/{refund_id}")
async def admin_refund_detail(refund_id: str, _: None = Security(verify_callback_key)):
    db = get_main_db()
    refund = await db["payment_refunds"].find_one({"refund_id": refund_id})
    if not refund:
        raise HTTPException(status_code=404, detail="退款记录不存在")
    order = await db["payment_orders"].find_one({"order_id": refund.get("order_id")}) if refund.get("order_id") else None
    event = await db["payment_callback_events"].find_one({"payment_event_id": refund.get("payment_event_id")}) if refund.get("payment_event_id") else None
    for row in (refund, order, event):
        if row and row.get("_id"):
            row["_id"] = str(row["_id"])
    return {"refund": refund, "order": order, "payment_event": event}


@router.post("/admin/orders/{order_id}/refund")
async def admin_order_refund(order_id: str, data: ManualRefundRequest, _: None = Security(verify_callback_key)):
    db = get_main_db()
    order = await db["payment_orders"].find_one({"order_id": order_id})
    if not order:
        raise HTTPException(status_code=404, detail="订单不存在")
    if order.get("status") not in {"paid", "refunding", "partially_refunded"}:
        raise HTTPException(status_code=400, detail="仅已支付订单允许退款")
    now = datetime.now(timezone.utc)
    event = await _original_payment_event_for_order(db, order)
    amount, refundable, calculation = await _resolve_refund_amount(db, order, data, event, now)
    refund_id = f"manual_refund_{uuid4().hex}"
    config = await load_billing_config()
    account = _channel_account_for_order(config, order)
    profile, adapter = await _payment_context_for_account(account)
    reason_info = _refund_reason(data)
    doc = {
        "refund_id": refund_id,
        "order_id": order_id,
        "user_email": order.get("user_email"),
        "provider": order.get("provider"),
        "payment_channel": order.get("payment_channel"),
        "payment_event_id": event.get("payment_event_id") if event else "",
        "payment_order_id": event.get("payment_order_id") if event else order_id,
        "provider_payment_id": event.get("provider_payment_id") if event else "",
        "refund_mode": (data.refund_mode or REFUND_MODE_FULL).strip().lower(),
        "amount_cents": amount,
        "refundable_cents_before": refundable,
        "currency": order.get("currency") or "",
        "status": "processing",
        **reason_info,
        "revoke_entitlement": bool(data.revoke_entitlement),
        "calculation": calculation,
        "created_at": now,
        "updated_at": now,
    }
    await db["payment_refunds"].insert_one(dict(doc))
    await db["payment_orders"].update_one(
        {"order_id": order_id},
        {"$set": {"status": "refunding", "refund_status": "processing", "updated_at": now}},
    )
    try:
        provider_refund = await adapter.refund_payment(
            payment_order_id=doc["payment_order_id"] or order_id,
            provider_payment_id=doc["provider_payment_id"],
            amount_cents=amount,
            currency=doc["currency"],
            reason=doc["reason"],
            refund_id=refund_id,
        )
        user = await db["users"].find_one({"email": order.get("user_email")})
        subscription_id = _provider_subscription_id(order, event, user)
        cancel_result = {}
        if order.get("provider") == "creem" and subscription_id:
            try:
                # 退款场景语义为立即终止订阅(权益同步收回),不同于用户取消续费的周期末取消
                cancel_result = await adapter.cancel_subscription(subscription_id, mode="immediate")
            except HTTPException as exc:
                cancel_result = {"status": "failed", "detail": exc.detail}
        business_result = await _apply_refund_business_effects(db, order, event, doc, now)
        total_refunded = await _refunded_amount_for_order(db, order_id)
        paid_amount = _int_cents(order.get("paid_amount_cents") or order.get("amount_cents"))
        order_refund_status = "refunded" if total_refunded >= paid_amount else "partially_refunded"
        await db["payment_refunds"].update_one({"refund_id": refund_id}, {"$set": {
            "status": order_refund_status,
            "provider_refund_id": provider_refund.get("provider_refund_id") or refund_id,
            "provider_refund_status": provider_refund.get("status") or "",
            "provider_refund_result": provider_refund,
            "provider_cancel_result": cancel_result,
            "business_result": business_result,
            "updated_at": datetime.now(timezone.utc),
        }})
        await db["payment_orders"].update_one({"order_id": order_id}, {"$set": {
            "status": order_refund_status,
            "refund_status": order_refund_status,
            "refunded_amount_cents": total_refunded,
            "updated_at": datetime.now(timezone.utc),
        }})
        if event:
            await db["payment_callback_events"].update_one({"payment_event_id": event["payment_event_id"]}, {"$inc": {"refunded_cents": amount}, "$set": {
                "refund_status": order_refund_status,
                "updated_at": datetime.now(timezone.utc),
            }})
        doc.update({
            "status": order_refund_status,
            "provider_refund_id": provider_refund.get("provider_refund_id") or refund_id,
            "provider_refund_status": provider_refund.get("status") or "",
            "provider_refund_result": provider_refund,
            "provider_cancel_result": cancel_result,
            "business_result": business_result,
        })
    except Exception as exc:
        detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
        await db["payment_refunds"].update_one({"refund_id": refund_id}, {"$set": {
            "status": "failed",
            "error": detail,
            "updated_at": datetime.now(timezone.utc),
        }})
        await db["payment_orders"].update_one({"order_id": order_id}, {"$set": {
            "status": "paid",
            "refund_status": "failed",
            "updated_at": datetime.now(timezone.utc),
        }})
        raise HTTPException(status_code=502, detail={"message": "退款执行失败", "error": detail})
    doc.pop("_id", None)
    return {"message": "退款已提交并完成业务处理", "refund": doc}


