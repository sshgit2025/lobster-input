import hmac
from hashlib import md5
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import httpx
from fastapi import HTTPException

from app.services.webhook import ingest as webhook_ingest
from app.services.billing.enums import CHARGE_TYPE_MANUAL_PURCHASE, SETTLEMENT_FULL_PRICE
from app.services.payment_providers.base import PaymentProduct, PaymentProviderAdapter
from app.services.payment_providers.webhook import NormalizedWebhookEvent, WebhookEventKind


ZPAY_METHOD_TYPES = {
    "wechat": "wxpay",
    "alipay": "alipay",
}


class ZPayPaymentProviderAdapter(PaymentProviderAdapter):
    code = "zpay"
    display_name = "ZPay"

    # 易支付协议(微信/支付宝):无代扣能力、无折扣券、无托管管理页;动态金额制,人民币。
    # capability 全部沿用基类默认 False;order_mode 显式声明动态金额。
    supports_recurring = False
    supports_discount_codes = False
    supports_customer_portal = False
    order_mode = "amount_order"

    async def products_by_id(self) -> dict[str, PaymentProduct]:
        return {}

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
        api_base_url = (self.config.get("api_base_url") or "").strip().rstrip("/")
        merchant_id = str(self.config.get("merchant_id") or self.config.get("pid") or "").strip()
        api_key = str(self.config.get("api_key") or "").strip()
        if not api_base_url or not merchant_id or not api_key:
            raise HTTPException(status_code=503, detail="ZPay merchant id or key is not configured")
        if currency and str(currency).upper() != "CNY":
            raise HTTPException(status_code=400, detail="ZPay 仅支持 CNY 金额下单")
        if amount_cents <= 0:
            raise HTTPException(status_code=400, detail="ZPay 下单金额必须大于 0")
        pay_type = ZPAY_METHOD_TYPES.get(str(payment_method or "").strip().lower())
        if not pay_type:
            raise HTTPException(status_code=400, detail="ZPay 暂不支持该支付方式")

        params = {
            "pid": merchant_id,
            "type": pay_type,
            "out_trade_no": request_id,
            "notify_url": notify_url,
            "return_url": self._strip_query(success_url),
            "name": (product_name or product_id or "Lobster Input")[:100],
            "money": f"{amount_cents / 100:.2f}",
            "sitename": "Lobster Input",
            "sign_type": "MD5",
        }
        params["sign"] = self.sign(params)
        return {
            "id": request_id,
            "checkout_url": f"{api_base_url}/submit.php?{urlencode(params)}",
            "status": "pending",
            "provider": self.code,
            "payment_type": pay_type,
            "out_trade_no": request_id,
        }

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
        api_base_url = (self.config.get("api_base_url") or "").strip().rstrip("/")
        merchant_id = str(self.config.get("merchant_id") or self.config.get("pid") or "").strip()
        api_key = str(self.config.get("api_key") or "").strip()
        if not api_base_url or not merchant_id or not api_key:
            raise HTTPException(status_code=503, detail="ZPay merchant id or key is not configured")
        if currency and str(currency).upper() != "CNY":
            raise HTTPException(status_code=400, detail="ZPay 仅支持 CNY 退款")
        if amount_cents <= 0:
            raise HTTPException(status_code=400, detail="ZPay 退款金额必须大于 0")
        payload = {
            "act": "refund",
            "pid": merchant_id,
            "key": api_key,
            "money": f"{amount_cents / 100:.2f}",
        }
        if provider_payment_id:
            payload["trade_no"] = provider_payment_id
        if payment_order_id:
            payload["out_trade_no"] = payment_order_id
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(f"{api_base_url}/api.php?act=refund", data=payload)
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail={
                    "message": "ZPay 退款请求失败",
                    "zpay_status": response.status_code,
                    "zpay_body": response.text[:1000],
                },
            )
        data = response.json()
        if str(data.get("code")) not in {"1", "success", "SUCCESS"}:
            raise HTTPException(status_code=502, detail={"message": "ZPay 退款失败", "zpay_body": data})
        return {
            "provider_refund_id": refund_id,
            "status": "succeeded",
            "raw": data,
        }

    def verify_webhook_signature(self, raw_body: bytes, signature: str | None) -> None:
        params = self.parse_notification(raw_body)
        provided = str(params.get("sign") or "")
        if not provided:
            raise HTTPException(status_code=401, detail="Missing ZPay signature")
        expected = self.sign(params)
        if not hmac.compare_digest(provided.lower(), expected.lower()):
            raise HTTPException(status_code=401, detail="Invalid ZPay signature")

    # ── webhook 规范化 ─────────────────────────────────────────────────
    # ZPay 易支付协议:签名在表单/查询串内(不在 header),GET 回调需从 query 取 body;应答固定纯文本 "success"。
    webhook_ack_text = "success"
    ZPAY_SUCCESS_STATUSES = {"TRADE_SUCCESS", "TRADE_FINISHED", "SUCCESS"}

    def webhook_verify_body(self, raw_body: bytes, request: Any) -> bytes:
        if raw_body:
            return raw_body
        return str(request.url.query).encode("utf-8")

    def webhook_ingest_raw(self, raw_body: bytes, request: Any) -> dict[str, Any]:
        return {"params": self.parse_notification(self.webhook_verify_body(raw_body, request))}

    def rebuild_webhook_body(self, raw: dict[str, Any]) -> bytes:
        # 存档的 ZPay 事件 raw 形如 {"params": {...}};重放时还原为查询串 body
        params = (raw or {}).get("params") or {}
        return urlencode({str(key): str(value) for key, value in params.items()}).encode("utf-8")

    def webhook_event_id(self, raw_body: bytes, request: Any) -> str:
        body = self.webhook_verify_body(raw_body, request)
        params = self.parse_notification(body)
        out_trade_no = str(params.get("out_trade_no") or "").strip()
        trade_status = str(params.get("trade_status") or "").strip().upper()
        if not out_trade_no:
            return webhook_ingest.synthetic_event_id(body)
        return f"{out_trade_no}:{trade_status}"

    async def normalize_webhook_event(self, db: Any, raw_body: bytes, request: Any) -> NormalizedWebhookEvent:
        body = self.webhook_verify_body(raw_body, request)
        params = self.parse_notification(body)
        out_trade_no = str(params.get("out_trade_no") or "").strip()
        trade_no = str(params.get("trade_no") or "").strip()
        trade_status = str(params.get("trade_status") or "").strip().upper()
        ingest_id = f"{out_trade_no}:{trade_status}" if out_trade_no else webhook_ingest.synthetic_event_id(body)
        if not out_trade_no:
            raise HTTPException(status_code=400, detail="ZPay 通知缺少商户订单号")
        if trade_status and trade_status not in self.ZPAY_SUCCESS_STATUSES:
            return NormalizedWebhookEvent.ignored(
                event_id=ingest_id, provider=self.code, provider_event_type=trade_status, raw={"params": params},
            )
        checkout = await db["payment_checkout_sessions"].find_one({"request_id": out_trade_no})
        if not checkout:
            raise HTTPException(status_code=404, detail="ZPay checkout 不存在")
        payment_event_id = f"zpay:{trade_no or out_trade_no}"
        raw_event = {"provider": self.code, "params": params}
        try:
            paid_amount_cents = int(round(float(params.get("money") or 0) * 100))
        except (TypeError, ValueError):
            paid_amount_cents = 0
        callback_event_updates = {
            "payment_order_id": out_trade_no,
            "provider_payment_id": trade_no,
            "payment_channel": checkout.get("payment_channel") or self.code,
        }
        if checkout.get("kind") == "subscription":
            return NormalizedWebhookEvent(
                kind=WebhookEventKind.SUBSCRIPTION_PAYMENT, event_id=ingest_id, provider=self.code,
                provider_event_type=trade_status,
                subscription={
                    "payment_event_id": payment_event_id,
                    "user_email": checkout["user_email"],
                    "plan_code": checkout["plan_code"],
                    "billing_cycle": checkout["billing_cycle"],
                    "provider": self.code,
                    "settlement_mode": checkout.get("settlement_mode") or SETTLEMENT_FULL_PRICE,
                    "paid_amount_cents": paid_amount_cents,
                    "payment_order_id": out_trade_no,
                    "provider_payment_id": trade_no,
                    "payment_channel": checkout.get("payment_channel") or self.code,
                    "auto_renew": bool(checkout.get("auto_renew")),
                    "charge_type": CHARGE_TYPE_MANUAL_PURCHASE,
                    "raw_event": raw_event,
                },
                checkout=checkout,
                new_subscription_id="",  # ZPay 无托管订阅 id;换渠道时由分发层触发取消旧代扣
                callback_event_updates=callback_event_updates,
                raw=raw_event,
            )
        if checkout.get("kind") == "credits_topup":
            return NormalizedWebhookEvent(
                kind=WebhookEventKind.TOPUP, event_id=ingest_id, provider=self.code, provider_event_type=trade_status,
                topup={
                    "payment_event_id": payment_event_id,
                    "user_email": checkout["user_email"],
                    "amount": int(checkout.get("amount") or 0),
                    "provider": self.code,
                    "raw_event": raw_event,
                },
                checkout=checkout,
                callback_event_updates=callback_event_updates,
                result_overrides={"paid_amount_cents": paid_amount_cents},
                raw=raw_event,
            )
        raise HTTPException(status_code=400, detail="ZPay checkout 类型不合法")

    def sign(self, params: dict[str, Any]) -> str:
        api_key = str(self.config.get("api_key") or "").strip()
        if not api_key:
            raise HTTPException(status_code=503, detail="ZPay key is not configured")
        pieces = []
        for key in sorted(params.keys()):
            if key in {"sign", "sign_type"}:
                continue
            value = params.get(key)
            if value is None or value == "":
                continue
            pieces.append(f"{key}={value}")
        return md5(("&".join(pieces) + api_key).encode("utf-8")).hexdigest()

    @staticmethod
    def parse_notification(raw_body: bytes) -> dict[str, str]:
        text = raw_body.decode("utf-8", errors="ignore")
        return {key: value for key, value in parse_qsl(text, keep_blank_values=True)}

    @staticmethod
    def _strip_query(url: str) -> str:
        parts = urlsplit(url)
        return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
