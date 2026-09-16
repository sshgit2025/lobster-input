"""套餐 / 订阅管理代理 API。

M2 归并:业务后端(lobster-input-backend)是套餐定义与订阅管理的唯一真源与唯一写入方。
本文件不再持有 DEFAULT_PLAN_CONFIGS / 清洗 / 日期 / 订阅激活到期重置等任何业务逻辑,
仅做「管理端登录态鉴权 + HMAC 转发」到业务后端 /api/v1/config/plan-admin/* 内部端点。
代理风格与 app/api/v1/billing_margin_admin.py 完全一致。

前端 PlansView / PlanAccountsView 仍调 /api/v1/plans/*,返回结构由后端端点保证一致。
"""
import hmac
import json
import time
from hashlib import sha256
from typing import Any, Optional
from urllib.parse import urlencode, urlsplit

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from app.api.v1.deps import get_current_admin
from app.core.config import settings

router = APIRouter(prefix="/api/v1/plans", tags=["plans"])

BACKEND_TIMEOUT = 30.0


class PlansConfigRequest(BaseModel):
    plan_configs: dict[str, Any]
    bonus_credit_policy: dict[str, Any]


class AssignPlanRequest(BaseModel):
    email: str
    plan_code: str
    billing_cycle: str = "monthly"
    change_mode: str = "activate_now"
    auto_renew: bool = False


class AutoRenewRequest(BaseModel):
    email: str
    auto_renew: bool


class GrantCompRequest(BaseModel):
    email: str
    plan_code: str
    start: Optional[str] = None
    end: Optional[str] = None
    reason: str = ""
    idempotency_key: Optional[str] = None


class RevokeEntitlementRequest(BaseModel):
    email: str
    to_free: bool = True
    reason: str = ""


def _backend_url(path: str) -> str:
    return f"{settings.BACKEND_URL.rstrip('/')}{path}"


def _headers(method: str, url: str, body: bytes = b"") -> dict:
    ts = str(int(time.time()))
    parsed = urlsplit(url)
    payload = b"\n".join([
        method.upper().encode("utf-8"),
        parsed.path.encode("utf-8"),
        parsed.query.encode("utf-8"),
        ts.encode("utf-8"),
        body,
    ])
    signature = hmac.new(settings.BACKEND_API_KEY.encode("utf-8"), payload, sha256).hexdigest()
    return {
        "X-API-Key": settings.BACKEND_API_KEY,
        "X-Internal-Timestamp": ts,
        "X-Internal-Signature": signature,
        "Content-Type": "application/json",
    }


def _extract_detail(resp: httpx.Response) -> Any:
    if resp.headers.get("content-type", "").startswith("application/json"):
        try:
            data = resp.json()
        except Exception:
            return resp.text
        if isinstance(data, dict):
            return data.get("detail", data)
        return data
    return resp.text


async def _proxy_get(path: str) -> dict:
    url = _backend_url(path)
    async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as client:
        resp = await client.get(url, headers=_headers("GET", url))
    if resp.status_code != 200:
        raise HTTPException(resp.status_code, _extract_detail(resp))
    return resp.json()


async def _proxy_post(path: str, body: bytes) -> dict:
    url = _backend_url(path)
    async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as client:
        resp = await client.post(url, content=body, headers=_headers("POST", url, body))
    if resp.status_code != 200:
        raise HTTPException(resp.status_code, _extract_detail(resp))
    return resp.json()


def _dump(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


@router.get("/config")
async def get_plans_config(_: str = Depends(get_current_admin)):
    """套餐配置 + bonus 策略(后端唯一真源)。前端读取 plan_configs / bonus_credit_policy。"""
    return await _proxy_get("/api/v1/config/plan-admin/plan-configs")


@router.post("/config")
async def save_plans_config(data: PlansConfigRequest, _: str = Depends(get_current_admin)):
    """保存套餐配置与 bonus 策略(清洗与落库均在后端完成)。"""
    return await _proxy_post("/api/v1/config/plan-admin/plan-configs", _dump(data.model_dump()))


@router.get("/subscription")
async def get_user_subscription(email: str, _: str = Depends(get_current_admin)):
    return await _proxy_get(f"/api/v1/config/plan-admin/subscription?{urlencode({'email': email})}")


@router.get("/accounts")
async def list_plan_accounts(
    email: str | None = None,
    plan_code: str | None = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    _: str = Depends(get_current_admin),
):
    params: dict[str, Any] = {"page": page, "page_size": page_size}
    if email:
        params["email"] = email
    if plan_code:
        params["plan_code"] = plan_code
    return await _proxy_get(f"/api/v1/config/plan-admin/accounts?{urlencode(params)}")


@router.get("/accounts/detail")
async def get_plan_account_detail(email: str, _: str = Depends(get_current_admin)):
    return await _proxy_get(f"/api/v1/config/plan-admin/accounts/detail?{urlencode({'email': email})}")


@router.post("/assign")
async def assign_plan(data: AssignPlanRequest, admin_email: str = Depends(get_current_admin)):
    """手动分配 / 变更套餐。管理端注入操作者 admin_email,订阅激活由后端 PlanService 负责。"""
    payload = {**data.model_dump(), "admin_email": admin_email}
    return await _proxy_post("/api/v1/config/plan-admin/assign", _dump(payload))


@router.post("/subscription/auto-renew")
async def update_auto_renew(data: AutoRenewRequest, admin_email: str = Depends(get_current_admin)):
    payload = {**data.model_dump(), "admin_email": admin_email}
    return await _proxy_post("/api/v1/config/plan-admin/subscription/auto-renew", _dump(payload))


@router.post("/grant")
async def grant_comp(data: GrantCompRequest, admin_email: str = Depends(get_current_admin)):
    """发放赠送套餐(comp:无订单/不续费/可指定有效期/重复延长)。权益授予由后端 EntitlementService 负责。"""
    payload = {**data.model_dump(), "admin_email": admin_email}
    return await _proxy_post("/api/v1/config/plan-admin/grant-comp", _dump(payload))


@router.post("/revoke")
async def revoke_entitlement(data: RevokeEntitlementRequest, admin_email: str = Depends(get_current_admin)):
    """撤销用户套餐权益(默认回落 free)。"""
    payload = {**data.model_dump(), "admin_email": admin_email}
    return await _proxy_post("/api/v1/config/plan-admin/revoke", _dump(payload))
