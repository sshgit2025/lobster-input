"""
积分账本 API — 查询 credit_ledger 集合。
"""
from fastapi import APIRouter, Depends, Query
from typing import Optional
from app.repositories.ledger_repository import LedgerRepository, with_consumption_filter
from app.api.v1.deps import get_ledger_repo, get_current_admin

router = APIRouter(prefix="/api/v1/ledger", tags=["ledger"])
REWARD_OPERATIONS = ["admin_grant", "registration_reward", "invite_reward"]


def _build_query(
    user_email: Optional[str],
    operation: Optional[str],
    client_platform: Optional[str],
    date_from: Optional[str],
    date_to: Optional[str],
) -> dict:
    q = {}
    if user_email:
        q["user_email"] = {"$regex": user_email, "$options": "i"}
    if operation:
        q["operation"] = operation
    elif client_platform == "system":
        q["operation"] = {"$in": REWARD_OPERATIONS}
    else:
        q = with_consumption_filter(q)
    if client_platform:
        q["client_platform"] = client_platform
    if date_from or date_to:
        date_q = {}
        if date_from:
            date_q["$gte"] = date_from
        if date_to:
            date_q["$lte"] = date_to
        q["date"] = date_q
    return q


@router.get("")
async def list_ledger(
    user_email: Optional[str] = Query(None),
    operation: Optional[str] = Query(None),
    client_platform: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    _: str = Depends(get_current_admin),
    repo: LedgerRepository = Depends(get_ledger_repo),
):
    q = _build_query(user_email, operation, client_platform, date_from, date_to)
    total = await repo.count(q)
    items = await repo.find_paginated(q, page, page_size)
    for item in items:
        item.pop("_id", None)
        if "created_at" in item and hasattr(item["created_at"], "isoformat"):
            item["created_at"] = item["created_at"].isoformat()
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.get("/daily")
async def daily_credits(
    days: int = Query(30, ge=1, le=90),
    _: str = Depends(get_current_admin),
    repo: LedgerRepository = Depends(get_ledger_repo),
):
    data = await repo.get_daily_credits(days)
    return [{"date": d["_id"], "total_credits": d["total_credits"], "record_count": d["record_count"]}
            for d in data]


@router.get("/platform-breakdown")
async def platform_breakdown(
    user_email: Optional[str] = Query(None),
    operation: Optional[str] = Query(None),
    client_platform: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    _: str = Depends(get_current_admin),
    repo: LedgerRepository = Depends(get_ledger_repo),
):
    q = _build_query(user_email, operation, client_platform, date_from, date_to)
    data = await repo.get_platform_breakdown(q if q else None)
    return [{"platform": d["_id"], "total_credits": d["total_credits"]} for d in data]


@router.get("/top-users")
async def top_users(
    limit: int = Query(10, ge=1, le=50),
    user_email: Optional[str] = Query(None),
    operation: Optional[str] = Query(None),
    client_platform: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    _: str = Depends(get_current_admin),
    repo: LedgerRepository = Depends(get_ledger_repo),
):
    q = _build_query(user_email, operation, client_platform, date_from, date_to)
    data = await repo.get_top_users(limit, q if q else None)
    return [{"email": d["_id"], "total_credits": d["total_credits"], "record_count": d["record_count"]}
            for d in data]


@router.get("/summary")
async def get_summary(
    user_email: Optional[str] = Query(None),
    operation: Optional[str] = Query(None),
    client_platform: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    _: str = Depends(get_current_admin),
    repo: LedgerRepository = Depends(get_ledger_repo),
):
    q = _build_query(user_email, operation, client_platform, date_from, date_to)
    return await repo.get_summary(q if q else None)
