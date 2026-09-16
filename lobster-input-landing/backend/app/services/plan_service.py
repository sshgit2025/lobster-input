"""PlanService — 新用户套餐初始化 + 个人中心积分只读聚合。

init_user_plan 与主后端 PlanService.init_user_plan/activate_subscription 写入的
套餐字段一致（试用套餐、周期、积分）。get_points 是只读聚合（不触发任何计费
副作用），按 "status=active 且未过期" 口径展示积分，与主后端 _build_credit_items
的展示结构对齐。
"""
import logging
from datetime import datetime, timedelta, timezone

from dateutil.relativedelta import relativedelta

from app.repositories.system_config_repository import SystemConfigRepository
from app.repositories.user_repository import UserRepository
from app.repositories.credit_grant_repository import (
    CreditGrantRepository,
    BONUS_CREDIT_TYPE,
    PAID_TOPUP_CREDIT_TYPE,
)

logger = logging.getLogger("lobster_landing.plan")

TRIAL_PLAN_CODE = "trial"
SUBSCRIPTION_STATUS_ACTIVE = "active"


def _as_utc(dt: datetime) -> datetime:
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt


def add_period(start: datetime, period: str, count: int = 1) -> datetime:
    start = _as_utc(start)
    count = max(1, int(count or 1))
    if period == "day":
        return start + timedelta(days=count)
    if period == "week":
        return start + timedelta(weeks=count)
    if period == "year":
        return start + relativedelta(years=count)
    return start + relativedelta(months=count)


def _configured_expires_at(config: dict, started_at: datetime):
    period = config.get("validity_period", "forever")
    if period == "forever":
        return None
    return add_period(started_at, period, int(config.get("validity_count") or 1))


class PlanService:
    def __init__(self):
        self.config_repo = SystemConfigRepository()
        self.user_repo = UserRepository()
        self.grant_repo = CreditGrantRepository()

    async def init_user_plan(self, email: str, registered_at: datetime) -> None:
        """新用户注册时初始化试用套餐（与主后端 activate_subscription(trial) 写入一致）。"""
        started = _as_utc(registered_at)
        config = await self.config_repo.get_plan_config(TRIAL_PLAN_CODE)
        expires_at = _configured_expires_at(config, started)
        period_end = add_period(started, config.get("reset_period", "month"), 1)
        if expires_at and period_end > expires_at:
            period_end = expires_at
        credits = int(config.get("credits", 0) or 0)
        doc = {
            "subscription_plan_code": TRIAL_PLAN_CODE,
            "subscription_started_at": started,
            "subscription_expires_at": expires_at,
            "subscription_status": SUBSCRIPTION_STATUS_ACTIVE,
            "subscription_billing_cycle": None,
            "subscription_auto_renew": False,
            "plan_code": TRIAL_PLAN_CODE,
            "plan_started_at": started,
            "plan_expires_at": expires_at,
            "plan_current_period_start": started,
            "plan_current_period_end": period_end,
            "plan_credits_total": credits,
            "plan_credits_used": 0,
            "credits_total": credits,
            "credits_used": 0,
            "credits_reset_at": period_end,
        }
        await self.user_repo.assign_plan(email, doc)
        logger.info("[plan] init_user_plan email=%s plan=trial", email)

    async def get_points(self, email: str) -> dict:
        """只读聚合用户积分（不触发周期重置等计费副作用）。"""
        registration_enabled = await self.config_repo.get_registration_enabled()
        invite_code_enabled = await self.config_repo.get_invite_code_enabled()
        show_invite_codes_enabled = await self.config_repo.get_show_invite_codes_enabled()
        show_subscription_module_enabled = await self.config_repo.get_show_subscription_module_enabled()

        user = await self.user_repo.find_by_email(email)
        empty_switches = {
            "registration_enabled": registration_enabled,
            "invite_code_enabled": invite_code_enabled,
            "show_invite_codes_enabled": show_invite_codes_enabled,
            "show_subscription_module_enabled": show_subscription_module_enabled,
        }
        if not user:
            return {
                "tier": "none",
                "credits_total": 0,
                "credits_used": 0,
                "credits_remaining": 0,
                "credits_reset_at": None,
                "bonus_credits_remaining": 0,
                "paid_topup_credits_remaining": 0,
                "credit_items": [],
                "plan_expires_at": None,
                "subscription_expires_at": None,
                "subscription_billing_cycle": None,
                "subscription_auto_renew": False,
                **empty_switches,
            }

        tier = user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier") or "none"
        credit_items = await self._build_credit_items(email, user, tier)
        credits_total = sum(int(item["credits_total"]) for item in credit_items)
        credits_used = sum(int(item["credits_used"]) for item in credit_items)
        credits_remaining = sum(int(item["credits_remaining"]) for item in credit_items)
        bonus_remaining = await self.grant_repo.get_available_total(email, credit_type=BONUS_CREDIT_TYPE)
        paid_topup_remaining = await self.grant_repo.get_available_total(email, credit_type=PAID_TOPUP_CREDIT_TYPE)
        subscription_expires_at = user.get("subscription_expires_at", user.get("plan_expires_at"))
        credits_reset_at = user.get("plan_current_period_end") or user.get("credits_reset_at")

        return {
            "tier": tier,
            "credits_total": credits_total,
            "credits_used": credits_used,
            "credits_remaining": credits_remaining,
            "credits_reset_at": credits_reset_at,
            "bonus_credits_remaining": bonus_remaining,
            "paid_topup_credits_remaining": paid_topup_remaining,
            "credit_items": credit_items,
            "plan_expires_at": subscription_expires_at,
            "subscription_expires_at": subscription_expires_at,
            "subscription_billing_cycle": user.get("subscription_billing_cycle"),
            "subscription_auto_renew": bool(user.get("subscription_auto_renew", False)),
            **empty_switches,
        }

    async def _build_credit_items(self, email: str, user: dict, tier: str) -> list[dict]:
        items: list[dict] = []
        plan_total = int(user.get("plan_credits_total", user.get("credits_total", 0)) or 0)
        plan_used = int(user.get("plan_credits_used", user.get("credits_used", 0)) or 0)
        if user.get("subscription_status", "active") == "active" and plan_total > 0:
            items.append({
                "id": f"plan:{tier}",
                "type": "plan",
                "source": tier,
                "label": tier,
                "credits_total": plan_total,
                "credits_used": min(plan_used, plan_total),
                "credits_remaining": max(0, plan_total - plan_used),
                "expires_at": user.get("subscription_expires_at", user.get("plan_expires_at")),
            })
        for grant in await self.grant_repo.list_active_grants(email):
            total = int(grant.get("amount_total", 0) or 0)
            used = int(grant.get("amount_used", 0) or 0)
            credit_type = grant.get("credit_type") or "bonus"
            source = grant.get("source") or credit_type
            items.append({
                "id": f"grant:{grant.get('_id')}",
                "type": credit_type,
                "source": source,
                "label": source,
                "credits_total": total,
                "credits_used": min(used, total),
                "credits_remaining": max(0, total - used),
                "expires_at": grant.get("expires_at"),
            })
        return items
