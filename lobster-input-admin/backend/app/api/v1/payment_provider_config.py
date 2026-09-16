import hmac
import json
import time
from hashlib import sha256
from typing import Any
from urllib.parse import urlencode, urljoin

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from app.api.v1.deps import get_current_admin
from app.services.payment_runtime_config import load_payment_runtime_config

router = APIRouter(prefix="/api/v1/payment-provider-config", tags=["payment-provider-config"])


class BillingConfigRequest(BaseModel):
    products: list[dict[str, Any]] = Field(default_factory=list)
    currencies: list[dict[str, Any]] = Field(default_factory=list)
    payment_methods: list[dict[str, Any]] = Field(default_factory=list)
    channels: list[dict[str, Any]] = Field(default_factory=list)
    channel_prices: list[dict[str, Any]] = Field(default_factory=list)
    exchange_rate_provider: dict[str, Any] = Field(default_factory=dict)


class ManualRefundRequest(BaseModel):
    refund_mode: str = "full"
    amount_cents: int | None = None
    reason_code: str = "admin_adjustment"
    reason: str = ""
    reason_note: str = ""
    revoke_entitlement: bool = True


def _signed_headers(method: str, path: str, query: str, body: bytes, internal_key: str) -> dict[str, str]:
    timestamp = str(int(time.time()))
    payload = b"\n".join([
        method.upper().encode("utf-8"),
        path.encode("utf-8"),
        query.encode("utf-8"),
        timestamp.encode("utf-8"),
        body,
    ])
    signature = hmac.new(internal_key.encode("utf-8"), payload, sha256).hexdigest()
    return {
        "X-API-Key": internal_key,
        "X-Callback-Timestamp": timestamp,
        "X-Callback-Signature": signature,
        "Content-Type": "application/json",
    }


async def _request_payment_service(method: str, path: str, payload: dict | None = None, query: dict[str, Any] | None = None) -> dict:
    runtime_config = await load_payment_runtime_config()
    service_url = runtime_config["service_url"]
    internal_key = runtime_config["callback_internal_key"]
    if not service_url or not internal_key:
        raise HTTPException(status_code=503, detail="支付服务未配置")
    query_text = urlencode({k: v for k, v in (query or {}).items() if v is not None and v != ""})
    body = b"" if payload is None else json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    headers = _signed_headers(method, path, query_text, body, internal_key)
    url = urljoin(service_url.rstrip("/") + "/", path.lstrip("/"))
    if query_text:
        url = f"{url}?{query_text}"
    async with httpx.AsyncClient(timeout=20.0) as client:
        response = await client.request(method, url, content=body, headers=headers)
    if response.status_code >= 400:
        try:
            detail = response.json()
        except Exception:
            detail = response.text
        raise HTTPException(status_code=response.status_code, detail=detail)
    return response.json()


@router.get("")
async def get_payment_provider_config(_: str = Depends(get_current_admin)):
    return await _request_payment_service("GET", "/api/v1/payments/admin/config")


@router.post("")
async def save_payment_provider_config(data: BillingConfigRequest, _: str = Depends(get_current_admin)):
    payload = data.model_dump() if hasattr(data, "model_dump") else data.dict()
    return await _request_payment_service("POST", "/api/v1/payments/admin/config", payload)


@router.get("/discounts/status")
async def payment_discount_status(_: str = Depends(get_current_admin)):
    return await _request_payment_service("GET", "/api/v1/payments/admin/discounts/status")


@router.get("/orders")
async def payment_orders(
    page: int = 1,
    page_size: int = 20,
    status: str = "",
    email: str = "",
    _: str = Depends(get_current_admin),
):
    return await _request_payment_service(
        "GET",
        "/api/v1/payments/admin/orders",
        query={"page": page, "page_size": page_size, "status": status, "email": email},
    )


@router.get("/orders/{order_id}")
async def payment_order_detail(order_id: str, _: str = Depends(get_current_admin)):
    return await _request_payment_service("GET", f"/api/v1/payments/admin/orders/{order_id}")


@router.get("/transactions")
async def payment_transactions(
    page: int = 1,
    page_size: int = 20,
    provider: str = "",
    email: str = "",
    _: str = Depends(get_current_admin),
):
    return await _request_payment_service(
        "GET",
        "/api/v1/payments/admin/transactions",
        query={"page": page, "page_size": page_size, "provider": provider, "email": email},
    )


@router.get("/refunds")
async def payment_refunds(
    page: int = 1,
    page_size: int = 20,
    status: str = "",
    email: str = "",
    _: str = Depends(get_current_admin),
):
    return await _request_payment_service(
        "GET",
        "/api/v1/payments/admin/refunds",
        query={"page": page, "page_size": page_size, "status": status, "email": email},
    )


@router.get("/refunds/{refund_id}")
async def payment_refund_detail(refund_id: str, _: str = Depends(get_current_admin)):
    return await _request_payment_service("GET", f"/api/v1/payments/admin/refunds/{refund_id}")


@router.post("/orders/{order_id}/refund")
async def payment_order_refund(order_id: str, data: ManualRefundRequest, _: str = Depends(get_current_admin)):
    payload = data.model_dump() if hasattr(data, "model_dump") else data.dict()
    return await _request_payment_service("POST", f"/api/v1/payments/admin/orders/{order_id}/refund", payload)
