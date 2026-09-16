"""支付购买订阅入口：供未来支付回调复用。"""
from datetime import datetime, timezone
import hashlib
from typing import Any
from uuid import uuid4

from app.core.database import get_db
from app.repositories.user_repository import UserRepository
from app.services.billing.plan_service import PlanService, add_period
from app.services.billing.plan_policy import PlanPolicy
from pymongo.errors import DuplicateKeyError

SETTLEMENT_FULL_PRICE = "full_price"
SETTLEMENT_PRORATED_DIFFERENCE = "prorated_difference"
SETTLEMENT_MODES = {SETTLEMENT_FULL_PRICE, SETTLEMENT_PRORATED_DIFFERENCE}
CHARGE_TYPE_MANUAL_PURCHASE = "manual_purchase"
CHARGE_TYPE_AUTO_RENEWAL = "auto_renewal"
CHARGE_TYPE_SCHEDULED_DOWNGRADE = "scheduled_downgrade"
CHARGE_TYPES = {
    CHARGE_TYPE_MANUAL_PURCHASE,
    CHARGE_TYPE_AUTO_RENEWAL,
    CHARGE_TYPE_SCHEDULED_DOWNGRADE,
}


class SubscriptionPurchaseService:
    """把支付成功事件转换成受限的订阅权益变更。"""

    def __init__(self):
        self.plan_service = PlanService()
        self.user_repo = UserRepository()

    @property
    def events_col(self):
        return get_db()["subscription_purchase_events"]

    @property
    def refunds_col(self):
        return get_db()["subscription_refund_events"]

    async def ensure_indexes(self) -> None:
        await self.events_col.create_index("payment_event_id", unique=True)
        await self.events_col.create_index([("user_email", 1), ("created_at", -1)])
        await self.events_col.create_index([("provider", 1), ("provider_payment_id", 1)])
        await self.events_col.create_index([("payment_order_id", 1), ("created_at", -1)])
        await self.refunds_col.create_index("refund_event_id", unique=True)
        await self.refunds_col.create_index("original_payment_event_id")
        await self.refunds_col.create_index([("provider", 1), ("provider_refund_id", 1)])
        await self.refunds_col.create_index([("user_email", 1), ("created_at", -1)])

    async def apply_paid_purchase(
        self,
        *,
        payment_event_id: str,
        user_email: str,
        plan_code: str,
        billing_cycle: str,
        provider: str,
        settlement_mode: str = SETTLEMENT_FULL_PRICE,
        paid_amount_cents: int | None = None,
        payment_order_id: str | None = None,
        provider_payment_id: str | None = None,
        payment_channel: str | None = None,
        raw_event: dict[str, Any] | None = None,
        auto_renew: bool = False,
        charge_type: str = CHARGE_TYPE_MANUAL_PURCHASE,
    ) -> dict:
        """支付成功后发放权益；仅允许付费套餐续费或升级。"""
        if not payment_event_id:
            raise ValueError("payment_event_id is required")
        charge_type = self._normalize_charge_type(charge_type)
        plan_config = await self.plan_service.plan_repo.get_plan_config(plan_code)
        target_policy = PlanPolicy.from_config(plan_config, plan_code)
        if not target_policy.can_self_checkout_subscription:
            raise ValueError("plan is not available for paid subscription checkout")
        billing_option = (plan_config.get("billing_options") or {}).get(billing_cycle)
        if not billing_option or billing_option.get("enabled") is False:
            raise ValueError("billing cycle is not available for this plan")
        duration_count = max(1, int(billing_option.get("duration_count") or 1))
        duration_period = billing_option.get("duration_period") or "month"
        price_cents = 0 if paid_amount_cents is None else int(paid_amount_cents)
        paid_amount = price_cents
        settlement_mode = self._normalize_settlement_mode(settlement_mode)
        provider = self._normalize_provider(provider)
        if paid_amount < 0:
            raise ValueError("paid_amount_cents must be non-negative")

        existing = await self.events_col.find_one({"payment_event_id": payment_event_id})
        if existing:
            return {"status": "duplicate", "subscription": existing.get("subscription", {})}

        user = await self.user_repo.find_by_email(user_email)
        if not user:
            raise ValueError("user not found")
        user = await self.plan_service.check_and_reset_credits(user_email, user)

        active_code = self.plan_service._active_plan_code(user) or "free"
        if active_code == "trial":
            active_code = "free" if self._is_expired(user) else "trial"
        active_plan_config = await self.plan_service.plan_repo.get_plan_config(active_code)
        active_policy = PlanPolicy.from_config(active_plan_config, active_code)
        mode = self._resolve_mode(
            user,
            active_policy,
            active_plan_config,
            target_policy,
            billing_cycle,
            duration_count,
            duration_period,
        )
        previous_payment_event = await self._active_payment_event(user, active_policy)
        previous_subscription = self._snapshot(user)
        event_now = datetime.now(timezone.utc)
        entitlement_started_at = self._entitlement_started_at(user, mode, event_now)
        entitlement_expires_at = add_period(entitlement_started_at, duration_period, duration_count)
        if not await self._insert_processing_event(
            payment_event_id=payment_event_id,
            provider=provider,
            provider_payment_id=provider_payment_id or "",
            payment_order_id=payment_order_id or payment_event_id,
            payment_channel=payment_channel or "",
            user_email=user_email,
            from_plan_code=active_policy.code,
            plan_code=plan_code,
            duration_count=duration_count,
            duration_period=duration_period,
            billing_cycle=billing_cycle,
            price_cents=price_cents,
            paid_amount_cents=paid_amount,
            auto_renew=auto_renew,
            charge_type=charge_type,
            change_mode=mode,
            settlement_mode=settlement_mode,
            previous_payment_event_id=(previous_payment_event or {}).get("payment_event_id"),
            previous_subscription=previous_subscription,
            entitlement_started_at=entitlement_started_at,
            entitlement_expires_at=entitlement_expires_at,
            raw_event=raw_event,
        ):
            existing = await self.events_col.find_one({"payment_event_id": payment_event_id})
            return {"status": "duplicate", "subscription": (existing or {}).get("subscription", {})}
        subscription = await self.plan_service.change_subscription(
            user_email,
            plan_code,
            duration_count=max(1, int(duration_count or 1)),
            duration_period=duration_period,
            billing_cycle=billing_cycle,
            auto_renew=auto_renew,
            change_mode=mode,
        )
        snapshot = self._snapshot(subscription)
        now = datetime.now(timezone.utc)
        await self.user_repo.update_subscription(user_email, {
            "latest_payment_event_id": payment_event_id,
            "latest_payment_provider": provider,
            "latest_payment_at": now,
            "latest_payment_order_id": payment_order_id or payment_event_id,
            "latest_provider_payment_id": provider_payment_id or "",
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
        refund_result = await self._auto_refund_previous_subscription(
            payment_event_id=payment_event_id,
            user_email=user_email,
            settlement_mode=settlement_mode,
            change_mode=mode,
            previous_event=previous_payment_event,
            now=now,
        )
        await self.events_col.update_one(
            {"payment_event_id": payment_event_id},
            {"$set": {
                "status": "applied",
                "subscription": snapshot,
                "upgrade_refund": refund_result,
                "entitlement_started_at": entitlement_started_at,
                "entitlement_expires_at": snapshot.get("subscription_expires_at") or entitlement_expires_at,
                "applied_at": now,
                "updated_at": now,
            }},
        )
        return {"status": "applied", "change_mode": mode, "subscription": snapshot, "upgrade_refund": refund_result}

    async def schedule_paid_downgrade(
        self,
        *,
        schedule_event_id: str | None,
        user_email: str,
        plan_code: str,
        billing_cycle: str,
        provider: str,
        raw_event: dict[str, Any] | None = None,
    ) -> dict:
        """付费降级只排队，不立即扣费；到期扣费成功后再调用 apply_paid_purchase 生效。"""
        plan_config = await self.plan_service.plan_repo.get_plan_config(plan_code)
        target_policy = PlanPolicy.from_config(plan_config, plan_code)
        if not target_policy.can_self_checkout_subscription:
            raise ValueError("paid downgrade target is not available for subscription checkout")
        billing_option = (plan_config.get("billing_options") or {}).get(billing_cycle)
        if not billing_option or billing_option.get("enabled") is False:
            raise ValueError("billing cycle is not available for this plan")
        provider = self._normalize_provider(provider)

        user = await self.user_repo.find_by_email(user_email)
        if not user:
            raise ValueError("user not found")
        user = await self.plan_service.check_and_reset_credits(user_email, user)
        active_code = self.plan_service._active_plan_code(user) or "free"
        active_plan_config = await self.plan_service.plan_repo.get_plan_config(active_code)
        active_policy = PlanPolicy.from_config(active_plan_config, active_code)
        expires_at = self._subscription_expires_at(user)
        if not active_policy.paid or not expires_at or self._is_expired(user):
            raise ValueError("downgrade scheduling requires an active paid subscription")
        if target_policy.rank >= active_policy.rank:
            raise ValueError("target plan is not a downgrade")

        schedule_event_id = schedule_event_id or f"sched_{uuid4().hex}"
        payment_event_id = f"schedule:{schedule_event_id}"
        existing = await self.events_col.find_one({"payment_event_id": payment_event_id})
        if existing:
            return {"status": "duplicate", "pending": self._pending_snapshot(user)}

        duration_count = max(1, int(billing_option.get("duration_count") or 1))
        duration_period = billing_option.get("duration_period") or "month"
        now = datetime.now(timezone.utc)
        try:
            await self.events_col.insert_one({
                "payment_event_id": payment_event_id,
                "event_type": "downgrade_scheduled",
                "status": "scheduled",
                "provider": provider,
                "user_email": user_email,
                "from_plan_code": active_policy.code,
                "plan_code": plan_code,
                "duration_count": duration_count,
                "duration_period": duration_period,
                "billing_cycle": billing_cycle,
                "price_cents": 0,
                "raw_event": raw_event or {},
                "created_at": now,
                "updated_at": now,
            })
        except DuplicateKeyError:
            return {"status": "duplicate", "pending": self._pending_snapshot(user)}

        await self.user_repo.update_subscription(user_email, {
            "pending_plan_code": plan_code,
            "pending_effective_at": expires_at,
            "pending_duration_count": duration_count,
            "pending_duration_period": duration_period,
            "pending_billing_cycle": billing_cycle,
            "pending_requires_payment": True,
            "pending_payment_status": "scheduled",
            "pending_payment_provider": provider,
            "pending_schedule_event_id": schedule_event_id,
            "pending_from_plan_code": active_policy.code,
            "pending_payment_charge_type": CHARGE_TYPE_SCHEDULED_DOWNGRADE,
            "pending_payment_amount_cents": None,
            "pending_payment_blocked_reason": None,
        })
        refreshed = await self.user_repo.find_by_email(user_email)
        return {"status": "scheduled", "pending": self._pending_snapshot(refreshed or {})}

    async def apply_due_auto_charge(
        self,
        *,
        user_email: str,
        user: dict | None = None,
        now: datetime | None = None,
    ) -> dict:
        """⚠️ DEPRECATED / 已停用，禁止重新接入本地权益发放路径。

        本方法以 price_cents=0 在本地"零元续期"发放整周期权益，是 2026-05 mock 计费生命周期遗留。
        渠道化（2026-07-12，见 docs/auto-renewal-strategy.md）后自动续费完全由渠道驱动：
        Creem webhook 续期、Apple 订阅组续订、zpay 到期转 free。_try_due_auto_charge 已不再调用本方法。
        保留函数体仅为历史事件回溯参考；如需接入真实主动代扣，必须先发起渠道扣款、以实扣额记账后才可发放权益。
        """
        now = now or datetime.now(timezone.utc)
        user = dict(user or await self.user_repo.find_by_email(user_email) or {})
        if not user:
            return {"status": "not_found"}

        expires_at = self._subscription_expires_at(user)
        if not expires_at:
            return {"status": "not_due", "reason": "no_subscription_expiry"}
        expires_at = expires_at.replace(tzinfo=timezone.utc) if expires_at.tzinfo is None else expires_at
        if expires_at > now:
            return {"status": "not_due", "reason": "subscription_not_expired"}

        active_code = self.plan_service._active_plan_code(user) or "free"
        active_plan_config = await self.plan_service.plan_repo.get_plan_config(active_code)
        active_policy = PlanPolicy.from_config(active_plan_config, active_code)
        if not user.get("subscription_auto_renew") or not active_policy.can_auto_renew:
            return {"status": "skipped", "reason": "auto_renew_disabled"}

        pending_at = user.get("pending_effective_at")
        pending_due = bool(
            user.get("pending_requires_payment")
            and user.get("pending_plan_code")
            and pending_at
            and now >= self._as_utc(pending_at)
        )
        if pending_due:
            target_code = user.get("pending_plan_code")
            billing_cycle = user.get("pending_billing_cycle") or "monthly"
            charge_type = CHARGE_TYPE_SCHEDULED_DOWNGRADE
            change_mode = "activate_now"
        else:
            target_code = active_policy.code
            billing_cycle = user.get("subscription_billing_cycle") or "monthly"
            charge_type = CHARGE_TYPE_AUTO_RENEWAL
            change_mode = "renew"

        target_plan_config = await self.plan_service.plan_repo.get_plan_config(target_code)
        target_policy = PlanPolicy.from_config(target_plan_config, target_code)
        if not target_policy.can_self_checkout_subscription:
            await self.user_repo.update_subscription(user_email, {
                "last_auto_charge_status": "failed",
                "last_auto_charge_reason": "target_plan_not_chargeable",
                "last_auto_charge_at": now,
            })
            return {"status": "failed", "reason": "target_plan_not_chargeable"}
        billing_option = (target_plan_config.get("billing_options") or {}).get(billing_cycle)
        if not billing_option or billing_option.get("enabled") is False:
            await self.user_repo.update_subscription(user_email, {
                "last_auto_charge_status": "failed",
                "last_auto_charge_reason": "billing_cycle_unavailable",
                "last_auto_charge_at": now,
            })
            return {"status": "failed", "reason": "billing_cycle_unavailable"}

        duration_count = max(1, int(billing_option.get("duration_count") or 1))
        duration_period = billing_option.get("duration_period") or "month"
        price_cents = 0
        provider = self._normalize_provider(
            user.get("pending_payment_provider") or user.get("latest_payment_provider") or "mock_auto"
        )
        payment_event_id = self._auto_charge_event_id(
            user_email=user_email,
            charge_type=charge_type,
            expires_at=expires_at,
            target_plan_code=target_policy.code,
            billing_cycle=billing_cycle,
        )
        existing = await self.events_col.find_one({"payment_event_id": payment_event_id})
        if existing:
            return {"status": "duplicate", "subscription": existing.get("subscription", {})}

        previous_subscription = self._snapshot(user)
        entitlement_started_at = now
        entitlement_expires_at = add_period(entitlement_started_at, duration_period, duration_count)
        if not await self._insert_processing_event(
            payment_event_id=payment_event_id,
            provider=provider,
            provider_payment_id=payment_event_id,
            payment_order_id=payment_event_id,
            payment_channel="auto_debit",
            user_email=user_email,
            from_plan_code=active_policy.code,
            plan_code=target_policy.code,
            duration_count=duration_count,
            duration_period=duration_period,
            billing_cycle=billing_cycle,
            price_cents=price_cents,
            paid_amount_cents=price_cents,
            auto_renew=True,
            charge_type=charge_type,
            change_mode=change_mode,
            settlement_mode=SETTLEMENT_FULL_PRICE,
            previous_payment_event_id=user.get("latest_payment_event_id"),
            previous_subscription=previous_subscription,
            entitlement_started_at=entitlement_started_at,
            entitlement_expires_at=entitlement_expires_at,
            raw_event={
                "source": "subscription_auto_billing",
                "pending_schedule_event_id": user.get("pending_schedule_event_id"),
                "original_subscription_expires_at": expires_at,
            },
        ):
            existing = await self.events_col.find_one({"payment_event_id": payment_event_id})
            return {"status": "duplicate", "subscription": (existing or {}).get("subscription", {})}

        subscription = await self.plan_service.change_subscription(
            user_email,
            target_policy.code,
            duration_count=duration_count,
            duration_period=duration_period,
            billing_cycle=billing_cycle,
            auto_renew=True,
            change_mode=change_mode,
        )
        snapshot = self._snapshot(subscription)
        await self.user_repo.update_subscription(user_email, {
            "latest_payment_event_id": payment_event_id,
            "latest_payment_provider": provider,
            "latest_payment_at": now,
            "latest_payment_order_id": payment_event_id,
            "latest_provider_payment_id": payment_event_id,
            "last_auto_charge_status": "applied",
            "last_auto_charge_type": charge_type,
            "last_auto_charge_at": now,
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
        await self.events_col.update_one(
            {"payment_event_id": payment_event_id},
            {"$set": {
                "status": "applied",
                "subscription": snapshot,
                "upgrade_refund": {"status": "not_required", "reason": charge_type},
                "entitlement_started_at": entitlement_started_at,
                "entitlement_expires_at": snapshot.get("subscription_expires_at") or entitlement_expires_at,
                "applied_at": now,
                "updated_at": now,
            }},
        )
        return {"status": "applied", "charge_type": charge_type, "change_mode": change_mode, "subscription": snapshot}

    async def apply_refund(
        self,
        *,
        refund_event_id: str,
        original_payment_event_id: str,
        provider: str,
        amount_cents: int | None = None,
        provider_refund_id: str | None = None,
        refund_order_id: str | None = None,
        raw_event: dict[str, Any] | None = None,
        revoke_entitlement: bool = False,
    ) -> dict:
        """记录退款通知；可选撤销仍由该支付事件提供的当前权益。"""
        if not refund_event_id:
            raise ValueError("refund_event_id is required")
        existing = await self.refunds_col.find_one({"refund_event_id": refund_event_id})
        if existing:
            return {"status": "duplicate", "refund": self._strip_id(existing)}

        original = await self.events_col.find_one({"payment_event_id": original_payment_event_id})
        if not original or original.get("status") != "applied":
            raise ValueError("original payment event is not applied")
        provider = self._normalize_provider(provider)
        original_provider = self._normalize_provider(original.get("provider"))
        if provider != original_provider:
            raise ValueError("refund provider must match the original payment provider")
        user_email = original.get("user_email")
        price_cents = int(original.get("price_cents", 0) or 0)
        refunded_cents = int(original.get("refunded_cents", 0) or 0)
        refundable_cents = max(0, price_cents - refunded_cents)
        amount = refundable_cents if amount_cents is None else int(amount_cents)
        if amount <= 0:
            raise ValueError("refund amount must be positive")
        if amount > refundable_cents:
            raise ValueError("refund amount exceeds refundable balance")
        now = datetime.now(timezone.utc)
        refund_doc = {
            "refund_event_id": refund_event_id,
            "refund_order_id": refund_order_id or refund_event_id,
            "provider_refund_id": provider_refund_id or "",
            "original_payment_event_id": original_payment_event_id,
            "original_payment_order_id": original.get("payment_order_id") or original_payment_event_id,
            "original_provider_payment_id": original.get("provider_payment_id") or "",
            "provider": provider,
            "user_email": user_email,
            "plan_code": original.get("plan_code"),
            "amount_cents": amount,
            "status": "applied",
            "revoke_entitlement": bool(revoke_entitlement),
            "raw_event": raw_event or {},
            "created_at": now,
            "updated_at": now,
        }
        try:
            await self.refunds_col.insert_one(dict(refund_doc))
        except DuplicateKeyError:
            existing = await self.refunds_col.find_one({"refund_event_id": refund_event_id})
            return {"status": "duplicate", "refund": self._strip_id(existing or {})}

        await self.events_col.update_one(
            {"payment_event_id": original_payment_event_id},
            {"$inc": {"refunded_cents": amount}, "$set": {
                "refund_status": "refunded" if amount >= refundable_cents else "partially_refunded",
                "updated_at": now,
            }},
        )
        if revoke_entitlement and user_email:
            user = await self.user_repo.find_by_email(user_email)
            if user and user.get("latest_payment_event_id") == original_payment_event_id:
                free_config = await self.plan_service.plan_repo.get_plan_config("free")
                await self.plan_service.activate_subscription(
                    user_email,
                    "free",
                    started_at=now,
                    expires_at=self.plan_service._configured_expires_at(free_config, now),
                )
                await self.user_repo.update_subscription(user_email, {
                    "latest_payment_event_id": None,
                    "latest_payment_provider": None,
                    "latest_payment_at": None,
                })
        refund_doc.pop("_id", None)
        return {"status": "applied", "refund": refund_doc}

    async def _insert_processing_event(self, **fields) -> bool:
        now = datetime.now(timezone.utc)
        try:
            await self.events_col.insert_one({
                **fields,
                "event_type": "subscription_purchase",
                "status": "processing",
                "raw_event": fields.get("raw_event") or {},
                "auto_renew": bool(fields.get("auto_renew")),
                "charge_type": self._normalize_charge_type(fields.get("charge_type")),
                "created_at": now,
                "updated_at": now,
            })
            return True
        except DuplicateKeyError:
            return False

    @classmethod
    def _resolve_mode(
        cls,
        user: dict,
        active_policy: PlanPolicy,
        active_plan_config: dict,
        target_policy: PlanPolicy,
        target_billing_cycle: str,
        target_duration_count: int,
        target_duration_period: str,
    ) -> str:
        if active_policy.code == target_policy.code:
            active_cycle = user.get("subscription_billing_cycle")
            if active_cycle == target_billing_cycle:
                return "renew"
            active_option = (active_plan_config.get("billing_options") or {}).get(active_cycle or "")
            active_months = cls._duration_months(
                active_option.get("duration_period") if active_option else None,
                active_option.get("duration_count") if active_option else None,
            )
            target_months = cls._duration_months(target_duration_period, target_duration_count)
            if not active_cycle and target_months <= active_months:
                return "renew"
            if target_months > active_months:
                return "cycle_upgrade"
            raise ValueError("paid billing-cycle downgrade must be scheduled and charged at period end")
        if not target_policy.can_replace_immediately(active_policy):
            raise ValueError("paid downgrade must be scheduled and charged at period end")
        return "activate_now"

    async def _active_payment_event(self, user: dict, active_policy: PlanPolicy) -> dict | None:
        if not active_policy.paid or self._is_expired(user):
            return None
        payment_event_id = user.get("latest_payment_event_id")
        if payment_event_id:
            event = await self.events_col.find_one({
                "payment_event_id": payment_event_id,
                "status": "applied",
            })
            if event:
                return event
        cursor = self.events_col.find({
            "user_email": user.get("email"),
            "plan_code": active_policy.code,
            "status": "applied",
            "event_type": "subscription_purchase",
        }).sort("applied_at", -1).limit(1)
        rows = await cursor.to_list(length=1)
        return rows[0] if rows else None

    async def _auto_refund_previous_subscription(
        self,
        *,
        payment_event_id: str,
        user_email: str,
        settlement_mode: str,
        change_mode: str,
        previous_event: dict | None,
        now: datetime,
    ) -> dict | None:
        if settlement_mode != SETTLEMENT_FULL_PRICE:
            return {"status": "not_required", "reason": "prorated_difference"}
        if change_mode not in {"activate_now", "cycle_upgrade"}:
            return {"status": "not_required", "reason": change_mode}
        if not previous_event:
            return {"status": "not_required", "reason": "missing_previous_payment"}
        amount = self._unused_refund_amount(previous_event, now)
        if amount <= 0:
            return {"status": "not_required", "reason": "no_refundable_balance"}
        refund_event_id = f"auto_refund:{payment_event_id}:{previous_event.get('payment_event_id')}"
        result = await self.apply_refund(
            refund_event_id=refund_event_id,
            original_payment_event_id=previous_event["payment_event_id"],
            provider=previous_event.get("provider") or "unknown",
            amount_cents=amount,
            refund_order_id=refund_event_id,
            raw_event={
                "reason": "subscription_upgrade_full_price",
                "new_payment_event_id": payment_event_id,
                "user_email": user_email,
            },
            revoke_entitlement=False,
        )
        refund = result.get("refund", {})
        return {
            "status": result.get("status"),
            "refund_event_id": refund.get("refund_event_id"),
            "original_payment_event_id": refund.get("original_payment_event_id"),
            "provider": refund.get("provider"),
            "amount_cents": refund.get("amount_cents"),
        }

    @staticmethod
    def _unused_refund_amount(event: dict, now: datetime) -> int:
        price_cents = int(event.get("price_cents", 0) or 0)
        refunded_cents = int(event.get("refunded_cents", 0) or 0)
        refundable_cents = max(0, price_cents - refunded_cents)
        if refundable_cents <= 0:
            return 0
        subscription = event.get("subscription") or {}
        started_at = (
            event.get("entitlement_started_at")
            or subscription.get("subscription_started_at")
            or event.get("applied_at")
            or event.get("created_at")
        )
        expires_at = event.get("entitlement_expires_at") or subscription.get("subscription_expires_at")
        if not started_at or not expires_at:
            return 0
        started_at = started_at.replace(tzinfo=timezone.utc) if started_at.tzinfo is None else started_at
        expires_at = expires_at.replace(tzinfo=timezone.utc) if expires_at.tzinfo is None else expires_at
        now = now.replace(tzinfo=timezone.utc) if now.tzinfo is None else now
        total_seconds = max(1, int((expires_at - started_at).total_seconds()))
        remaining_seconds = max(0, int((expires_at - now).total_seconds()))
        if remaining_seconds <= 0:
            return 0
        prorated = int(price_cents * remaining_seconds / total_seconds)
        return min(refundable_cents, max(0, prorated))

    @classmethod
    def _entitlement_started_at(cls, user: dict, change_mode: str, now: datetime) -> datetime:
        if change_mode == "renew":
            expires_at = cls._subscription_expires_at(user)
            if expires_at:
                expires_at = expires_at.replace(tzinfo=timezone.utc) if expires_at.tzinfo is None else expires_at
                if expires_at > now:
                    return expires_at
        return now

    @staticmethod
    def _duration_months(period: str | None, count: int | None) -> int:
        count = max(1, int(count or 1))
        if period == "year":
            return count * 12
        return count

    @staticmethod
    def _normalize_settlement_mode(mode: str | None) -> str:
        normalized = (mode or SETTLEMENT_FULL_PRICE).strip().lower()
        if normalized not in SETTLEMENT_MODES:
            raise ValueError("unsupported settlement mode")
        return normalized

    @staticmethod
    def _normalize_provider(provider: str | None) -> str:
        return (provider or "unknown").strip().lower() or "unknown"

    @staticmethod
    def _normalize_charge_type(charge_type: str | None) -> str:
        value = (charge_type or CHARGE_TYPE_MANUAL_PURCHASE).strip().lower()
        if value not in CHARGE_TYPES:
            raise ValueError("unsupported charge type")
        return value

    @staticmethod
    def _auto_charge_event_id(
        *,
        user_email: str,
        charge_type: str,
        expires_at: datetime,
        target_plan_code: str,
        billing_cycle: str,
    ) -> str:
        normalized_expiry = expires_at.isoformat()
        raw = f"{user_email}|{charge_type}|{normalized_expiry}|{target_plan_code}|{billing_cycle}"
        return f"auto:{charge_type}:{hashlib.sha256(raw.encode()).hexdigest()[:24]}"

    @staticmethod
    def _as_utc(dt: datetime) -> datetime:
        return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt

    @staticmethod
    def _snapshot(user: dict) -> dict:
        return {
            "plan_code": user.get("subscription_plan_code") or user.get("plan_code"),
            "subscription_started_at": user.get("subscription_started_at"),
            "subscription_expires_at": user.get("subscription_expires_at"),
            "subscription_billing_cycle": user.get("subscription_billing_cycle"),
            "subscription_auto_renew": bool(user.get("subscription_auto_renew", False)),
            "pending_plan_code": user.get("pending_plan_code"),
            "pending_effective_at": user.get("pending_effective_at"),
            "pending_billing_cycle": user.get("pending_billing_cycle"),
            "pending_requires_payment": bool(user.get("pending_requires_payment", False)),
            "pending_payment_status": user.get("pending_payment_status"),
            "pending_payment_charge_type": user.get("pending_payment_charge_type"),
        }

    @staticmethod
    def _pending_snapshot(user: dict) -> dict:
        return {
            "pending_plan_code": user.get("pending_plan_code"),
            "pending_effective_at": user.get("pending_effective_at"),
            "pending_duration_count": user.get("pending_duration_count"),
            "pending_duration_period": user.get("pending_duration_period"),
            "pending_billing_cycle": user.get("pending_billing_cycle"),
            "pending_requires_payment": bool(user.get("pending_requires_payment", False)),
            "pending_payment_status": user.get("pending_payment_status"),
            "pending_payment_charge_type": user.get("pending_payment_charge_type"),
            "pending_payment_amount_cents": user.get("pending_payment_amount_cents"),
        }

    @staticmethod
    def _subscription_expires_at(user: dict):
        return user.get("subscription_expires_at") or user.get("plan_expires_at")

    @classmethod
    def _is_expired(cls, user: dict) -> bool:
        expires_at = cls._subscription_expires_at(user)
        if not expires_at:
            return False
        expires_at = expires_at.replace(tzinfo=timezone.utc) if expires_at.tzinfo is None else expires_at
        return expires_at <= datetime.now(timezone.utc)

    @staticmethod
    def _strip_id(doc: dict) -> dict:
        data = dict(doc)
        data.pop("_id", None)
        return data
