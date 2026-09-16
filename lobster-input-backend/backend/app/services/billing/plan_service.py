"""PlanService — 用户订阅生命周期、套餐周期重置和余额查询。"""
import logging
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo
from dateutil.relativedelta import relativedelta
from app.repositories.plan_repository import PlanRepository
from app.repositories.user_repository import UserRepository
from app.repositories.credit_grant_repository import CreditGrantRepository
from app.core.content_i18n import localized_text
from app.services.billing.plan_policy import FREE_PLAN_CODE, TRIAL_PLAN_CODE, PlanPolicy
from app.services.billing.subscription_lifecycle import CreditGrantLifecycleCoordinator

logger = logging.getLogger("voice_input.plan")

SUBSCRIPTION_STATUS_ACTIVE = "active"
TRIAL_EXPIRY_TIMEZONE = ZoneInfo("Asia/Shanghai")


def _as_utc(dt: datetime) -> datetime:
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt


def add_period(start: datetime, period: str, count: int = 1) -> datetime:
    start = _as_utc(start)
    count = max(1, int(count or 1))
    if period == "none":
        # "none" = 有效期内不做周期性积分刷新(一次性额度)。返回远期,
        # 使周期末被套餐有效期截断,积分刷新在有效期内永不触发。
        return start + relativedelta(years=100)
    if period == "day":
        return start + timedelta(days=count)
    if period == "week":
        return start + timedelta(weeks=count)
    if period == "year":
        return start + relativedelta(years=count)
    return start + relativedelta(months=count)


class PlanService:
    """套餐服务，封装订阅状态、周期重置和查询逻辑。"""

    def __init__(self):
        self.plan_repo = PlanRepository()
        self.user_repo = UserRepository()
        self.grant_repo = CreditGrantRepository()

    def _grant_lifecycle(self) -> CreditGrantLifecycleCoordinator:
        return CreditGrantLifecycleCoordinator(self.grant_repo)

    async def init_user_plan(self, email: str, registered_at: datetime) -> None:
        """新用户注册时初始化试用套餐。"""
        started = _as_utc(registered_at)
        config = await self.plan_repo.get_plan_config(TRIAL_PLAN_CODE)
        expires_at = self._configured_expires_at(config, started)
        await self.activate_subscription(
            email,
            TRIAL_PLAN_CODE,
            started_at=started,
            expires_at=expires_at,
        )
        logger.info(
            "[plan] init_user_plan email=%s plan=trial registered_at=%s",
            email, registered_at.isoformat()
        )

    async def activate_subscription(
        self,
        email: str,
        plan_code: str,
        started_at: datetime | None = None,
        expires_at: datetime | None = None,
        billing_cycle: str | None = None,
        auto_renew: bool = False,
        clear_pending: bool = True,
    ) -> dict:
        """立即激活一个订阅，并从激活时刻开始重置套餐周期积分。"""
        started = _as_utc(started_at or datetime.now(timezone.utc))
        config = await self.plan_repo.get_plan_config(plan_code)
        period_end = add_period(started, config.get("reset_period", "month"), 1)
        normalized_expires_at = _as_utc(expires_at) if expires_at else None
        if normalized_expires_at and period_end > normalized_expires_at:
            period_end = normalized_expires_at
        active_plan_code = config.get("code", plan_code)
        policy = PlanPolicy.from_config(config, active_plan_code)
        doc = {
            "subscription_plan_code": active_plan_code,
            "subscription_started_at": started,
            "subscription_expires_at": normalized_expires_at,
            "subscription_status": SUBSCRIPTION_STATUS_ACTIVE,
            "subscription_billing_cycle": billing_cycle,
            "subscription_auto_renew": bool(auto_renew and policy.can_auto_renew),
            "plan_code": active_plan_code,
            "plan_started_at": started,
            "plan_expires_at": normalized_expires_at,
            "plan_current_period_start": started,
            "plan_current_period_end": period_end,
            "plan_credits_total": int(config.get("credits", 0) or 0),
            "plan_credits_used": 0,
            "credits_total": int(config.get("credits", 0) or 0),
            "credits_used": 0,
            "credits_reset_at": period_end,
        }
        if clear_pending:
            doc["pending_plan_code"] = None
            doc["pending_effective_at"] = None
            doc["pending_duration_count"] = None
            doc["pending_duration_period"] = None
            doc["pending_billing_cycle"] = None
            doc["pending_requires_payment"] = None
            doc["pending_payment_status"] = None
            doc["pending_payment_due_at"] = None
            doc["pending_payment_provider"] = None
            doc["pending_schedule_event_id"] = None
            doc["pending_from_plan_code"] = None
            doc["pending_payment_charge_type"] = None
            doc["pending_payment_amount_cents"] = None
            doc["pending_payment_blocked_reason"] = None
        await self.user_repo.assign_plan(email, doc)
        await self._grant_lifecycle().apply_subscription_activation(
            email,
            active_plan_code,
            normalized_expires_at,
            started,
            paid_topup_enabled=policy.paid and policy.paid_topup_enabled,
        )
        return doc

    async def renew_subscription(
        self,
        email: str,
        plan_code: str,
        duration_count: int,
        duration_period: str,
        billing_cycle: str | None = None,
        auto_renew: bool | None = None,
    ) -> dict:
        """同套餐续费或购买多期，从 max(当前到期时间, 当前时间) 往后延长。"""
        now = datetime.now(timezone.utc)
        user = await self.user_repo.find_by_email(email)
        if not user:
            return {}
        active_code = self._active_plan_code(user)
        expires_at = self._effective_subscription_expires_at(user)
        if active_code != plan_code:
            config = await self.plan_repo.get_plan_config(plan_code)
            return await self.activate_subscription(
                email,
                plan_code,
                started_at=now,
                expires_at=self._configured_expires_at(config, now) if not PlanPolicy.from_config(config, plan_code).paid else add_period(now, duration_period, duration_count),
                billing_cycle=billing_cycle,
                auto_renew=bool(auto_renew),
            )
        if plan_code == FREE_PLAN_CODE:
            config = await self.plan_repo.get_plan_config(FREE_PLAN_CODE)
            return await self.activate_subscription(email, FREE_PLAN_CODE, started_at=now, expires_at=self._configured_expires_at(config, now))
        if not expires_at or _as_utc(expires_at) <= now:
            config = await self.plan_repo.get_plan_config(plan_code)
            policy = PlanPolicy.from_config(config, plan_code)
            return await self.activate_subscription(
                email,
                plan_code,
                started_at=now,
                expires_at=add_period(now, duration_period, duration_count) if policy.paid else self._configured_expires_at(config, now),
                billing_cycle=billing_cycle,
                auto_renew=bool(user.get("subscription_auto_renew") if auto_renew is None else auto_renew),
            )
        config = await self.plan_repo.get_plan_config(plan_code)
        policy = PlanPolicy.from_config(config, plan_code)
        base = now
        if expires_at and _as_utc(expires_at) > now:
            base = _as_utc(expires_at)
        new_expires_at = add_period(base, duration_period, duration_count)
        await self.user_repo.update_subscription(email, {
            "subscription_expires_at": new_expires_at,
            "plan_expires_at": new_expires_at,
            "subscription_status": SUBSCRIPTION_STATUS_ACTIVE,
            "subscription_billing_cycle": billing_cycle or user.get("subscription_billing_cycle"),
            "subscription_auto_renew": bool(policy.can_auto_renew and (user.get("subscription_auto_renew") if auto_renew is None else auto_renew)),
        })
        await self._grant_lifecycle().apply_subscription_activation(
            email,
            plan_code,
            new_expires_at,
            now,
            paid_topup_enabled=policy.paid and policy.paid_topup_enabled,
        )
        refreshed = await self.user_repo.find_by_email(email)
        return refreshed or {}

    async def schedule_plan_change(
        self,
        email: str,
        plan_code: str,
        effective_at: datetime,
        duration_count: int = 1,
        duration_period: str = "month",
        billing_cycle: str | None = None,
    ) -> dict:
        """将套餐变更排队到当前订阅结束时生效，常用于降级。"""
        await self.user_repo.update_subscription(email, {
            "pending_plan_code": plan_code,
            "pending_effective_at": _as_utc(effective_at),
            "pending_duration_count": max(1, int(duration_count or 1)),
            "pending_duration_period": duration_period,
            "pending_billing_cycle": billing_cycle,
        })
        refreshed = await self.user_repo.find_by_email(email)
        return refreshed or {}

    async def change_subscription(
        self,
        email: str,
        plan_code: str,
        duration_count: int = 1,
        duration_period: str = "month",
        billing_cycle: str | None = None,
        auto_renew: bool = False,
        change_mode: str = "activate_now",
    ) -> dict:
        """订阅动作：管理端可调用全部模式，支付链路应只调用受限封装。"""
        now = datetime.now(timezone.utc)
        user = await self.user_repo.find_by_email(email)
        if not user:
            return {}
        if change_mode == "renew":
            return await self.renew_subscription(
                email, plan_code, duration_count, duration_period, billing_cycle, auto_renew,
            )
        if change_mode == "downgrade_later":
            effective_at = self._subscription_expires_at(user) or now
            config = await self.plan_repo.get_plan_config(plan_code)
            policy = PlanPolicy.from_config(config, plan_code)
            pending_count = duration_count if policy.paid else int(config.get("validity_count") or 0)
            pending_period = duration_period if policy.paid else config.get("validity_period", "forever")
            return await self.schedule_plan_change(
                email, plan_code, effective_at, pending_count, pending_period, billing_cycle,
            )
        if plan_code == FREE_PLAN_CODE:
            config = await self.plan_repo.get_plan_config(plan_code)
            return await self.activate_subscription(email, plan_code, started_at=now, expires_at=self._configured_expires_at(config, now))
        config = await self.plan_repo.get_plan_config(plan_code)
        policy = PlanPolicy.from_config(config, plan_code)
        expires_at = add_period(now, duration_period, duration_count) if policy.paid else self._configured_expires_at(config, now)
        return await self.activate_subscription(
            email,
            plan_code,
            started_at=now,
            expires_at=expires_at,
            billing_cycle=billing_cycle,
            auto_renew=auto_renew,
        )

    async def check_and_reset_credits(self, email: str, user: dict) -> dict:
        """惰性检查单用户订阅状态和套餐周期，过期则切换订阅或重置套餐积分。"""
        now = datetime.now(timezone.utc)
        active_plan_code = self._active_plan_code(user)
        if not active_plan_code:
            base = user.get("created_at") or datetime.now(timezone.utc)
            await self.init_user_plan(email, base)
            await self.grant_repo.refresh_statuses(email, now)
            refreshed = await self.user_repo.find_by_email(email)
            return refreshed or user

        expires_at = self._effective_subscription_expires_at(user)
        pending_plan = user.get("pending_plan_code")
        pending_at = user.get("pending_effective_at")
        subscription_due = self._is_subscription_due(active_plan_code, expires_at, now)
        if pending_plan and user.get("pending_requires_payment") and pending_at and now >= _as_utc(pending_at):
            if subscription_due:
                auto_charge = await self._try_due_auto_charge(email, user, now)
                if auto_charge.get("status") in {"applied", "duplicate"}:
                    await self.grant_repo.refresh_statuses(email, now)
                    refreshed = await self.user_repo.find_by_email(email)
                    return refreshed or user
                free_config = await self.plan_repo.get_plan_config(FREE_PLAN_CODE)
                await self.activate_subscription(
                    email,
                    FREE_PLAN_CODE,
                    started_at=now,
                    expires_at=self._configured_expires_at(free_config, now),
                    clear_pending=False,
                )
                await self.user_repo.update_subscription(email, {
                    "pending_effective_at": None,
                    "pending_payment_due_at": now,
                    "pending_payment_status": "payment_due",
                    "pending_payment_blocked_reason": auto_charge.get("reason"),
                })
                await self.grant_repo.refresh_statuses(email, now)
                refreshed = await self.user_repo.find_by_email(email)
                return refreshed or user
            await self.grant_repo.refresh_statuses(email, now)
            return user

        if pending_plan and pending_at and now >= _as_utc(pending_at):
            pending_expires_at = await self._pending_expires_at(user, pending_plan, now)
            await self.activate_subscription(
                email,
                pending_plan,
                started_at=now,
                expires_at=pending_expires_at,
                billing_cycle=user.get("pending_billing_cycle"),
            )
            await self.grant_repo.refresh_statuses(email, now)
            refreshed = await self.user_repo.find_by_email(email)
            return refreshed or user
        if subscription_due:
            if pending_plan:
                pending_expires_at = await self._pending_expires_at(user, pending_plan, now)
                await self.activate_subscription(
                    email,
                    pending_plan,
                    started_at=now,
                    expires_at=pending_expires_at,
                    billing_cycle=user.get("pending_billing_cycle"),
                )
            else:
                auto_charge = await self._try_due_auto_charge(email, user, now)
                if auto_charge.get("status") in {"applied", "duplicate"}:
                    await self.grant_repo.refresh_statuses(email, now)
                    refreshed = await self.user_repo.find_by_email(email)
                    return refreshed or user
                free_config = await self.plan_repo.get_plan_config(FREE_PLAN_CODE)
                await self.activate_subscription(
                    email,
                    FREE_PLAN_CODE,
                    started_at=now,
                    expires_at=self._configured_expires_at(free_config, now),
                )
            await self.grant_repo.refresh_statuses(email, now)
            refreshed = await self.user_repo.find_by_email(email)
            return refreshed or user

        await self.grant_repo.refresh_statuses(email, now)
        period_end = user.get("plan_current_period_end") or user.get("credits_reset_at")
        if not period_end or now >= _as_utc(period_end):
            active_plan_code = self._active_plan_code(user) or FREE_PLAN_CODE
            if self._is_subscription_due(active_plan_code, expires_at, now):
                free_config = await self.plan_repo.get_plan_config(FREE_PLAN_CODE)
                await self.activate_subscription(
                    email,
                    FREE_PLAN_CODE,
                    started_at=now,
                    expires_at=self._configured_expires_at(free_config, now),
                )
                refreshed = await self.user_repo.find_by_email(email)
                return refreshed or user
            config = await self.plan_repo.get_plan_config(active_plan_code)
            period = config.get("reset_period", "month")
            start = _as_utc(period_end or user.get("plan_started_at") or now)
            while now >= add_period(start, period, 1):
                start = add_period(start, period, 1)
            new_reset_at = add_period(start, period, 1)
            if expires_at:
                normalized_expires_at = _as_utc(expires_at)
                if new_reset_at > normalized_expires_at:
                    new_reset_at = normalized_expires_at
            credits_total = int(config.get("credits", 0) or 0)
            await self.user_repo.reset_plan_period(email, start, new_reset_at, credits_total)
            logger.info(
                "[plan] credits reset email=%s new_total=%d next_reset=%s",
                email, credits_total, new_reset_at.isoformat()
            )
            refreshed = await self.user_repo.find_by_email(email)
            return refreshed or user

        return user

    async def get_user_plan_info(self, email: str, language: str = "zh") -> dict:
        """
        获取用户套餐信息（含积分余额、到期日期、邀请码开关）。
        同时触发积分重置检查。
        """
        registration_enabled = await self.plan_repo.get_registration_enabled()
        invite_code_enabled = await self.plan_repo.get_invite_code_enabled()
        show_invite_codes_enabled = await self.plan_repo.get_show_invite_codes_enabled()
        show_subscription_module_enabled = await self.plan_repo.get_show_subscription_module_enabled()

        user = await self.user_repo.find_by_email(email)
        if not user:
            return {
                "tier": "none",
                "plan_name": "none",
                "credits_total": 0,
                "credits_used": 0,
                "credits_remaining": 0,
                "credits_reset_at": None,
                "bonus_credits_remaining": 0,
                "paid_topup_credits_remaining": 0,
                "credit_items": [],
                "plan_expires_at": None,
                "auto_renew": False,
                "next_renewal_at": None,
                "renewal_cancellable": False,
                "registration_enabled": registration_enabled,
                "invite_code_enabled": invite_code_enabled,
                "show_invite_codes_enabled": show_invite_codes_enabled,
                "show_subscription_module_enabled": show_subscription_module_enabled,
            }

        user = await self.check_and_reset_credits(email, user)

        tier = self._active_plan_code(user) or "none"
        credit_items = await self._build_credit_items(email, user, tier)
        credits_total = sum(int(item["credits_total"]) for item in credit_items)
        credits_used = sum(int(item["credits_used"]) for item in credit_items)
        credits_remaining = sum(int(item["credits_remaining"]) for item in credit_items)
        bonus_remaining = await self.grant_repo.get_available_total(email, credit_type="bonus")
        paid_topup_remaining = await self.grant_repo.get_available_total(email, credit_type="paid_topup")
        credits_reset_at = user.get("plan_current_period_end") or user.get("credits_reset_at")
        active_config = await self.plan_repo.get_plan_config(tier) if tier != "none" else {}
        plan_name = localized_text(active_config.get("localized_names"), language, fallback=tier)

        return {
            "tier": tier,
            "plan_name": plan_name,
            "credits_total": credits_total,
            "credits_used": credits_used,
            "credits_remaining": credits_remaining,
            "credits_reset_at": credits_reset_at,
            "bonus_credits_remaining": bonus_remaining,
            "paid_topup_credits_remaining": paid_topup_remaining,
            "credit_items": credit_items,
            "plan_expires_at": self._subscription_expires_at(user),
            "subscription_expires_at": self._subscription_expires_at(user),
            "pending_plan_code": user.get("pending_plan_code"),
            "pending_effective_at": user.get("pending_effective_at"),
            "pending_duration_count": user.get("pending_duration_count"),
            "pending_duration_period": user.get("pending_duration_period"),
            "subscription_billing_cycle": user.get("subscription_billing_cycle"),
            "subscription_auto_renew": bool(user.get("subscription_auto_renew", False)),
            # 订阅管理入口字段:auto_renew 开启时下次扣款时间即当前订阅到期时间;
            # renewal_cancellable=True 时客户端展示「取消订阅」入口。不暴露任何渠道信息。
            # Apple IAP 订阅的续费由 Apple 管理(只能在 App Store 取消,后端取消会造成
            # 本地 False/Apple 照扣的状态分裂),故 cancellable 恒为 False;客户端对
            # auto_renew=True 且 cancellable=False 的组合展示「请在订阅设备的应用商店管理」。
            "auto_renew": bool(user.get("subscription_auto_renew", False)),
            "next_renewal_at": self._subscription_expires_at(user) if user.get("subscription_auto_renew") else None,
            "renewal_cancellable": bool(
                user.get("subscription_auto_renew", False)
                and str(user.get("latest_payment_provider") or "").strip().lower() != "apple"
            ),
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
            "registration_enabled": registration_enabled,
            "invite_code_enabled": invite_code_enabled,
            "show_invite_codes_enabled": show_invite_codes_enabled,
            "show_subscription_module_enabled": show_subscription_module_enabled,
        }

    async def process_due_resets(self, limit: int = 200) -> int:
        now = datetime.now(timezone.utc)
        users = await self.user_repo.find_due_plan_users(now, limit=limit)
        for user in users:
            email = user.get("email")
            if email:
                await self.check_and_reset_credits(email, user)
        return len(users)

    async def _try_due_auto_charge(self, email: str, user: dict, now: datetime) -> dict:
        if not user.get("subscription_auto_renew"):
            return {"status": "skipped", "reason": "auto_renew_disabled"}
        # 自动续费能力完全由支付渠道决定(见 docs/auto-renewal-strategy.md),后端不得本地续期:
        #   - Creem 平台托管,按周期自动扣款并经支付端 webhook(subscription.paid)续期记账;
        #   - zpay 无代扣能力,到期转 free,走"到期提醒 + 手动再购";
        #   - Apple 由订阅组自动续订 + App Store 通知驱动。
        # 历史 SubscriptionPurchaseService.apply_due_auto_charge 以 price_cents=0 本地零元续期,
        # 是 2026-05 mock 计费遗留,在渠道化后会造成"无真实扣款即延长订阅"的资损,已停用。
        # 到期而渠道未续费的用户在此返回非 applied,由调用方走 free 兜底。
        return {"status": "skipped", "reason": "auto_renew_channel_managed"}

    async def _build_credit_items(self, email: str, user: dict, tier: str) -> list[dict]:
        items = []
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
                "expires_at": self._subscription_expires_at(user),
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

    @staticmethod
    def _active_plan_code(user: dict) -> str:
        return user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier") or ""

    @staticmethod
    def _subscription_expires_at(user: dict):
        return user.get("subscription_expires_at", user.get("plan_expires_at"))

    @staticmethod
    def _effective_subscription_expires_at(user: dict):
        return PlanService._subscription_expires_at(user)

    @staticmethod
    def _is_subscription_due(plan_code: str, expires_at, now: datetime) -> bool:
        if not expires_at:
            return False
        normalized_expires_at = _as_utc(expires_at)
        normalized_now = _as_utc(now)
        if plan_code == TRIAL_PLAN_CODE:
            return (
                normalized_expires_at.astimezone(TRIAL_EXPIRY_TIMEZONE).date()
                <= normalized_now.astimezone(TRIAL_EXPIRY_TIMEZONE).date()
            )
        return normalized_now >= normalized_expires_at

    async def _pending_expires_at(self, user: dict, plan_code: str, started_at: datetime):
        duration_period = user.get("pending_duration_period")
        if duration_period == "forever":
            return None
        duration_count = int(user.get("pending_duration_count") or 0)
        if duration_period and duration_count > 0:
            return add_period(started_at, duration_period, duration_count)
        config = await self.plan_repo.get_plan_config(plan_code)
        return self._configured_expires_at(config, started_at)

    @staticmethod
    def _configured_expires_at_sync(config: dict, started_at: datetime):
        period = config.get("validity_period", "forever")
        if period == "forever":
            return None
        return add_period(started_at, period, int(config.get("validity_count") or 1))

    def _configured_expires_at(self, config: dict, started_at: datetime):
        return self._configured_expires_at_sync(config, started_at)
