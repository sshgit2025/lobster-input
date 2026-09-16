"""
套餐 / 订阅 管理端点(管理端代理调用,内部鉴权 verify_internal_api_key)。

M2 归并:业务后端成为套餐定义与订阅管理的唯一真源与唯一写入方。
- 套餐配置读写、bonus 策略:走 PlanRepository(唯一 DEFAULT_PLAN_CONFIGS/清洗)。
- 订阅激活 / 续费 / 到期降级 / 周期重置:全部走 PlanService(唯一 add_period /
  activate_subscription),不再由管理端自算。

管理端(lobster-input-admin)plans.py 现为纯 HMAC 代理转发到本文件的
/api/v1/config/plan-admin/* 端点,行为(入参 / 返回 / 副作用)与其历史实现保持一致。
路径前缀 /api/v1/config/plan-admin 已在 client_platform 中间件 _SKIP_PREFIXES 豁免。
"""
import logging
from datetime import datetime, timezone
from typing import Any, Optional

from fastapi import APIRouter, Body, Depends, HTTPException, Query
from pydantic import BaseModel

from app.api.v1.payments import _post_payment_service
from app.core.database import get_db
from app.middleware.auth import verify_internal_api_key
from app.repositories.credit_grant_repository import CreditGrantRepository
from app.repositories.plan_repository import (
    DEFAULT_PLAN_CONFIGS,
    PlanRepository,
)
from app.repositories.user_repository import UserRepository
from app.services.billing.plan_policy import PlanPolicy, TRIAL_PLAN_CODE
from app.services.billing.entitlement_service import EntitlementService
from app.services.billing.plan_service import PlanService, add_period
from app.services.billing.subscription_lifecycle import (
    BONUS_CREDIT_TYPE,
    PAID_TOPUP_CREDIT_TYPE,
)

logger = logging.getLogger("voice_input.plan_admin")

router = APIRouter(prefix="/config/plan-admin", tags=["plan-admin"])

CHARGE_TYPE_SCHEDULED_DOWNGRADE = "scheduled_downgrade"


class PlanConfigsRequest(BaseModel):
    plan_configs: dict[str, Any]
    bonus_credit_policy: dict[str, Any]


class AssignPlanRequest(BaseModel):
    email: str
    plan_code: str
    billing_cycle: str = "monthly"
    change_mode: str = "activate_now"
    auto_renew: bool = False
    admin_email: str = ""


class AutoRenewRequest(BaseModel):
    email: str
    auto_renew: bool
    admin_email: str = ""


class GrantCompRequest(BaseModel):
    email: str
    plan_code: str
    start: Optional[datetime] = None
    end: Optional[datetime] = None
    reason: str = ""
    idempotency_key: Optional[str] = None
    admin_email: str = ""


class RevokeEntitlementRequest(BaseModel):
    email: str
    to_free: bool = True
    reason: str = ""
    admin_email: str = ""


class GrantPaidRequest(BaseModel):
    email: str
    plan_code: str
    billing_cycle: str
    duration_count: int = 1
    duration_period: str = "month"
    change_mode: str
    auto_renew: bool = False
    paid_amount_cents: int = 0
    provider: str = ""
    provider_payment_id: str = ""
    payment_order_id: str = ""
    payment_event_id: str
    charge_type: str = ""


class GrantPaidTopupRequest(BaseModel):
    email: str
    amount: int
    expires_at: datetime
    provider: str = ""
    payment_event_id: str
    plan_code: str = ""


# ── 通用小工具 ─────────────────────────────────────────────
def _int_value(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _normalize_dt(value):
    if not value:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    return value


def _is_paid_plan(plan: dict[str, Any] | None) -> bool:
    return bool((plan or {}).get("paid", False))


def _can_auto_renew(plan: dict[str, Any] | None) -> bool:
    p = plan or {}
    return PlanPolicy.from_config(p, p.get("code", "")).can_auto_renew


def _can_replace_immediately(active_plan: dict[str, Any] | None, target_plan: dict[str, Any] | None) -> bool:
    active_rank = int((active_plan or {}).get("rank", 0) or 0)
    target_rank = int((target_plan or {}).get("rank", 0) or 0)
    return target_rank >= active_rank


def _active_plan_code(user: dict) -> str:
    return PlanService._active_plan_code(user)


def _subscription_expires_at(user: dict):
    return PlanService._subscription_expires_at(user)


def _subscription_payload(user: dict) -> dict[str, Any]:
    """复刻管理端 plans.py 的订阅展示 payload(字段 / 计算方式完全一致)。"""
    expires_at = _subscription_expires_at(user)
    period_end = user.get("plan_current_period_end", user.get("credits_reset_at"))
    plan_total = _int_value(user.get("plan_credits_total", user.get("credits_total", 0)))
    plan_used = min(_int_value(user.get("plan_credits_used", user.get("credits_used", 0))), plan_total)
    plan_remaining = max(0, plan_total - plan_used)
    bonus_remaining = _int_value(user.get("bonus_credits_remaining", 0))
    paid_topup_remaining = _int_value(user.get("paid_topup_credits_remaining", 0))
    credits_remaining = plan_remaining + bonus_remaining + paid_topup_remaining
    return {
        "email": user.get("email"),
        "plan_code": _active_plan_code(user),
        "subscription_started_at": user.get("subscription_started_at", user.get("plan_started_at")),
        "subscription_expires_at": expires_at,
        "subscription_status": user.get("subscription_status", "active"),
        "subscription_billing_cycle": user.get("subscription_billing_cycle"),
        "subscription_auto_renew": bool(user.get("subscription_auto_renew", False)),
        "plan_current_period_start": user.get("plan_current_period_start"),
        "plan_current_period_end": period_end,
        "plan_current_period_note": "订阅到期前不再重置" if expires_at and period_end and expires_at <= period_end else None,
        "plan_credits_total": plan_total,
        "plan_credits_used": plan_used,
        "plan_credits_remaining": plan_remaining,
        "bonus_credits_remaining": bonus_remaining,
        "paid_topup_credits_remaining": paid_topup_remaining,
        "credits_total": plan_total + bonus_remaining + paid_topup_remaining,
        "credits_used": plan_used,
        "credits_remaining": credits_remaining,
        "pending_plan_code": user.get("pending_plan_code"),
        "pending_effective_at": user.get("pending_effective_at"),
        "pending_duration_count": user.get("pending_duration_count"),
        "pending_duration_period": user.get("pending_duration_period"),
        "pending_billing_cycle": user.get("pending_billing_cycle"),
        "pending_requires_payment": bool(user.get("pending_requires_payment", False)),
        "pending_payment_status": user.get("pending_payment_status"),
        "pending_payment_due_at": user.get("pending_payment_due_at"),
        "pending_payment_provider": user.get("pending_payment_provider"),
        "pending_payment_charge_type": user.get("pending_payment_charge_type"),
        "pending_payment_amount_cents": user.get("pending_payment_amount_cents"),
        "pending_payment_blocked_reason": user.get("pending_payment_blocked_reason"),
        "last_auto_charge_status": user.get("last_auto_charge_status"),
        "last_auto_charge_type": user.get("last_auto_charge_type"),
        "last_auto_charge_at": user.get("last_auto_charge_at"),
    }


async def _subscription_payload_with_balance(plan_service: PlanService, grant_repo: CreditGrantRepository, user: dict) -> dict[str, Any]:
    """先用 PlanService 惰性推进订阅 / 周期(唯一真源),再补 bonus / 加购余额。"""
    email = user.get("email")
    row = dict(user)
    if email:
        now = datetime.now(timezone.utc)
        row = await plan_service.check_and_reset_credits(email, dict(user))
        row["bonus_credits_remaining"] = await grant_repo.get_available_total(email, now, credit_type=BONUS_CREDIT_TYPE)
        row["paid_topup_credits_remaining"] = await grant_repo.get_available_total(email, now, credit_type=PAID_TOPUP_CREDIT_TYPE)
    return _subscription_payload(row)


async def _record_subscription_event(db, payload: dict[str, Any]) -> None:
    payload["created_at"] = payload.get("created_at") or datetime.now(timezone.utc)
    await db["subscription_events"].insert_one(payload)


# ── 端点 ───────────────────────────────────────────────────
@router.get("/plan-configs", summary="[管理端] 获取套餐配置 / 默认值 / bonus 策略")
async def get_plan_configs(_: dict = Depends(verify_internal_api_key)):
    plan_repo = PlanRepository()
    return {
        "plan_configs": await plan_repo.get_plan_configs(),
        "defaults": {k: dict(v) for k, v in DEFAULT_PLAN_CONFIGS.items()},
        "bonus_credit_policy": await plan_repo.get_bonus_credit_policy(),
    }


@router.post("/plan-configs", summary="[管理端] 保存套餐配置与 bonus 策略")
async def save_plan_configs(data: PlanConfigsRequest, _: dict = Depends(verify_internal_api_key)):
    plan_repo = PlanRepository()
    await plan_repo.set_plan_configs(data.plan_configs)
    await plan_repo.set_bonus_credit_policy(data.bonus_credit_policy)
    return {"message": "套餐配置已保存"}


@router.get("/subscription", summary="[管理端] 获取用户订阅详情")
async def get_user_subscription(email: str, _: dict = Depends(verify_internal_api_key)):
    db = get_db()
    user = await db["users"].find_one({"email": email}, {"_id": 0, "hashed_password": 0})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    return await _subscription_payload_with_balance(PlanService(), CreditGrantRepository(), user)


@router.get("/accounts", summary="[管理端] 套餐账户列表")
async def list_plan_accounts(
    email: str | None = None,
    plan_code: str | None = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    _: dict = Depends(verify_internal_api_key),
):
    db = get_db()
    q: dict[str, Any] = {}
    if email:
        q["email"] = {"$regex": email, "$options": "i"}
    if plan_code:
        q["subscription_plan_code"] = plan_code
    total = await db["users"].count_documents(q)
    cursor = db["users"].find(q, {"_id": 0, "hashed_password": 0}).sort("created_at", -1).skip((page - 1) * page_size).limit(page_size)
    users = await cursor.to_list(length=page_size)
    plan_service = PlanService()
    grant_repo = CreditGrantRepository()
    items = [await _subscription_payload_with_balance(plan_service, grant_repo, user) for user in users]
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.get("/accounts/detail", summary="[管理端] 套餐账户详情 + 历史")
async def get_plan_account_detail(email: str, _: dict = Depends(verify_internal_api_key)):
    db = get_db()
    user = await db["users"].find_one({"email": email}, {"_id": 0, "hashed_password": 0})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    cursor = db["subscription_events"].find({"email": email}, {"_id": 0}).sort("created_at", -1).limit(100)
    events = await cursor.to_list(length=100)
    current = await _subscription_payload_with_balance(PlanService(), CreditGrantRepository(), user)
    if not events:
        events = [{"event_type": "current_snapshot", "email": email, **current, "created_at": user.get("created_at")}]
    return {"current": current, "history": events}


@router.post("/assign", summary="[管理端] 手动分配 / 变更套餐")
async def assign_plan(data: AssignPlanRequest, _: dict = Depends(verify_internal_api_key)):
    db = get_db()
    plan_service = PlanService()
    plan_repo = PlanRepository()
    user_repo = UserRepository()
    grant_coord = plan_service._grant_lifecycle()

    plans = await plan_repo.get_plan_configs()
    plan = plans.get(data.plan_code)
    if not plan:
        raise HTTPException(status_code=400, detail="套餐不存在")
    if not plan.get("enabled", True) or plan.get("lifecycle_status") == "archived":
        raise HTTPException(status_code=400, detail="套餐未启用")
    if plan.get("manual_assign_enabled") is False:
        raise HTTPException(status_code=400, detail="该套餐不允许管理端手动开通")
    if plan.get("plan_family", "base") != "base" or plan.get("stackable"):
        raise HTTPException(status_code=400, detail="叠加包不能通过基础订阅入口开通")
    billing_option = None
    if _is_paid_plan(plan):
        billing_option = (plan.get("billing_options") or {}).get(data.billing_cycle)
        if not billing_option or billing_option.get("enabled") is False:
            raise HTTPException(status_code=400, detail="该支付方式未启用")
    user = await db["users"].find_one({"email": data.email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    before = _subscription_payload(user)
    now = datetime.now(timezone.utc)
    active_code = _active_plan_code(user)
    active_plan = dict(plans.get(active_code, {"code": active_code}))
    active_expires_at = _normalize_dt(_subscription_expires_at(user))
    active_is_current = bool(active_code and (not active_expires_at or active_expires_at > now))
    duration_count = 0
    duration_unit = ""
    if billing_option:
        duration_count = max(1, int(billing_option.get("duration_count") or 1))
        duration_unit = billing_option.get("duration_period") if billing_option.get("duration_period") in {"month", "year"} else "month"
    plan_validity_count = int(plan.get("validity_count") or 0)
    plan_validity_period = plan.get("validity_period", "forever")
    mode = data.change_mode or "activate_now"
    if mode == "renew" and active_code == data.plan_code and _is_paid_plan(plan):
        base = now
        current_expires = _normalize_dt(_subscription_expires_at(user))
        if current_expires and current_expires > now:
            base = current_expires
        expires_at = add_period(base, duration_unit, duration_count)
        if base <= now:
            await plan_service.activate_subscription(
                data.email,
                data.plan_code,
                started_at=now,
                expires_at=expires_at,
                billing_cycle=data.billing_cycle,
                auto_renew=data.auto_renew,
            )
        else:
            await user_repo.update_subscription(data.email, {
                "subscription_expires_at": expires_at,
                "plan_expires_at": expires_at,
                "subscription_status": "active",
                "subscription_billing_cycle": data.billing_cycle,
                "subscription_auto_renew": bool(data.auto_renew and _can_auto_renew(plan)),
                "pending_plan_code": None,
                "pending_effective_at": None,
                "pending_duration_count": None,
                "pending_duration_period": None,
                "pending_billing_cycle": None,
                "pending_requires_payment": None,
                "pending_payment_status": None,
                "pending_payment_due_at": None,
                "pending_payment_provider": None,
                "pending_schedule_event_id": None,
                "pending_from_plan_code": None,
                "pending_payment_charge_type": None,
                "pending_payment_amount_cents": None,
                "pending_payment_blocked_reason": None,
            })
            await grant_coord.apply_subscription_activation(
                data.email,
                data.plan_code,
                expires_at,
                now,
                paid_topup_enabled=_is_paid_plan(plan) and plan.get("paid_topup_enabled", True),
            )
    elif mode == "downgrade_later":
        effective_at = _normalize_dt(_subscription_expires_at(user)) or now
        if effective_at <= now:
            raise HTTPException(status_code=400, detail="只有未到期的有效订阅才能排队到期切换")
        if _is_paid_plan(plan) and not _is_paid_plan(active_plan):
            raise HTTPException(status_code=400, detail="付费套餐到期降级需要当前存在有效付费订阅")
        pending_requires_payment = bool(_is_paid_plan(plan))
        pending_payment_provider = user.get("latest_payment_provider") or "admin_manual"
        await user_repo.update_subscription(data.email, {
            "pending_plan_code": data.plan_code,
            "pending_effective_at": effective_at,
            "pending_duration_count": duration_count if _is_paid_plan(plan) else plan_validity_count,
            "pending_duration_period": duration_unit if _is_paid_plan(plan) else plan_validity_period,
            "pending_billing_cycle": data.billing_cycle if billing_option else None,
            "pending_requires_payment": pending_requires_payment,
            "pending_payment_status": "scheduled" if pending_requires_payment else None,
            "pending_payment_due_at": None,
            "pending_payment_provider": pending_payment_provider if pending_requires_payment else None,
            "pending_from_plan_code": active_code,
            "pending_payment_charge_type": CHARGE_TYPE_SCHEDULED_DOWNGRADE if pending_requires_payment else None,
            "pending_payment_amount_cents": None,
            "pending_payment_blocked_reason": None,
            "subscription_auto_renew": bool(data.auto_renew and _can_auto_renew(active_plan)),
        })
    else:
        if active_is_current and not _can_replace_immediately(active_plan, plan):
            raise HTTPException(status_code=400, detail="目标套餐优先级低于当前套餐，请使用到期降级/切换或调整套餐等级")
        expires_at = add_period(now, duration_unit, duration_count) if _is_paid_plan(plan) else PlanService._configured_expires_at_sync(plan, now)
        await plan_service.activate_subscription(
            data.email,
            data.plan_code,
            started_at=now,
            expires_at=expires_at,
            billing_cycle=data.billing_cycle if billing_option else None,
            auto_renew=data.auto_renew,
        )
    await db["admin_operation_log"].insert_one({
        "admin_email": data.admin_email,
        "action": "subscription_change",
        "target_email": data.email,
        "plan_code": data.plan_code,
        "change_mode": mode,
        "duration_count": duration_count,
        "duration_unit": duration_unit,
        "billing_cycle": data.billing_cycle if billing_option else None,
        "auto_renew": bool(data.auto_renew and billing_option),
        "created_at": now,
    })
    after_user = await db["users"].find_one({"email": data.email}, {"_id": 0, "hashed_password": 0})
    await _record_subscription_event(db, {
        "email": data.email,
        "event_type": mode,
        "operator": "admin",
        "admin_email": data.admin_email,
        "from_plan_code": before.get("plan_code"),
        "to_plan_code": data.plan_code,
        "duration_count": duration_count,
        "duration_unit": duration_unit,
        "billing_cycle": data.billing_cycle if billing_option else None,
        "auto_renew": bool(data.auto_renew and billing_option),
        "before": before,
        "after": _subscription_payload(after_user or {}),
        "created_at": now,
    })
    return {"message": f"已处理 {data.email} 的订阅操作"}


@router.post("/subscription/auto-renew", summary="[管理端] 更新自动续费开关")
async def update_auto_renew(data: AutoRenewRequest, _: dict = Depends(verify_internal_api_key)):
    db = get_db()
    plan_repo = PlanRepository()
    user_repo = UserRepository()
    user = await db["users"].find_one({"email": data.email})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    plan_code = _active_plan_code(user)
    plan = await plan_repo.get_plan_config(plan_code)
    if not _can_auto_renew(plan) and data.auto_renew:
        raise HTTPException(status_code=400, detail="免费或试用套餐不能开启自动续费")
    provider = str(user.get("latest_payment_provider") or "").strip().lower()
    provider_subscription_id = str(user.get("latest_provider_subscription_id") or "").strip()
    has_creem_subscription = provider == "creem" and bool(provider_subscription_id)
    currently_on = bool(user.get("subscription_auto_renew", False))
    # Creem 渠道代扣取消后无法程序化恢复:本地 OFF→ON 会造成「本地开启/渠道已取消」的状态分裂,
    # 一律拒绝,需用户重新订阅。本地已是 ON 的重复开启视为幂等无副作用,放行。
    if data.auto_renew and not currently_on and has_creem_subscription:
        raise HTTPException(status_code=400, detail="Creem 渠道代扣取消后无法程序化恢复，需用户重新订阅后才能开启自动续费")
    now = datetime.now(timezone.utc)
    # 关闭自动续费时 best-effort 同步取消渠道代扣(经支付端),失败只告警不阻断本地关闭
    channel_sync = None
    if not data.auto_renew and has_creem_subscription:
        try:
            result = await _post_payment_service(
                "/api/v1/payments/subscription/cancel-renewal",
                {"user_email": data.email},
            )
            channel_sync = result.get("channel_sync") or result.get("status") or "ok"
        except Exception as exc:  # noqa: BLE001 - 渠道同步失败不阻断管理端本地关闭
            channel_sync = "failed"
            logger.warning(
                "[plan-admin][需人工处理] 关闭自动续费的渠道同步失败(本地已关闭) email=%s subscription_id=%s: %s",
                data.email, provider_subscription_id, exc,
            )
    await user_repo.update_subscription(data.email, {"subscription_auto_renew": bool(data.auto_renew)})
    await db["admin_operation_log"].insert_one({
        "admin_email": data.admin_email,
        "action": "subscription_auto_renew",
        "target_email": data.email,
        "plan_code": plan_code,
        "auto_renew": bool(data.auto_renew),
        "channel_sync": channel_sync,
        "created_at": now,
    })
    await _record_subscription_event(db, {
        "email": data.email,
        "event_type": "auto_renew_updated",
        "operator": "admin",
        "admin_email": data.admin_email,
        "plan_code": plan_code,
        "auto_renew": bool(data.auto_renew),
        "channel_sync": channel_sync,
        "created_at": now,
    })
    return {"message": "自动续费状态已更新", "channel_sync": channel_sync}


@router.post("/grant-comp", summary="[管理端] 发放赠送套餐(comp:无订单/不续费/可指定有效期/重复延长)")
async def grant_comp(data: GrantCompRequest, _: dict = Depends(verify_internal_api_key)):
    try:
        return await EntitlementService().grant_comp(
            data.email,
            data.plan_code,
            start=data.start,
            end=data.end,
            admin_email=data.admin_email,
            reason=data.reason,
            idempotency_key=data.idempotency_key,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@router.post("/revoke", summary="[管理端] 撤销用户套餐权益(默认回落 free)")
async def revoke_entitlement(data: RevokeEntitlementRequest, _: dict = Depends(verify_internal_api_key)):
    try:
        return await EntitlementService().revoke(
            data.email,
            to_free=data.to_free,
            reason=data.reason,
            admin_email=data.admin_email,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@router.post("/grant-paid", summary="[内部] 支付履约授予权益(source=paid;后端权益单一写入方,P3 收敛)")
async def grant_paid(data: GrantPaidRequest, _: dict = Depends(verify_internal_api_key)):
    try:
        return await EntitlementService().grant_paid(
            data.email,
            data.plan_code,
            billing_cycle=data.billing_cycle,
            duration_count=data.duration_count,
            duration_period=data.duration_period,
            change_mode=data.change_mode,
            auto_renew=data.auto_renew,
            paid_amount_cents=data.paid_amount_cents,
            provider=data.provider,
            provider_payment_id=data.provider_payment_id,
            payment_order_id=data.payment_order_id,
            payment_event_id=data.payment_event_id,
            charge_type=data.charge_type,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@router.post("/grant-paid-topup", summary="[内部] 支付加购积分授予(paid_topup grant)")
async def grant_paid_topup(data: GrantPaidTopupRequest, _: dict = Depends(verify_internal_api_key)):
    try:
        return await EntitlementService().grant_paid_topup(
            data.email,
            data.amount,
            expires_at=data.expires_at,
            provider=data.provider,
            payment_event_id=data.payment_event_id,
            plan_code=data.plan_code,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
