"""号池内部 API — 供后端和管理端服务调用。"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.api.v1.deps import verify_internal_key, get_api_key_repo
from app.repositories.api_key_repository import ApiKeyRepository

router = APIRouter(prefix="/api/v1/pool", tags=["pool"])


class UsageReport(BaseModel):
    api_key_id: str
    group_id: str = ""
    category: str = ""
    platform_code: str = ""
    tokens_used: float = 0
    seconds_used: float = 0
    requests_used: int = 1
    operation: str = ""
    user_email: str = ""
    latency_ms: int = 0
    success: bool = True
    error_message: str = ""
    client_platform: str = ""
    api_key_hint: str = ""


class ErrorReport(BaseModel):
    api_key_id: str
    error_message: str = ""


class ResetRequest(BaseModel):
    api_key_id: str
    status: str = "disabled"
    reason: str = ""


@router.get("/catalog")
async def catalog(
    category: str = "",
    _auth: bool = Depends(verify_internal_key),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    """管理端读取平台目录和分组，用于实时挂载 provider。"""
    return {
        "categories": await repo.list_categories(),
        "platforms": await repo.list_platform_records(category),
        "groups": await repo.list_group_records(category),
    }


@router.get("/pick")
async def pick_key(
    group_id: str,
    _auth: bool = Depends(verify_internal_key),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    """按 group_id 在组内负载均衡获取一个可用 API Key。"""
    doc = await repo.pick_key(group_id)
    if not doc:
        raise HTTPException(503, f"No available key for group_id={group_id}")
    return {
        "id": doc["_id"],
        "api_key": doc["api_key"],
        "base_url": doc.get("base_url", ""),
        "model": doc.get("model", ""),
        "group_id": doc.get("group_id", ""),
        "category": doc.get("category", ""),
        "platform_code": doc.get("platform_code", ""),
        "platform_name": doc.get("platform_name", ""),
        "extra_config": doc.get("extra_config", {}),
        "proxy_config": doc.get("proxy_config", {}),
    }


@router.post("/usage")
async def report_usage(
    req: UsageReport,
    _auth: bool = Depends(verify_internal_key),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    result = await repo.report_usage(req.api_key_id, req.model_dump())
    return {"ok": True, "status": result.get("status", "")}


@router.post("/error")
async def report_error(
    req: ErrorReport,
    _auth: bool = Depends(verify_internal_key),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    result = await repo.report_error(req.api_key_id, req.error_message)
    return {
        "ok": True,
        "status": result.get("status", ""),
        "error_count": result.get("error_count", 0),
    }


@router.post("/reset")
async def reset_key(
    req: ResetRequest,
    _auth: bool = Depends(verify_internal_key),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    ok = await repo.reset_status(req.api_key_id, req.status, req.reason)
    if not ok:
        raise HTTPException(404, "Key not found")
    return {"ok": True}
