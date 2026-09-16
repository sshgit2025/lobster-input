"""iOS 内购(Apple IAP)配置代理接口。

与 payment_provider_config 相同的定位:管理端不直接持有支付领域数据,
通过内部签名转发到支付服务的 /api/v1/payments/apple/admin/config 读写配置。
"""
from typing import Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.api.v1.deps import get_current_admin
from app.api.v1.payment_provider_config import _request_payment_service

router = APIRouter(prefix="/api/v1/apple-iap-config", tags=["apple-iap-config"])


class AppleIapConfigRequest(BaseModel):
    enabled: bool = False
    bundle_id: str = ""
    app_apple_id: int | None = None
    allow_sandbox: bool = True
    enable_online_checks: bool = False
    api_issuer_id: str = ""
    api_key_id: str = ""
    api_private_key: str = ""
    products: list[dict[str, Any]] = Field(default_factory=list)


@router.get("")
async def get_apple_iap_config(_: str = Depends(get_current_admin)):
    return await _request_payment_service("GET", "/api/v1/payments/apple/admin/config")


@router.post("")
async def save_apple_iap_config(data: AppleIapConfigRequest, _: str = Depends(get_current_admin)):
    payload = data.model_dump() if hasattr(data, "model_dump") else data.dict()
    return await _request_payment_service("POST", "/api/v1/payments/apple/admin/config", payload)
