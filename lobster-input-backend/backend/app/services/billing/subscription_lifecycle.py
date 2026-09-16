"""Subscription and credit-grant lifecycle coordination.

The standard lifecycle is implemented as a small policy plus a coordinator:
callers describe the current subscription, while this module decides how
subscription-linked grants and paid top-ups should move. Future plan-specific
behavior can override the policy without scattering conditionals across API
handlers and repositories.
"""
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Awaitable, Callable

from app.services.billing.plan_policy import FREE_PLAN_CODE

BONUS_CREDIT_TYPE = "bonus"
PAID_TOPUP_CREDIT_TYPE = "paid_topup"
CREDIT_STATUS_ACTIVE = "active"
CREDIT_STATUS_EXPIRED = "expired"
SUBSCRIPTION_EXPIRES_MODE = "subscription"
EXPIRE_REASON_EXPIRES_AT = "expires_at"
EXPIRE_REASON_SUBSCRIPTION_TO_FREE = "subscription_to_free"


def as_utc(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


class LinkedGrantAction(str, Enum):
    SYNC = "sync"
    EXPIRE = "expire"
    HOLD = "hold"


@dataclass(frozen=True)
class SubscriptionSnapshot:
    plan_code: str
    expires_at: datetime | None


class SubscriptionLifecyclePolicy:
    """Standard subscription lifecycle strategy.

    Trial plans are intentionally treated like paid entitlements by checking
    only for "non-free + future expiry". Override this class if a future plan
    family needs different grant behavior.
    """

    free_plan_code = FREE_PLAN_CODE

    def snapshot_from_user(self, user: dict) -> SubscriptionSnapshot:
        return SubscriptionSnapshot(
            plan_code=self.active_plan_code(user),
            expires_at=self.subscription_expires_at(user),
        )

    def active_plan_code(self, user: dict) -> str:
        return user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier") or ""

    def subscription_expires_at(self, user: dict) -> datetime | None:
        expires_at = user.get("subscription_expires_at") or user.get("plan_expires_at")
        return as_utc(expires_at) if expires_at else None

    def linked_grant_action(self, snapshot: SubscriptionSnapshot, now: datetime) -> LinkedGrantAction:
        if self.has_active_entitlement(snapshot, now):
            return LinkedGrantAction.SYNC
        if self.is_free_state(snapshot):
            return LinkedGrantAction.EXPIRE
        return LinkedGrantAction.HOLD

    def has_active_entitlement(self, snapshot: SubscriptionSnapshot, now: datetime) -> bool:
        return bool(
            snapshot.plan_code
            and snapshot.plan_code != self.free_plan_code
            and snapshot.expires_at
            and as_utc(snapshot.expires_at) > now
        )

    def is_free_state(self, snapshot: SubscriptionSnapshot) -> bool:
        return snapshot.plan_code in {"", self.free_plan_code}


class CreditGrantLifecycleCoordinator:
    """Template-method style coordinator for grant lifecycle side effects."""

    def __init__(self, grant_repo, policy: SubscriptionLifecyclePolicy | None = None):
        self.grant_repo = grant_repo
        self.policy = policy or SubscriptionLifecyclePolicy()

    async def refresh_for_user(
        self,
        user_email: str,
        user_loader: Callable[[], Awaitable[dict | None]],
        now: datetime | None = None,
    ) -> int:
        now = as_utc(now or datetime.now(timezone.utc))
        changed = 0
        user = await user_loader()
        if user:
            snapshot = self.policy.snapshot_from_user(user)
            changed += await self.apply_linked_grants(user_email, snapshot, now)
        changed += await self.grant_repo.expire_standalone_grants(user_email, now)
        return changed

    async def apply_subscription_activation(
        self,
        user_email: str,
        plan_code: str,
        expires_at: datetime | None,
        now: datetime | None = None,
        *,
        paid_topup_enabled: bool = False,
    ) -> dict[str, int]:
        now = as_utc(now or datetime.now(timezone.utc))
        snapshot = SubscriptionSnapshot(plan_code=plan_code, expires_at=as_utc(expires_at) if expires_at else None)
        changed = {"paid_topups": 0, "subscription_linked": 0}
        if paid_topup_enabled and snapshot.expires_at:
            changed["paid_topups"] += await self.grant_repo.extend_paid_topups(user_email, snapshot.expires_at)
        changed["subscription_linked"] += await self.apply_linked_grants(user_email, snapshot, now)
        if self.policy.is_free_state(snapshot):
            changed["paid_topups"] += await self.grant_repo.expire_paid_topups(user_email, now)
        return changed

    async def apply_linked_grants(
        self,
        user_email: str,
        snapshot: SubscriptionSnapshot,
        now: datetime,
    ) -> int:
        action = self.policy.linked_grant_action(snapshot, now)
        if action == LinkedGrantAction.SYNC and snapshot.expires_at:
            return await self.grant_repo.sync_subscription_linked_grants(
                user_email,
                as_utc(snapshot.expires_at),
                snapshot.plan_code,
                now,
            )
        if action == LinkedGrantAction.EXPIRE:
            return await self.grant_repo.expire_subscription_linked_grants(user_email, now)
        return 0
