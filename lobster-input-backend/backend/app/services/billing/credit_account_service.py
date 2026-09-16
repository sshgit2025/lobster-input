"""CreditAccountService — 套餐积分与 bonus 积分统一账户服务。"""
from datetime import datetime, timezone, timedelta
from typing import Optional

from app.core.exceptions import CreditsExhaustedException
from app.repositories.credit_grant_repository import (
    BONUS_CREDIT_TYPE,
    PAID_TOPUP_CREDIT_TYPE,
    CreditGrantRepository,
)
from app.repositories.distributed_lock_repository import DistributedLockRepository
from app.repositories.plan_repository import PlanRepository
from app.repositories.user_repository import UserRepository
from app.services.billing.plan_service import PlanService


class CreditAccountService:
    def __init__(self):
        self.user_repo = UserRepository()
        self.plan_service = PlanService()
        self.plan_repo = PlanRepository()
        self.grant_repo = CreditGrantRepository()
        self.lock_repo = DistributedLockRepository()

    async def get_balance(self, email: str) -> dict:
        user = await self.user_repo.find_by_email(email)
        if not user:
            return {
                "total_remaining": 0,
                "plan_remaining": 0,
                "bonus_remaining": 0,
                "paid_topup_remaining": 0,
            }
        user = await self.plan_service.check_and_reset_credits(email, user)
        plan_total = int(user.get("plan_credits_total", user.get("credits_total", 0)) or 0)
        plan_used = int(user.get("plan_credits_used", user.get("credits_used", 0)) or 0)
        plan_status = user.get("subscription_status", "active")
        plan_remaining = max(0, plan_total - plan_used) if plan_status == "active" else 0
        bonus_remaining = await self.grant_repo.get_available_total(email, credit_type=BONUS_CREDIT_TYPE)
        paid_topup_remaining = await self.grant_repo.get_available_total(email, credit_type=PAID_TOPUP_CREDIT_TYPE)
        return {
            "total_remaining": plan_remaining + bonus_remaining + paid_topup_remaining,
            "plan_remaining": plan_remaining,
            "bonus_remaining": bonus_remaining,
            "paid_topup_remaining": paid_topup_remaining,
            "user": user,
        }

    async def ensure_available(self, email: Optional[str]) -> Optional[int]:
        if not email:
            return None
        balance = await self.get_balance(email)
        if balance["total_remaining"] <= 0:
            raise CreditsExhaustedException()
        return balance["total_remaining"]

    async def ensure_at_least(self, email: Optional[str], amount: int) -> Optional[int]:
        if not email:
            return None
        amount = max(1, int(amount or 1))
        balance = await self.get_balance(email)
        if balance["total_remaining"] < amount:
            raise CreditsExhaustedException()
        return balance["total_remaining"]

    async def deduct(self, email: Optional[str], amount: int) -> tuple[Optional[int], list[dict]]:
        return await self.charge(email, amount)

    async def charge(self, email: Optional[str], amount: int) -> tuple[Optional[int], list[dict]]:
        """Atomically charge credits across plan, bonus, and paid top-up balances."""
        if not email:
            return None, []
        amount = max(0, int(amount or 0))
        async with self.lock_repo.lock(f"credits:{email}"):
            balance = await self.get_balance(email)
            if amount <= 0:
                return balance["total_remaining"], []
            if balance["total_remaining"] < amount:
                raise CreditsExhaustedException()

            rows = []
            plan_used = min(amount, balance["plan_remaining"])
            if plan_used > 0:
                await self.user_repo.increment_plan_credits_used(email, plan_used)
                rows.append({"source": "plan", "credits": plan_used})
            rest = amount - plan_used
            if rest > 0:
                bonus_rows = await self.grant_repo.deduct(email, rest, credit_type=BONUS_CREDIT_TYPE)
                rows.extend(bonus_rows)
                rest -= sum(int(row.get("credits", 0) or 0) for row in bonus_rows)
            if rest > 0:
                topup_rows = await self.grant_repo.deduct(email, rest, credit_type=PAID_TOPUP_CREDIT_TYPE)
                rows.extend(topup_rows)
                rest -= sum(int(row.get("credits", 0) or 0) for row in topup_rows)
            if rest > 0:
                await self._refund_rows(email, rows)
                raise CreditsExhaustedException()
            new_balance = await self.get_balance(email)
            return new_balance["total_remaining"], rows

    async def refund(self, email: Optional[str], rows: list[dict], amount: Optional[int] = None) -> None:
        if not email or not rows:
            return
        async with self.lock_repo.lock(f"credits:{email}"):
            await self._refund_rows(email, rows, amount)

    async def _refund_rows(self, email: str, rows: list[dict], amount: Optional[int] = None) -> int:
        remaining = sum(int(row.get("credits", 0) or 0) for row in rows) if amount is None else max(0, int(amount))
        refunded = 0
        for row in reversed(rows):
            if remaining <= 0:
                break
            row_credits = int(row.get("credits", 0) or 0)
            if row_credits <= 0:
                continue
            refund_amount = min(remaining, row_credits)
            if row.get("source") == "plan":
                await self.user_repo.increment_plan_credits_used(email, -refund_amount)
            elif row.get("grant_id"):
                await self.grant_repo.refund(row["grant_id"], refund_amount)
            remaining -= refund_amount
            refunded += refund_amount
        return refunded

    async def grant_bonus(
        self,
        email: str,
        amount: int,
        source: str,
        expires_days: Optional[int] = None,
        metadata: Optional[dict] = None,
        idempotency_key: str = "",
    ) -> bool:
        expires_at = datetime.now(timezone.utc) + timedelta(days=max(1, int(expires_days or 365)))
        return await self.grant_repo.grant(
            email,
            amount,
            source,
            expires_at,
            metadata,
            credit_type=BONUS_CREDIT_TYPE,
            idempotency_key=idempotency_key,
        )

    async def grant_by_policy(self, email: str, source: str, idempotency_key: str = "") -> int:
        policy = await self.plan_repo.get_bonus_credit_policy()
        cfg = policy.get(source, {})
        if not cfg.get("enabled", False):
            return 0
        amount = int(cfg.get("credits", 0) or 0)
        if amount <= 0:
            return 0
        created = await self.grant_bonus(
            email,
            amount,
            source,
            int(cfg.get("expires_days", 0) or 0),
            idempotency_key=idempotency_key,
        )
        return amount if (created or idempotency_key) else 0
