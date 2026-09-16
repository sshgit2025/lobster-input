"""号池管理 API：平台目录、负载均衡分组、真实 Key。"""
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.api.v1.deps import get_current_admin, get_api_key_repo
from app.repositories.api_key_repository import ApiKeyRepository

router = APIRouter(prefix="/api/v1/keys", tags=["keys"])


class PlatformRequest(BaseModel):
    code: str
    category: str
    name: str = ""
    description: str = ""
    default_base_url: str = ""
    default_model: str = ""
    default_extra_config: dict = Field(default_factory=dict)
    enabled: bool = True


class GroupRequest(BaseModel):
    group_id: str
    platform_code: str
    category: str
    name: str = ""
    description: str = ""
    enabled: bool = True


class QuotaInput(BaseModel):
    enabled: bool = False
    total: float = 0
    used: float = 0
    auto_reset_period: str = "none"


class ProxyConfigInput(BaseModel):
    enabled: bool = False
    proxy_url: str = ""
    username: str = ""
    password: str = ""


class CreateKeyRequest(BaseModel):
    group_id: str
    api_key: str
    name: str = ""
    description: str = ""
    token_quota: QuotaInput = Field(default_factory=QuotaInput)
    seconds_quota: QuotaInput = Field(default_factory=QuotaInput)
    requests_quota: QuotaInput = Field(default_factory=QuotaInput)
    weight: int = 10
    priority: int = 0
    base_url: str = ""
    model: str = ""
    extra_config: dict = Field(default_factory=dict)
    proxy_config: ProxyConfigInput = Field(default_factory=ProxyConfigInput)
    cooldown_seconds: int = 60
    error_threshold: int = Field(default=30, ge=30)
    expires_at: Optional[str] = None


class UpdateKeyRequest(BaseModel):
    group_id: Optional[str] = None
    name: Optional[str] = None
    description: Optional[str] = None
    api_key: Optional[str] = None
    weight: Optional[int] = None
    priority: Optional[int] = None
    base_url: Optional[str] = None
    model: Optional[str] = None
    extra_config: Optional[dict] = None
    proxy_config: Optional[ProxyConfigInput] = None
    cooldown_seconds: Optional[int] = None
    error_threshold: Optional[int] = Field(default=None, ge=30)
    expires_at: Optional[str] = None
    token_quota: Optional[QuotaInput] = None
    seconds_quota: Optional[QuotaInput] = None
    requests_quota: Optional[QuotaInput] = None


class ResetStatusRequest(BaseModel):
    status: str = "disabled"
    reason: str = ""


class AdjustQuotaRequest(BaseModel):
    quota_type: str
    total: Optional[float] = None
    used: Optional[float] = None
    enabled: Optional[bool] = None
    auto_reset_period: Optional[str] = None


def _parse_expires(data: dict) -> dict:
    if "expires_at" not in data:
        return data
    if data.get("expires_at"):
        data["expires_at"] = datetime.fromisoformat(data["expires_at"]).replace(tzinfo=timezone.utc)
    else:
        data["expires_at"] = None
    return data


@router.get("")
async def list_keys(
    category: str = "",
    platform_code: str = "",
    group_id: str = "",
    status: str = "",
    page: int = 1,
    page_size: int = 20,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    try:
        items, total = await repo.list_keys(category, platform_code, group_id, status, page, page_size)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"items": items, "total": total, "page": page, "page_size": page_size}


@router.post("")
async def create_key(
    req: CreateKeyRequest,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    try:
        key_id = await repo.create(_parse_expires(req.model_dump()))
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"ok": True, "id": key_id}


@router.get("/categories")
async def list_categories(
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    return await repo.list_categories()


@router.get("/platforms")
async def list_platforms(
    category: str = "",
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    return await repo.list_platform_records(category)


@router.post("/platforms")
async def upsert_platform(
    req: PlatformRequest,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    try:
        code = await repo.upsert_platform(req.model_dump())
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"ok": True, "code": code}


@router.get("/groups")
async def list_groups(
    category: str = "",
    platform_code: str = "",
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    try:
        return await repo.list_group_records(category, platform_code)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc


@router.post("/groups")
async def upsert_group(
    req: GroupRequest,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    try:
        group_id = await repo.upsert_group(req.model_dump())
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"ok": True, "group_id": group_id}


@router.get("/{key_id}")
async def get_key(
    key_id: str,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    doc = await repo.get_by_id(key_id)
    if not doc:
        raise HTTPException(404, "Key not found")
    return doc


@router.put("/{key_id}")
async def update_key(
    key_id: str,
    req: UpdateKeyRequest,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    data = {k: v for k, v in req.model_dump().items() if v is not None}
    data = _parse_expires(data)
    if not data:
        raise HTTPException(400, "No fields to update")
    try:
        ok = await repo.update(key_id, data)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    if not ok:
        raise HTTPException(404, "Key not found")
    return {"ok": True}


@router.delete("/{key_id}")
async def delete_key(
    key_id: str,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    ok = await repo.delete(key_id)
    if not ok:
        raise HTTPException(404, "Key not found")
    return {"ok": True}


@router.post("/{key_id}/reset")
async def reset_key_status(
    key_id: str,
    req: ResetStatusRequest,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    try:
        ok = await repo.reset_status(key_id, req.status, req.reason)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    if not ok:
        raise HTTPException(404, "Key not found")
    return {"ok": True}


@router.post("/{key_id}/quota")
async def adjust_quota(
    key_id: str,
    req: AdjustQuotaRequest,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    valid_types = ("token_quota", "seconds_quota", "requests_quota")
    if req.quota_type not in valid_types:
        raise HTTPException(400, f"quota_type must be one of {valid_types}")
    ok = await repo.adjust_quota(key_id, req.quota_type, req.total, req.used, req.enabled, req.auto_reset_period)
    if not ok:
        raise HTTPException(404, "Key not found or no change")
    return {"ok": True}
