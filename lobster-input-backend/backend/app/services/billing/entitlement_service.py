"""EntitlementService — 套餐权益授予的统一入口。

设计目标(套餐重构):后端作为套餐权益的**单一写入方**,消除"支付端直写 users 订阅字段 +
后端 PlanService 各写一遍"的双写漂移。按来源区分:

- source=paid: 支付渠道履约授予(P3 将把支付端直写收敛为调本服务的 grant_paid)
- source=comp: 管理员赠送(complimentary),**无支付订单、不自动续费、可指定有效期窗口、
  重复发放同套餐延长到期**,仅管理端可发起。适用于内部套餐与外部套餐的管理员赠送。

权益写入一律复用 PlanService 的既有实现(activate_subscription / grant lifecycle),
本服务只负责来源语义(comp/paid)、有效期策略(自定义窗口 / 延长)、幂等与审计,不另造写库路径。
"""
import logging
from datetime import datetime, timezone
from typing import Any, Optional

from app.core.database import get_db
from app.repositories.plan_repository import PlanRepository
from app.repositories.user_repository import UserRepository
from app.services.billing.plan_policy import FREE_PLAN_CODE
from app.services.billing.plan_service import PlanService, _as_utc, add_period
from app.services.billing.subscription_lifecycle import CREDIT_STATUS_ACTIVE

logger = logging.getLogger(__name__)

ENTITLEMENT_SOURCE_PAID = "paid"
ENTITLEMENT_SOURCE_COMP = "comp"

# subscription_callback 履约时清空的 pending 字段(P3 权益收敛:逐字段照搬 payment)
_PENDING_FIELDS = (
    "pending_plan_code", "pending_effective_at", "pending_duration_count", "pending_duration_period",
    "pending_billing_cycle", "pending_requires_payment", "pending_payment_status", "pending_payment_due_at",
    "pending_payment_provider", "pending_schedule_event_id", "pending_from_plan_code",
    "pending_payment_charge_type", "pending_payment_amount_cents", "pending_payment_blocked_reason",
)


class EntitlementService:
    def __init__(self) -> None:
        self.plan_service = PlanService()
        self.plan_repo = PlanRepository()
        self.user_repo = UserRepository()

    async def grant_comp(
        self,
        email: str,
        plan_code: str,
        *,
        start: Optional[datetime] = None,
        end: Optional[datetime] = None,
        admin_email: str = "",
        reason: str = "",
        idempotency_key: Optional[str] = None,
    ) -> dict[str, Any]:
        """管理员赠送套餐(comp)。无订单、不自动续费;可指定有效期窗口;重复发放同套餐延长到期。

        有效期:end 优先;否则按套餐 validity 计算;重复发放同套餐从 max(当前到期, now) 延长。
        """
        db = get_db()
        plan = await self.plan_repo.get_plan_config(plan_code)
        if not plan or plan.get("code") != plan_code:
            raise ValueError(f"套餐不存在: {plan_code}")
        if plan.get("lifecycle_status") == "archived":
            raise ValueError("套餐已归档,不能发放")

        if idempotency_key:
            existing = await db["subscription_events"].find_one({"idempotency_key": idempotency_key})
            if existing:
                return {"status": "duplicate", "email": email, "plan_code": plan_code}

        user = await self.user_repo.find_by_email(email)
        if not user:
            raise ValueError(f"用户不存在: {email}")

        now = datetime.now(timezone.utc)
        started = _as_utc(start) if start else now
        active_code = self.plan_service._active_plan_code(user)
        current_expires = self.plan_service._effective_subscription_expires_at(user)
        same_plan_active = bool(
            active_code == plan_code and current_expires and _as_utc(current_expires) > now
        )

        if end:
            target_expires: Optional[datetime] = _as_utc(end)
        else:
            base = _as_utc(current_expires) if same_plan_active else now
            target_expires = PlanService._configured_expires_at_sync(plan, base)

        extend = same_plan_active and not end
        if extend:
            # 同套餐延长:只延到期,不重置本周期积分(保留已用),避免赠送延期把用量清零
            await self.user_repo.update_subscription(email, {
                "subscription_expires_at": target_expires,
                "plan_expires_at": target_expires,
                "subscription_status": "active",
                "subscription_source": ENTITLEMENT_SOURCE_COMP,
                "subscription_auto_renew": False,
            })
            await self.plan_service._grant_lifecycle().apply_subscription_activation(
                email, plan_code, target_expires, now, paid_topup_enabled=False,
            )
        else:
            # 新发放/换套餐:激活并重置周期积分。comp 恒不自动续费。
            await self.plan_service.activate_subscription(
                email, plan_code, started_at=started, expires_at=target_expires, auto_renew=False,
            )
            await self.user_repo.update_subscription(email, {"subscription_source": ENTITLEMENT_SOURCE_COMP})

        await db["subscription_events"].insert_one({
            "email": email,
            "event_type": "comp_grant",
            "source": ENTITLEMENT_SOURCE_COMP,
            "plan_code": plan_code,
            "sale_type": plan.get("sale_type"),
            "expires_at": target_expires,
            "extended": extend,
            "idempotency_key": idempotency_key,
            "admin_email": admin_email,
            "reason": reason,
            "created_at": now,
        })
        await db["admin_operation_log"].insert_one({
            "admin_email": admin_email,
            "action": "comp_grant",
            "target_email": email,
            "plan_code": plan_code,
            "expires_at": target_expires,
            "extended": extend,
            "reason": reason,
            "created_at": now,
        })
        logger.info(
            "[entitlement] comp grant email=%s plan=%s expires=%s extend=%s admin=%s",
            email, plan_code, target_expires, extend, admin_email,
        )
        return {
            "status": "applied", "email": email, "plan_code": plan_code,
            "expires_at": target_expires, "extended": extend, "source": ENTITLEMENT_SOURCE_COMP,
        }

    async def revoke(
        self,
        email: str,
        *,
        to_free: bool = True,
        reason: str = "",
        admin_email: str = "",
    ) -> dict[str, Any]:
        """撤销用户当前套餐权益。to_free=True 时立即回落 free(取代埋在支付端的 downgrade 逻辑)。"""
        db = get_db()
        user = await self.user_repo.find_by_email(email)
        if not user:
            raise ValueError(f"用户不存在: {email}")
        now = datetime.now(timezone.utc)
        prev_code = self.plan_service._active_plan_code(user)
        if to_free:
            free_config = await self.plan_repo.get_plan_config(FREE_PLAN_CODE)
            await self.plan_service.activate_subscription(
                email, FREE_PLAN_CODE, started_at=now,
                expires_at=self.plan_service._configured_expires_at(free_config, now),
            )
            await self.user_repo.update_subscription(email, {
                "subscription_source": None,
                "subscription_auto_renew": False,
            })
        await db["subscription_events"].insert_one({
            "email": email,
            "event_type": "entitlement_revoke",
            "plan_code": prev_code,
            "to_free": to_free,
            "reason": reason,
            "admin_email": admin_email,
            "created_at": now,
        })
        await db["admin_operation_log"].insert_one({
            "admin_email": admin_email,
            "action": "entitlement_revoke",
            "target_email": email,
            "plan_code": prev_code,
            "reason": reason,
            "created_at": now,
        })
        logger.info(
            "[entitlement] revoke email=%s prev_plan=%s to_free=%s admin=%s",
            email, prev_code, to_free, admin_email,
        )
        return {"status": "revoked", "email": email, "previous_plan": prev_code, "to_free": to_free}

    async def grant_paid(
        self,
        email: str,
        plan_code: str,
        *,
        billing_cycle: str,
        duration_count: int,
        duration_period: str,
        change_mode: str,
        auto_renew: bool = False,
        paid_amount_cents: int = 0,
        provider: str = "",
        provider_payment_id: str = "",
        payment_order_id: str = "",
        payment_event_id: str,
        charge_type: str = "",
        now: Optional[datetime] = None,
    ) -> dict[str, Any]:
        """支付履约授予权益(source=paid)。P3 权益收敛:承接 payment subscription_callback 的权益写入,
        由后端作为唯一权益写入方。payment 只保留验签/记账/订单/退款/渠道,校验后调本方法。

        逐字段照搬 payment 语义:renew 从 max(当前到期,now) 延期、不改 plan_code、不重置周期积分;
        非 renew(new/upgrade/activate_now)换套餐并重置周期积分。幂等键 payment_event_id。
        """
        db = get_db()
        existing = await db["subscription_events"].find_one(
            {"payment_event_id": payment_event_id, "source": ENTITLEMENT_SOURCE_PAID}
        )
        if existing:
            return {"status": "duplicate", "email": email, "plan_code": plan_code}
        user = await self.user_repo.find_by_email(email)
        if not user:
            raise ValueError(f"用户不存在: {email}")
        plan = await self.plan_repo.get_plan_config(plan_code)
        if not plan or plan.get("code") != plan_code:
            raise ValueError(f"套餐不存在: {plan_code}")
        now = _as_utc(now) if now else datetime.now(timezone.utc)
        await self.plan_service._grant_lifecycle().refresh_for_user(
            email, lambda: self.user_repo.find_by_email(email), now,
        )
        auto_renew_final = bool(auto_renew and plan.get("auto_renew_supported", True))
        latest = {
            "latest_payment_event_id": payment_event_id,
            "latest_payment_provider": provider,
            "latest_payment_at": now,
            "latest_payment_order_id": payment_order_id or payment_event_id,
            "latest_provider_payment_id": provider_payment_id or "",
        }
        pending_clear = {field: None for field in _PENDING_FIELDS}

        if change_mode == "renew":
            base = _as_utc(user.get("subscription_expires_at") or user.get("plan_expires_at")) or now
            if base < now:
                base = now
            expires_at = add_period(base, duration_period, duration_count)
            entitlement_started_at = base
            await self.user_repo.update_subscription(email, {
                "subscription_expires_at": expires_at,
                "plan_expires_at": expires_at,
                "subscription_status": "active",
                "subscription_billing_cycle": billing_cycle,
                "subscription_auto_renew": auto_renew_final,
                "subscription_source": ENTITLEMENT_SOURCE_PAID,
                **pending_clear,
                **latest,
            })
        else:
            credits = int(plan.get("credits", 0) or 0)
            period_end = add_period(now, plan.get("reset_period", "month"), 1)
            expires_at = add_period(now, duration_period, duration_count)
            if period_end > expires_at:
                period_end = expires_at
            entitlement_started_at = now
            await self.user_repo.update_subscription(email, {
                # tier/plan_code 为兼容旧字段(部分直读处依赖),与 payment 履约逐字段等价,一并更新
                "tier": plan_code,
                "plan_code": plan_code,
                "subscription_plan_code": plan_code,
                "subscription_started_at": now,
                "subscription_expires_at": expires_at,
                "subscription_status": "active",
                "subscription_billing_cycle": billing_cycle,
                "subscription_auto_renew": auto_renew_final,
                "plan_started_at": now,
                "plan_expires_at": expires_at,
                "plan_current_period_start": now,
                "plan_current_period_end": period_end,
                "plan_credits_total": credits,
                "plan_credits_used": 0,
                "credits_total": credits,
                "credits_used": 0,
                "credits_reset_at": period_end,
                "subscription_source": ENTITLEMENT_SOURCE_PAID,
                **pending_clear,
                **latest,
            })
        await self.plan_service._grant_lifecycle().apply_subscription_activation(
            email, plan_code, expires_at, now, paid_topup_enabled=plan.get("paid_topup_enabled", True),
        )
        await db["subscription_events"].insert_one({
            "email": email,
            "event_type": "paid_grant",
            "source": ENTITLEMENT_SOURCE_PAID,
            "payment_event_id": payment_event_id,
            "plan_code": plan_code,
            "change_mode": change_mode,
            "charge_type": charge_type,
            "billing_cycle": billing_cycle,
            "paid_amount_cents": paid_amount_cents,
            "expires_at": expires_at,
            "created_at": now,
        })
        logger.info(
            "[entitlement] paid grant email=%s plan=%s change_mode=%s expires=%s",
            email, plan_code, change_mode, expires_at,
        )
        return {
            "status": "applied", "change_mode": change_mode, "plan_code": plan_code,
            "subscription_expires_at": expires_at, "entitlement_started_at": entitlement_started_at,
            "entitlement_expires_at": expires_at, "source": ENTITLEMENT_SOURCE_PAID,
        }

    async def grant_paid_topup(
        self,
        email: str,
        amount: int,
        *,
        expires_at: datetime,
        provider: str = "",
        payment_event_id: str,
        plan_code: str = "",
        now: Optional[datetime] = None,
    ) -> dict[str, Any]:
        """支付加购积分授予(paid_topup grant)。承接 payment credits_topup_callback 的 credit_grants 写入。

        校验(付费套餐/未到期/积分用完)由 payment 侧完成;本方法只做权益授予,幂等键 payment_event_id。
        """
        db = get_db()
        existing = await db["subscription_events"].find_one(
            {"payment_event_id": payment_event_id, "source": ENTITLEMENT_SOURCE_PAID, "event_type": "paid_topup_grant"}
        )
        if existing:
            return {"status": "duplicate", "email": email}
        if amount <= 0:
            raise ValueError("加购积分必须大于 0")
        now = _as_utc(now) if now else datetime.now(timezone.utc)
        expires_at = _as_utc(expires_at)
        grant_doc = {
            "user_email": email,
            "source": "paid_topup",
            "credit_type": "paid_topup",
            "status": CREDIT_STATUS_ACTIVE,
            "amount_total": int(amount),
            "amount_used": 0,
            "expires_at": expires_at,
            "metadata": {
                "provider": provider,
                "payment_event_id": payment_event_id,
                "expires_at_source": "subscription_expires_at",
                "subscription_plan_code": plan_code,
            },
            "created_at": now,
            "updated_at": now,
        }
        insert_result = await db["credit_grants"].insert_one(grant_doc)
        await db["subscription_events"].insert_one({
            "email": email, "event_type": "paid_topup_grant", "source": ENTITLEMENT_SOURCE_PAID,
            "payment_event_id": payment_event_id, "amount": int(amount), "expires_at": expires_at,
            "created_at": now,
        })
        logger.info("[entitlement] paid topup grant email=%s amount=%s expires=%s", email, amount, expires_at)
        return {
            "status": "applied", "credit_type": "paid_topup", "amount": int(amount),
            "expires_at": expires_at, "grant_id": str(insert_result.inserted_id),
        }
