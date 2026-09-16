"""计费目录(Catalog)与 Webhook 事件管理代理接口。

登录态鉴权沿用管理端 get_current_admin;内部复用
payment_provider_config._request_payment_service 的 HMAC 签名转发到支付服务:
- /api/v1/billing-catalog/*  → /api/v1/payments/admin/catalog/*
- /api/v1/webhook-events/*   → /api/v1/payments/admin/webhook-events/*
"""

from typing import Any

from fastapi import APIRouter, Body, Depends, Query

from app.api.v1.deps import get_current_admin
from app.api.v1.payment_provider_config import _request_payment_service

router = APIRouter(prefix="/api/v1/billing-catalog", tags=["billing-catalog"])
webhook_router = APIRouter(prefix="/api/v1/webhook-events", tags=["webhook-events"])

_CATALOG = "/api/v1/payments/admin/catalog"
_WEBHOOK = "/api/v1/payments/admin/webhook-events"


# ---------------------------------------------------------------------------
# 计费目录:套餐(plans)
# ---------------------------------------------------------------------------


@router.get("/plans")
async def catalog_list_plans(_: str = Depends(get_current_admin)):
    return await _request_payment_service("GET", f"{_CATALOG}/plans")


@router.post("/plans")
async def catalog_upsert_plan(
    data: dict[str, Any] = Body(...),
    _: str = Depends(get_current_admin),
):
    """只需传要变更的字段(必含 plan_code),返回 plan + impact_hints。"""
    return await _request_payment_service("POST", f"{_CATALOG}/plans", data)


@router.post("/plans/{plan_code}/status")
async def catalog_set_plan_status(
    plan_code: str,
    data: dict[str, Any] = Body(...),
    _: str = Depends(get_current_admin),
):
    return await _request_payment_service("POST", f"{_CATALOG}/plans/{plan_code}/status", data)


# ---------------------------------------------------------------------------
# 计费目录:价格版本(prices)
# ---------------------------------------------------------------------------


@router.get("/prices")
async def catalog_list_prices(
    plan_code: str = "",
    _: str = Depends(get_current_admin),
):
    return await _request_payment_service("GET", f"{_CATALOG}/prices", query={"plan_code": plan_code})


@router.post("/prices")
async def catalog_create_price(
    data: dict[str, Any] = Body(...),
    _: str = Depends(get_current_admin),
):
    return await _request_payment_service("POST", f"{_CATALOG}/prices", data)


@router.post("/prices/{price_id}/archive")
async def catalog_archive_price(price_id: str, _: str = Depends(get_current_admin)):
    return await _request_payment_service("POST", f"{_CATALOG}/prices/{price_id}/archive")


@router.post("/prices/{price_id}/make-current")
async def catalog_make_price_current(price_id: str, _: str = Depends(get_current_admin)):
    return await _request_payment_service("POST", f"{_CATALOG}/prices/{price_id}/make-current")


# ---------------------------------------------------------------------------
# 计费目录:发布投影与审计
# ---------------------------------------------------------------------------


@router.post("/publish")
async def catalog_publish(
    dry_run: bool = Query(True, description="true=仅返回 diff;false=正式发布"),
    data: dict[str, Any] = Body(default={}),
    _: str = Depends(get_current_admin),
):
    return await _request_payment_service(
        "POST",
        f"{_CATALOG}/publish",
        data or {},
        query={"dry_run": "true" if dry_run else "false"},
    )


@router.get("/publish-log")
async def catalog_publish_log(
    limit: int = Query(50, ge=1, le=200),
    _: str = Depends(get_current_admin),
):
    return await _request_payment_service("GET", f"{_CATALOG}/publish-log", query={"limit": limit})


# ---------------------------------------------------------------------------
# Webhook 事件
# ---------------------------------------------------------------------------


@webhook_router.get("")
async def webhook_events(
    provider: str = "",
    status: str = "",
    page: int = 1,
    page_size: int = 20,
    _: str = Depends(get_current_admin),
):
    return await _request_payment_service(
        "GET",
        _WEBHOOK,
        query={"provider": provider, "status": status, "page": page, "page_size": page_size},
    )


@webhook_router.get("/{provider}/{event_id}")
async def webhook_event_detail(provider: str, event_id: str, _: str = Depends(get_current_admin)):
    return await _request_payment_service("GET", f"{_WEBHOOK}/{provider}/{event_id}")


@webhook_router.post("/{provider}/{event_id}/replay")
async def webhook_event_replay(provider: str, event_id: str, _: str = Depends(get_current_admin)):
    return await _request_payment_service("POST", f"{_WEBHOOK}/{provider}/{event_id}/replay")
