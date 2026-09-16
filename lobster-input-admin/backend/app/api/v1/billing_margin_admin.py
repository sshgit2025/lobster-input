"""计费经济性(节点单价 + 成本表 + 只读毛利监控)管理代理 API。

前端以 /api/v1/billing-margin/* 访问,登录态鉴权沿用现有 admin(get_current_admin);
内部使用 BACKEND_URL + BACKEND_API_KEY 的 HMAC 签名转发到业务后端
(lobster-input-backend)的 /api/v1/config/billing-* 接口。
代理风格模仿 app/api/v1/user_dict.py。

计费重构后契约(阶段A):
- 节点单价 rules(ASR/LLM 按节点单价无 provider;web_search 保留 provider)与 policy 一起存,
  保存不再有毛利地板拦截 / violations / force。
- 成本表 provider-costs 独立 CRUD,仅供毛利监控,不参与扣费。
- 毛利报表 report 为只读监控。
- 已删除 calibrate 校准助手。
"""
import hmac
import json
import logging
import time
from hashlib import sha256
from typing import Any
from urllib.parse import urlsplit

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.api.v1.deps import get_current_admin
from app.core.config import settings

logger = logging.getLogger("lobster_admin.billing_margin")

router = APIRouter(prefix="/api/v1/billing-margin", tags=["billing-margin"])

BACKEND_TIMEOUT = 30.0


class SaveRulesRequest(BaseModel):
    rules: list[dict[str, Any]] = Field(default_factory=list)
    policy: dict[str, Any] | None = None


class SaveProviderCostsRequest(BaseModel):
    costs: list[dict[str, Any]] = Field(default_factory=list)


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


def _dump(model: BaseModel) -> bytes:
    data = model.model_dump() if hasattr(model, "model_dump") else model.dict()
    return json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


@router.get("/rules")
async def get_billing_rules(_: str = Depends(get_current_admin)):
    """节点单价规则数组(ASR/LLM 按节点单价无 provider;web_search 含 provider)与全局策略 policy。"""
    return await _proxy_get("/api/v1/config/billing-rules")


@router.post("/rules")
async def save_billing_rules(data: SaveRulesRequest, _: str = Depends(get_current_admin)):
    """保存节点单价规则与策略。仅校验字段合法性,不做毛利地板拦截,返回 {saved:true}。"""
    return await _proxy_post("/api/v1/config/billing-rules", _dump(data))


@router.get("/provider-costs")
async def get_provider_costs(_: str = Depends(get_current_admin)):
    """上游参考成本表(provider→upstream_cost_cny),仅供毛利监控,不参与扣费。"""
    return await _proxy_get("/api/v1/config/billing-provider-costs")


@router.post("/provider-costs")
async def save_provider_costs(data: SaveProviderCostsRequest, _: str = Depends(get_current_admin)):
    """保存上游参考成本表,返回 {saved:true}。"""
    return await _proxy_post("/api/v1/config/billing-provider-costs", _dump(data))


@router.get("/report")
async def get_margin_report(_: str = Depends(get_current_admin)):
    """只读毛利监控:每节点各 provider 的 margin 与红绿灯状态、全局最低每积分售价。纯展示,不阻断任何操作。"""
    return await _proxy_get("/api/v1/config/billing-margin-report")
