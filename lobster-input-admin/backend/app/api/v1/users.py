import logging
from datetime import datetime, timezone, timedelta
from fastapi import APIRouter, Depends, HTTPException, Query
from typing import Optional
from app.repositories.user_repository import UserRepository
from app.api.v1.deps import get_user_repo, get_current_admin, get_admin_db, get_main_db
from app.models.user import BanUserRequest, UnbanUserRequest, GrantCreditsRequest, EmailRequest

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/users", tags=["users"])
MAX_ADMIN_GRANT_DAYS = 3650
GRANT_EXPIRES_MANUAL = "manual"
GRANT_EXPIRES_SUBSCRIPTION = "subscription"


def _normalize_expires_at(value: datetime) -> datetime:
    expires_at = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    if expires_at <= now:
        raise HTTPException(status_code=400, detail="赠送积分有效期必须晚于当前时间")
    if expires_at > now + timedelta(days=MAX_ADMIN_GRANT_DAYS):
        raise HTTPException(status_code=400, detail="赠送积分有效期不能超过 10 年")
    return expires_at


def _normalize_dt(value: datetime | None) -> datetime | None:
    if not value:
        return None
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def _active_plan_code(user: dict) -> str:
    return user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier") or ""


def _subscription_expires_at(user: dict) -> datetime | None:
    return _normalize_dt(user.get("subscription_expires_at") or user.get("plan_expires_at"))


async def _resolve_grant_expires_at(data: GrantCreditsRequest, repo: UserRepository) -> tuple[datetime, dict]:
    mode = (data.expires_at_mode or GRANT_EXPIRES_MANUAL).strip().lower()
    now = datetime.now(timezone.utc)
    if mode == GRANT_EXPIRES_MANUAL:
        if not data.expires_at:
            raise HTTPException(status_code=400, detail="请选择赠送积分有效期")
        expires_at = _normalize_expires_at(data.expires_at)
        return expires_at, {"expires_at_mode": GRANT_EXPIRES_MANUAL}

    if mode != GRANT_EXPIRES_SUBSCRIPTION:
        raise HTTPException(status_code=400, detail="不支持的赠送积分到期方式")

    user = await repo.find_by_email(data.email)
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    plan_code = _active_plan_code(user)
    expires_at = _subscription_expires_at(user)
    if plan_code == "free" or not expires_at:
        raise HTTPException(status_code=400, detail="免费套餐不能选择随套餐失效，请手动设置赠送积分有效期")
    if expires_at <= now:
        raise HTTPException(status_code=400, detail="当前套餐已到期，不能选择随套餐失效")
    return expires_at, {
        "expires_at_mode": GRANT_EXPIRES_SUBSCRIPTION,
        "subscription_plan_code": plan_code,
        "subscription_expires_at": expires_at,
    }


def _build_query(
    email: Optional[str],
    device_id: Optional[str],
    ip: Optional[str],
    plan_code: Optional[str],
    is_active: Optional[bool],
) -> dict:
    q = {}
    if email:
        q["email"] = {"$regex": email, "$options": "i"}
    if device_id:
        q["reg_device_id"] = device_id
    if ip:
        q["reg_ip"] = ip
    if plan_code:
        q["$or"] = [{"subscription_plan_code": plan_code}, {"plan_code": plan_code}]
    if is_active is not None:
        q["is_active"] = is_active
    return q


@router.get("")
async def list_users(
    email: Optional[str] = Query(None),
    device_id: Optional[str] = Query(None),
    ip: Optional[str] = Query(None),
    plan_code: Optional[str] = Query(None),
    is_active: Optional[bool] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    _: str = Depends(get_current_admin),
    repo: UserRepository = Depends(get_user_repo),
):
    q = _build_query(email, device_id, ip, plan_code, is_active)
    total = await repo.count(q)
    items = await repo.find_paginated(q, page, page_size)
    for item in items:
        item.pop("_id", None)
        item["plan_code"] = item.get("subscription_plan_code") or item.get("plan_code")
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.get("/stats/plan-distribution")
async def plan_distribution(
    _: str = Depends(get_current_admin),
    repo: UserRepository = Depends(get_user_repo),
):
    data = await repo.get_plan_distribution()
    return [{"plan_code": d["_id"] or "none", "count": d["count"]} for d in data]


@router.get("/stats/daily-registrations")
async def daily_registrations(
    days: int = Query(30, ge=1, le=90),
    _: str = Depends(get_current_admin),
    repo: UserRepository = Depends(get_user_repo),
):
    data = await repo.get_daily_registrations(days)
    return [{"date": d["_id"], "count": d["count"]} for d in data]


@router.post("/credits")
async def get_user_credits(
    data: EmailRequest,
    _: str = Depends(get_current_admin),
    repo: UserRepository = Depends(get_user_repo),
):
    user = await repo.find_by_email(data.email)
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    # 订阅到期/周期推进是业务后端的唯一职责(计费重构 D6:管理端不再自算/写共享库订阅态)。
    # 此前 `from app.api.v1.plans import _ensure_subscription_current` 依赖的函数已随 plans.py 纯代理化删除,
    # 会 ImportError→500。这里改为直接读库展示;推进由用户访问后端时惰性完成,管理端只读不写。
    info = await repo.get_credits_info(data.email)
    if not info:
        raise HTTPException(status_code=404, detail="用户不存在")
    total = info.get("credits_total", 0)
    used = info.get("credits_used", 0)
    grants = await repo.list_active_credit_grants(data.email)
    return {
        "email": data.email,
        "plan_code": info.get("plan_code", "none"),
        "credits_total": total,
        "credits_used": used,
        "credits_remaining": max(0, total - used),
        "credits_reset_at": info.get("credits_reset_at"),
        "credits_reset_note": info.get("credits_reset_note"),
        "bonus_credits_remaining": info.get("bonus_credits_remaining", 0),
        "paid_topup_credits_remaining": info.get("paid_topup_credits_remaining", 0),
        "subscription_expires_at": info.get("subscription_expires_at", info.get("plan_expires_at")),
        "pending_plan_code": info.get("pending_plan_code"),
        "pending_effective_at": info.get("pending_effective_at"),
        "credit_grants": grants,
    }


@router.post("/detail")
async def get_user(
    data: EmailRequest,
    _: str = Depends(get_current_admin),
    repo: UserRepository = Depends(get_user_repo),
):
    user = await repo.find_by_email(data.email)
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    user.pop("_id", None)
    user.pop("hashed_password", None)
    user["plan_code"] = user.get("subscription_plan_code") or user.get("plan_code")
    return user


@router.post("/ban")
async def ban_user(
    data: BanUserRequest,
    _: str = Depends(get_current_admin),
    repo: UserRepository = Depends(get_user_repo),
):
    ok = await repo.set_active(data.email, False)
    if not ok:
        raise HTTPException(status_code=404, detail="用户不存在")
    return {"message": f"用户 {data.email} 已禁用"}


@router.post("/unban")
async def unban_user(
    data: UnbanUserRequest,
    _: str = Depends(get_current_admin),
    repo: UserRepository = Depends(get_user_repo),
):
    ok = await repo.set_active(data.email, True)
    if not ok:
        raise HTTPException(status_code=404, detail="用户不存在")
    return {"message": f"用户 {data.email} 已解封"}


@router.post("/grant-credits")
async def grant_credits(
    data: GrantCreditsRequest,
    admin_email: str = Depends(get_current_admin),
    repo: UserRepository = Depends(get_user_repo),
):
    if data.amount <= 0:
        raise HTTPException(status_code=400, detail="赠送积分数量必须大于 0")
    expires_at, grant_metadata = await _resolve_grant_expires_at(data, repo)
    grant_metadata["reason"] = data.reason
    ok = await repo.grant_credits(data.email, data.amount, expires_at=expires_at, metadata=grant_metadata)
    if not ok:
        raise HTTPException(status_code=404, detail="用户不存在")

    now = datetime.now(timezone.utc)
    admin_db = get_admin_db()
    await admin_db["admin_operation_log"].insert_one({
        "admin_email": admin_email,
        "action": "grant_credits",
        "target_email": data.email,
        "amount": data.amount,
        "reason": data.reason,
        "expires_at": expires_at,
        "expires_at_mode": grant_metadata.get("expires_at_mode"),
        "subscription_plan_code": grant_metadata.get("subscription_plan_code"),
        "created_at": now,
    })

    main_db = get_main_db()
    await main_db["credit_ledger"].insert_one({
        "user_email": data.email,
        "date": now.strftime("%Y-%m-%d"),
        "operation": "admin_grant",
        "client_platform": "system",
        "total_credits": data.amount,
        "breakdown": [{"platform": "admin_grant", "credits": data.amount,
                       "input_tokens": 0, "output_tokens": 0,
                       "audio_duration_sec": 0.0, "audio_chars": 0, "search_count": 0}],
        "remark": data.reason,
        "admin_email": admin_email,
        "expires_at": expires_at,
        "expires_at_mode": grant_metadata.get("expires_at_mode"),
        "subscription_plan_code": grant_metadata.get("subscription_plan_code"),
        "created_at": now,
    })

    logger.info(
        "grant_credits admin=%s target=%s amount=%d reason=%s",
        admin_email, data.email, data.amount, data.reason,
    )

    updated = await repo.get_credits_info(data.email)
    total = updated.get("credits_total", 0) if updated else 0
    used = updated.get("credits_used", 0) if updated else 0
    return {
        "message": f"已赠送 {data.amount} 积分给 {data.email}",
        "credits_total": total,
        "credits_used": used,
        "credits_remaining": max(0, total - used),
        "expires_at": expires_at,
        "expires_at_mode": grant_metadata.get("expires_at_mode"),
    }
