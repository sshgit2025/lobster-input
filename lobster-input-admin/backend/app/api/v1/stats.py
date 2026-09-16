from fastapi import APIRouter, Depends, Query
from typing import Optional
from app.repositories.stats_repository import StatsRepository
from app.api.v1.deps import get_stats_repo, get_current_admin

router = APIRouter(prefix="/api/v1/stats", tags=["stats"])


def _build_query(
    user_email: Optional[str],
    platform: Optional[str],
    operation: Optional[str],
    date_from: Optional[str],
    date_to: Optional[str],
    api_key_hint: Optional[str] = None,
) -> dict:
    q = {}
    if user_email:
        q["user_email"] = {"$regex": user_email, "$options": "i"}
    if platform:
        q["platform"] = platform
    if operation:
        q["operation"] = operation
    if date_from or date_to:
        date_q = {}
        if date_from:
            date_q["$gte"] = date_from
        if date_to:
            date_q["$lte"] = date_to
        q["date"] = date_q
    if api_key_hint:
        q["api_key_hint"] = {"$regex": api_key_hint, "$options": "i"}
    return q


@router.get("")
async def list_stats(
    user_email: Optional[str] = Query(None),
    platform: Optional[str] = Query(None),
    operation: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    api_key_hint: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    _: str = Depends(get_current_admin),
    repo: StatsRepository = Depends(get_stats_repo),
):
    q = _build_query(user_email, platform, operation, date_from, date_to, api_key_hint)
    total = await repo.count(q)
    items = await repo.find_paginated(q, page, page_size)
    for item in items:
        item.pop("_id", None)
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.get("/summary")
async def get_summary(
    user_email: Optional[str] = Query(None),
    platform: Optional[str] = Query(None),
    operation: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    api_key_hint: Optional[str] = Query(None),
    _: str = Depends(get_current_admin),
    repo: StatsRepository = Depends(get_stats_repo),
):
    q = _build_query(user_email, platform, operation, date_from, date_to, api_key_hint)
    return await repo.get_summary(q if q else None)


@router.get("/daily")
async def daily_stats(
    days: int = Query(30, ge=1, le=90),
    _: str = Depends(get_current_admin),
    repo: StatsRepository = Depends(get_stats_repo),
):
    data = await repo.get_daily_requests(days)
    return [{"date": d["_id"], **{k: v for k, v in d.items() if k != "_id"}} for d in data]


@router.get("/platform-distribution")
async def platform_distribution(
    _: str = Depends(get_current_admin),
    repo: StatsRepository = Depends(get_stats_repo),
):
    data = await repo.get_platform_distribution()
    return [{"platform": d["_id"], "count": d["count"]} for d in data]


@router.get("/top-users")
async def top_users(
    limit: int = Query(10, ge=1, le=50),
    _: str = Depends(get_current_admin),
    repo: StatsRepository = Depends(get_stats_repo),
):
    data = await repo.get_top_users(limit)
    return [{"email": d["_id"], **{k: v for k, v in d.items() if k != "_id"}} for d in data]


@router.get("/api-keys")
async def api_key_stats(
    user_email: Optional[str] = Query(None),
    platform: Optional[str] = Query(None),
    operation: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    api_key_hint: Optional[str] = Query(None),
    _: str = Depends(get_current_admin),
    repo: StatsRepository = Depends(get_stats_repo),
):
    q = _build_query(user_email, platform, operation, date_from, date_to, api_key_hint)
    data = await repo.get_api_key_stats(q if q else None)
    return [{"api_key_hint": d["_id"], **{k: v for k, v in d.items() if k != "_id"}} for d in data]
