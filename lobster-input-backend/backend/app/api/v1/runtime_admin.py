"""Internal runtime configuration operations."""
from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.middleware.auth import verify_internal_api_key
from app.services.infra.runtime_provider_config import clear_runtime_provider_cache

router = APIRouter(prefix="/admin/runtime-config", tags=["Admin - RuntimeConfig"])


class CacheClearRequest(BaseModel):
    source: str = ""


@router.post("/cache/clear")
async def clear_runtime_config_cache(
    _req: CacheClearRequest,
    _payload: dict = Depends(verify_internal_api_key),
):
    clear_runtime_provider_cache()
    return {"ok": True}
