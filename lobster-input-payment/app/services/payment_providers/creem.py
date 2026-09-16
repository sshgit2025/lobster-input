import hmac
import json
from hashlib import sha256
from typing import Any

import httpx
from cachetools import TTLCache
from fastapi import HTTPException

from app.services.webhook import ingest as webhook_ingest
from app.services.billing.config import load_billing_config, products_by_code
from app.services.billing.enums import (
    CHARGE_TYPE_AUTO_RENEWAL,
    CHARGE_TYPE_MANUAL_PURCHASE,
    SETTLEMENT_FULL_PRICE,
)
from app.services.payment_providers.base import PaymentProduct, PaymentProviderAdapter
from app.services.payment_providers.webhook import NormalizedWebhookEvent, WebhookEventKind


CREEM_HEADERS = {"User-Agent": "LobsterInputPayment/1.0"}
PRODUCT_CATALOG_CACHE_TTL_SECONDS = 30 * 60
_PRODUCT_CATALOG_CACHE: TTLCache[str, dict[str, PaymentProduct]] = TTLCache(
    maxsize=64,
    ttl=PRODUCT_CATALOG_CACHE_TTL_SECONDS,
)


class CreemPaymentProviderAdapter(PaymentProviderAdapter):
    code = "creem"
    display_name = "Creem"

    # 国际卡,平台托管订阅:支持代扣续费、折扣券补差价、自助管理页、程序化退款;外部商品制。
    supports_recurring = True
    supports_discount_codes = True
    supports_customer_portal = True
    supports_refund_api = True
    order_mode = "external_product"

    async def products_by_id(self) -> dict[str, PaymentProduct]:
        cache_key = self._catalog_cache_key()
        cached = _PRODUCT_CATALOG_CACHE.get(cache_key)
        if cached is not None:
            return dict(cached)
        api_key = self.config.get("api_key") or ""
        api_base_url = (self.config.get("api_base_url") or "").rstrip("/")
        if not api_key or not api_base_url:
            raise HTTPException(status_code=503, detail="Creem API key is not configured")
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.get(
                f"{api_base_url}/v1/products/search",
                headers={**CREEM_HEADERS, "x-api-key": api_key},
            )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail={
                    "message": "Creem 商品列表读取失败",
                    "creem_status": response.status_code,
                    "creem_body": response.text[:1000],
                },
            )
        payload = response.json()
        items = payload.get("items") if isinstance(payload, dict) else payload
        products: dict[str, PaymentProduct] = {}
        for item in items or []:
            product = self._normalize_product(item)
            if product:
                products[product.product_id] = product
        _PRODUCT_CATALOG_CACHE[cache_key] = products
        return dict(products)

    async def discount_by_code(self, discount_code: str) -> dict[str, Any]:
        api_key = self.config.get("api_key") or ""
        api_base_url = (self.config.get("api_base_url") or "").rstrip("/")
        code = str(discount_code or "").strip()
        if not api_key or not api_base_url:
            raise HTTPException(status_code=503, detail="Creem API key is not configured")
        if not code:
            return {"configured": False, "valid": False, "reason": "empty_code"}
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.get(
                f"{api_base_url}/v1/discounts",
                headers={**CREEM_HEADERS, "x-api-key": api_key},
                params={"discount_code": code},
            )
        if response.status_code == 404:
            return {"configured": True, "valid": False, "reason": "not_found", "discount_code": code}
        if response.status_code >= 400:
            return {
                "configured": True,
                "valid": False,
                "reason": "api_error",
                "discount_code": code,
                "creem_status": response.status_code,
                "creem_body": response.text[:1000],
            }
        return self._normalize_discount_response(code, response.json())

    async def create_checkout(
        self,
        *,
        product_id: str,
        request_id: str,
        user_email: str,
        success_url: str,
        notify_url: str = "",
        product_name: str = "",
        amount_cents: int = 0,
        currency: str = "",
        payment_method: str = "",
        discount_code: str = "",
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        api_key = self.config.get("api_key") or ""
        api_base_url = (self.config.get("api_base_url") or "").rstrip("/")
        if not api_key or not api_base_url:
            raise HTTPException(status_code=503, detail="Creem API key is not configured")
        payload: dict[str, Any] = {
            "product_id": product_id,
            "request_id": request_id,
            "success_url": success_url,
            "customer": {"email": user_email},
            "metadata": metadata or {},
        }
        if discount_code:
            payload["discount_code"] = discount_code
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.post(
                f"{api_base_url}/v1/checkouts",
                headers={**CREEM_HEADERS, "x-api-key": api_key, "Content-Type": "application/json"},
                json=payload,
            )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail={
                    "message": "Creem checkout 创建失败",
                    "creem_status": response.status_code,
                    "creem_body": response.text[:1000],
                },
            )
        return response.json()

    async def create_discount(
        self,
        *,
        code: str,
        amount_cents: int,
        currency: str,
        applies_to_product_ids: list[str],
        expiry_date: str = "",
        max_redemptions: int = 1,
        name: str = "",
    ) -> dict[str, Any]:
        """创建一次性固定金额折扣券(套餐升级补差价用)。

        Creem 固定价商品无法按任意金额下单,补差价通过 type=fixed / duration=once 的
        一次性折扣券实现;max_redemptions=1 + 短 expiry_date + applies_to_products 三重
        锁定,券只能被指定商品核销一次、且很快过期,杜绝复用。
        """
        api_key = self.config.get("api_key") or ""
        api_base_url = (self.config.get("api_base_url") or "").rstrip("/")
        if not api_key or not api_base_url:
            raise HTTPException(status_code=503, detail="Creem API key is not configured")
        if amount_cents <= 0:
            raise HTTPException(status_code=400, detail="折扣金额必须大于 0")
        if not applies_to_product_ids:
            raise HTTPException(status_code=400, detail="折扣券必须限定适用商品,禁止无限制券")
        # Creem 约束:name ≤ 40 字符、code ≤ 14 字符,超限会 400。此处防御性截断。
        payload: dict[str, Any] = {
            "name": (name or f"Upgrade proration {code}")[:40],
            "type": "fixed",
            "duration": "once",
            "amount": int(amount_cents),
            "currency": (currency or "USD").upper(),
            "max_redemptions": int(max_redemptions),
            "applies_to_products": list(applies_to_product_ids),
        }
        if code:
            payload["code"] = code[:14]
        if expiry_date:
            payload["expiry_date"] = expiry_date
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.post(
                f"{api_base_url}/v1/discounts",
                headers={**CREEM_HEADERS, "x-api-key": api_key, "Content-Type": "application/json"},
                json=payload,
            )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail={
                    "message": "Creem 折扣创建失败",
                    "creem_status": response.status_code,
                    "creem_body": response.text[:1000],
                },
            )
        data = response.json()
        return {
            "discount_id": data.get("id") or "",
            "code": data.get("code") or code,
            "raw": data,
        }

    async def delete_discount(self, discount_id: str) -> dict[str, Any]:
        """删除折扣券(升级支付完成后清理;非关键路径,失败可忽略,券本身已单次+过期锁定)。"""
        api_key = self.config.get("api_key") or ""
        api_base_url = (self.config.get("api_base_url") or "").rstrip("/")
        if not api_key or not api_base_url:
            return {"status": "skipped", "reason": "not_configured"}
        if not discount_id:
            return {"status": "skipped", "reason": "empty_id"}
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.delete(
                f"{api_base_url}/v1/discounts/{discount_id}/delete",
                headers={**CREEM_HEADERS, "x-api-key": api_key},
            )
        if response.status_code >= 400:
            return {"status": "failed", "creem_status": response.status_code, "creem_body": response.text[:500]}
        return {"status": "deleted", "discount_id": discount_id}

    async def refund_payment(
        self,
        *,
        payment_order_id: str,
        provider_payment_id: str,
        amount_cents: int,
        currency: str,
        reason: str = "",
        refund_id: str = "",
    ) -> dict[str, Any]:
        api_key = self.config.get("api_key") or ""
        api_base_url = (self.config.get("api_base_url") or "").rstrip("/")
        transaction_id = (provider_payment_id or "").strip()
        if not api_key or not api_base_url:
            raise HTTPException(status_code=503, detail="Creem API key is not configured")
        if not transaction_id:
            raise HTTPException(status_code=400, detail="Creem transaction id is required for refund")
        payload = {
            "transaction_id": transaction_id,
            "amount": int(amount_cents),
            "currency": (currency or "USD").upper(),
            "reason": (reason or "requested_by_customer")[:200],
            "request_id": refund_id,
        }
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{api_base_url}/v1/refunds",
                headers={**CREEM_HEADERS, "x-api-key": api_key, "Content-Type": "application/json"},
                json=payload,
            )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail={
                    "message": "Creem 退款创建失败",
                    "creem_status": response.status_code,
                    "creem_body": response.text[:1000],
                },
            )
        data = response.json()
        return {
            "provider_refund_id": data.get("id") or refund_id,
            "status": data.get("status") or "succeeded",
            "raw": data,
        }

    async def cancel_subscription(
        self,
        subscription_id: str,
        mode: str = "scheduled",
        on_execute: str = "cancel",
    ) -> dict[str, Any]:
        """取消 Creem 订阅。

        - mode="scheduled" + onExecute="cancel":周期末取消(用户「取消自动续费」的标准语义,
          已付周期权益保留到期末);
        - mode="immediate":立即取消(退款等管理场景),此时不传 onExecute。
        """
        api_key = self.config.get("api_key") or ""
        api_base_url = (self.config.get("api_base_url") or "").rstrip("/")
        if not api_key or not api_base_url:
            raise HTTPException(status_code=503, detail="Creem API key is not configured")
        if not subscription_id:
            raise HTTPException(status_code=400, detail="Creem subscription id is required")
        payload: dict[str, Any] = {"mode": (mode or "scheduled").strip().lower() or "scheduled"}
        if payload["mode"] != "immediate" and on_execute:
            payload["onExecute"] = on_execute
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{api_base_url}/v1/subscriptions/{subscription_id}/cancel",
                headers={**CREEM_HEADERS, "x-api-key": api_key, "Content-Type": "application/json"},
                json=payload,
            )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail={
                    "message": "Creem 订阅取消失败",
                    "creem_status": response.status_code,
                    "creem_body": response.text[:1000],
                },
            )
        return response.json()

    async def customer_portal_link(self, customer_id: str) -> str:
        """换取 Creem customer portal 链接(用户自助取消订阅/管理支付方式)。"""
        api_key = self.config.get("api_key") or ""
        api_base_url = (self.config.get("api_base_url") or "").rstrip("/")
        if not api_key or not api_base_url:
            raise HTTPException(status_code=503, detail="Creem API key is not configured")
        if not customer_id:
            raise HTTPException(status_code=400, detail="Creem customer id is required")
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{api_base_url}/v1/customers/billing",
                json={"customer_id": customer_id},
                headers={**CREEM_HEADERS, "x-api-key": api_key, "Content-Type": "application/json"},
            )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail={
                    "message": "Creem 管理页链接获取失败",
                    "creem_status": response.status_code,
                    "creem_body": response.text[:1000],
                },
            )
        data = response.json()
        link = str(data.get("customer_portal_link") or data.get("url") or "").strip()
        if not link:
            raise HTTPException(status_code=502, detail="Creem 未返回管理页链接")
        return link

    def verify_webhook_signature(self, raw_body: bytes, signature: str | None) -> None:
        secret = self.config.get("webhook_secret") or ""
        if not secret:
            raise HTTPException(status_code=503, detail="Creem webhook secret is not configured")
        if not signature:
            raise HTTPException(status_code=401, detail="Missing Creem signature")
        expected = hmac.new(secret.encode("utf-8"), raw_body, sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise HTTPException(status_code=401, detail="Invalid Creem signature")

    # ── webhook 规范化 ─────────────────────────────────────────────────
    webhook_signature_header = "creem-signature"

    def webhook_event_id(self, raw_body: bytes, request: Any) -> str:
        event = self._parse_event(raw_body)
        return str((event or {}).get("id") or "").strip() or webhook_ingest.synthetic_event_id(raw_body)

    @staticmethod
    def _parse_event(raw_body: bytes) -> dict[str, Any] | None:
        try:
            event = json.loads(raw_body.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None
        return event if isinstance(event, dict) else None

    async def _checkout_by_provider_object(self, db, obj: dict) -> dict | None:
        request_id = obj.get("request_id") or (obj.get("metadata") or {}).get("request_id")
        checkout_id = obj.get("id")
        conditions = []
        if request_id:
            conditions.append({"request_id": request_id})
        if checkout_id:
            conditions.append({"checkout_id": checkout_id})
        if not conditions:
            return None
        return await db["payment_checkout_sessions"].find_one({"$or": conditions})

    async def normalize_webhook_event(self, db: Any, raw_body: bytes, request: Any) -> NormalizedWebhookEvent:
        event = self._parse_event(raw_body)
        if event is None:
            raise HTTPException(status_code=400, detail="Invalid JSON")
        event_id = str(event.get("id") or "").strip()
        event_type = event.get("eventType") or event.get("event_type")
        obj = event.get("object") or {}
        if not event_id or not event_type:
            raise HTTPException(status_code=400, detail="Invalid creem event")

        if event_type == "checkout.completed":
            return await self._normalize_checkout_completed(db, event_id, event_type, obj, event)
        if event_type == "subscription.paid":
            return await self._normalize_subscription_paid(db, event_id, event_type, obj, event)
        if event_type in {"subscription.scheduled_cancel", "subscription.canceled", "subscription.past_due", "subscription.expired"}:
            return NormalizedWebhookEvent(
                kind=WebhookEventKind.SUBSCRIPTION_STATUS, event_id=event_id, provider=self.code,
                provider_event_type=event_type, status_change={"event_type": event_type, "object": obj}, raw=event,
            )
        return NormalizedWebhookEvent.ignored(
            event_id=event_id, provider=self.code, provider_event_type=event_type, raw=event,
        )

    async def _normalize_checkout_completed(self, db, event_id, event_type, obj, event) -> NormalizedWebhookEvent:
        checkout = await self._checkout_by_provider_object(db, obj)
        if not checkout or checkout.get("kind") != "credits_topup":
            # 订阅 checkout 的完成等 subscription.paid 处理,这里忽略
            return NormalizedWebhookEvent.ignored(
                event_id=event_id, provider=self.code, provider_event_type=event_type, raw=event,
            )
        product = obj.get("product") or {}
        product_id = product.get("id") or obj.get("product_id") or obj.get("product")
        order = obj.get("order") or {}
        customer = obj.get("customer") or {}
        return NormalizedWebhookEvent(
            kind=WebhookEventKind.TOPUP, event_id=event_id, provider=self.code, provider_event_type=event_type,
            topup={
                "payment_event_id": event_id,
                "user_email": checkout["user_email"],
                "amount": int(checkout.get("amount") or 0),
                "provider": self.code,
                "raw_event": event,
            },
            checkout=checkout,
            callback_event_updates={
                "payment_order_id": order.get("id") or event_id,
                "provider_payment_id": order.get("id") or "",
                "payment_channel": checkout.get("payment_channel") or self.code,
                "customer_id": customer.get("id") or "",
                "product_id": product_id,
            },
            raw=event,
        )

    async def _normalize_subscription_paid(self, db, event_id, event_type, obj, event) -> NormalizedWebhookEvent:
        product = obj.get("product") or {}
        product_id = product.get("id") or obj.get("product_id") or obj.get("product")
        customer = obj.get("customer") or {}
        metadata = obj.get("metadata") or {}
        email = metadata.get("user_email") or customer.get("email")
        if not email:
            raise HTTPException(status_code=400, detail="订阅事件缺少用户邮箱")
        checkout = None
        request_id = metadata.get("request_id")
        if request_id:
            checkout = await db["payment_checkout_sessions"].find_one({"request_id": request_id})
        if not checkout:
            checkout = await db["payment_checkout_sessions"].find_one({
                "provider": self.code,
                "kind": "subscription",
                "user_email": email,
                "product_id": product_id,
                "status": "pending",
            })
        if checkout:
            plan_code = checkout.get("plan_code")
            billing_cycle = checkout.get("billing_cycle")
        else:
            config = await load_billing_config()
            price_row = next((
                item for item in config.get("channel_prices") or []
                if item.get("external_product_id") == str(product_id or "") and item.get("enabled", True)
            ), None)
            product_row = products_by_code(config).get((price_row or {}).get("product_code", ""))
            if not product_row:
                return NormalizedWebhookEvent.ignored(
                    event_id=event_id, provider=self.code, provider_event_type=event_type, raw=event,
                )
            plan_code = product_row.get("plan_code")
            billing_cycle = product_row.get("billing_cycle")
        settlement_mode = (checkout or {}).get("settlement_mode") or metadata.get("settlement_mode") or SETTLEMENT_FULL_PRICE
        auto_renew = (checkout or {}).get("auto_renew")
        if auto_renew is None:
            auto_renew = True
        transaction_id = obj.get("last_transaction_id") or obj.get("transaction_id") or event_id
        # product.price 是商品目录全价,不是实际扣款额;折扣升级实付为差价。以服务端结账时算好的
        # payment_orders.amount_cents(实际应付/差价)为准记账,避免退款超额退、补差价 basis 放大;
        # order 缺失时回退全价(普通购买差价==全价)。
        paid_amount_cents = int(product.get("price") or 0)
        order_id_for_amount = (checkout or {}).get("order_id")
        if order_id_for_amount:
            order_row = await db["payment_orders"].find_one({"order_id": order_id_for_amount})
            if order_row and order_row.get("amount_cents") is not None:
                paid_amount_cents = int(order_row.get("amount_cents") or 0)
        return NormalizedWebhookEvent(
            kind=WebhookEventKind.SUBSCRIPTION_PAYMENT, event_id=event_id, provider=self.code,
            provider_event_type=event_type,
            subscription={
                "payment_event_id": f"creem:{transaction_id}",
                "user_email": email,
                "plan_code": plan_code,
                "billing_cycle": billing_cycle,
                "provider": self.code,
                "settlement_mode": settlement_mode,
                "paid_amount_cents": paid_amount_cents,
                "payment_order_id": obj.get("id") or event_id,
                "provider_payment_id": transaction_id,
                "payment_channel": (checkout or {}).get("payment_channel") or self.code,
                "auto_renew": bool(auto_renew),
                "charge_type": CHARGE_TYPE_AUTO_RENEWAL if not checkout else CHARGE_TYPE_MANUAL_PURCHASE,
                "raw_event": event,
            },
            checkout=checkout,
            new_subscription_id=obj.get("id") or "",
            user_updates={
                "latest_provider_subscription_id": obj.get("id") or "",
                "latest_payment_customer_id": customer.get("id") or "",
            },
            raw=event,
        )

    def _catalog_cache_key(self) -> str:
        config_id = str(self.config.get("id") or "").strip()
        api_base_url = str(self.config.get("api_base_url") or "").strip().rstrip("/")
        return f"{self.code}:{config_id}:{api_base_url}"

    @staticmethod
    def _normalize_discount_response(code: str, payload: Any) -> dict[str, Any]:
        if isinstance(payload, dict):
            items = payload.get("items")
            if isinstance(items, list):
                item = next((row for row in items if isinstance(row, dict) and str(row.get("discount_code") or row.get("code") or "").strip().lower() == code.lower()), None)
                item = item or (items[0] if items else {})
            else:
                item = payload.get("discount") if isinstance(payload.get("discount"), dict) else payload
        elif isinstance(payload, list):
            item = next((row for row in payload if isinstance(row, dict) and str(row.get("discount_code") or row.get("code") or "").strip().lower() == code.lower()), None)
            item = item or (payload[0] if payload else {})
        else:
            item = {}
        if not isinstance(item, dict) or not item:
            return {"configured": True, "valid": False, "reason": "not_found", "discount_code": code, "raw": payload}
        status = str(item.get("status") or "").strip().lower()
        active_value = item.get("active")
        expires_at = item.get("expires_at") or item.get("expiration_date") or item.get("expiresAt") or item.get("expires_date")
        valid_until = item.get("valid_until") or item.get("validUntil") or expires_at
        is_active = bool(active_value) if active_value is not None else status not in {"inactive", "disabled", "expired", "archived"}
        return {
            "configured": True,
            "valid": is_active,
            "reason": "active" if is_active else (status or "inactive"),
            "discount_code": str(item.get("discount_code") or item.get("code") or code),
            "name": item.get("name") or "",
            "status": status,
            "active": is_active,
            "expires_at": expires_at,
            "valid_until": valid_until,
            "raw": item,
        }

    @staticmethod
    def _normalize_product(item: Any) -> PaymentProduct | None:
        if not isinstance(item, dict) or not item.get("id"):
            return None
        try:
            price_cents = int(item.get("price"))
        except (TypeError, ValueError):
            price_cents = 0
        return PaymentProduct(
            product_id=str(item["id"]),
            name=item.get("name") or "",
            price_cents=max(0, price_cents),
            currency=str(item.get("currency") or "").upper() or "USD",
            billing_type=item.get("billing_type") or "",
            billing_period=item.get("billing_period") or "",
            status=item.get("status") or "",
        )
