"""健康检查。"""
from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.get("/health")
async def health():
    return {"status": "ok", "service": "lobster-landing-api"}


@router.get("/api/v1/health")
async def health_v1():
    return {"status": "ok", "service": "lobster-landing-api"}
