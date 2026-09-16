"""
统计仪表盘和消费明细 API。
"""
from fastapi import APIRouter, Depends
from app.api.v1.deps import get_current_admin, get_api_key_repo
from app.repositories.api_key_repository import ApiKeyRepository

router = APIRouter(
    prefix="/api/v1/stats", tags=["stats"],
)


@router.get("/dashboard")
async def dashboard(
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    return await repo.get_dashboard()


@router.get("/categories")
async def category_stats(
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    """按 Provider 分类聚合 Key 状态统计。"""
    return await repo.get_category_stats()


@router.get("/platforms")
async def platform_stats(
    category: str = "",
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    """按平台聚合，可按 category 过滤。"""
    return await repo.get_platform_stats(category)


@router.get("/usage")
async def usage_list(
    category: str = "",
    platform_code: str = "",
    group_id: str = "",
    api_key_id: str = "",
    start_date: str = "",
    end_date: str = "",
    page: int = 1,
    page_size: int = 50,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    items, total = await repo.list_usage(
        category, platform_code, group_id, api_key_id,
        start_date, end_date, page, page_size,
    )
    return {
        "items": items, "total": total,
        "page": page, "page_size": page_size,
    }


@router.get("/keys/{key_id}")
async def key_stats(
    key_id: str,
    _admin: str = Depends(get_current_admin),
    repo: ApiKeyRepository = Depends(get_api_key_repo),
):
    return await repo.get_key_stats(key_id)
