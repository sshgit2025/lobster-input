"""Subscription and credit-grant lifecycle coordination for admin flows.

API handlers should update the user subscription state, then call this
coordinator for the standard credit side effects. The policy object owns the
sync/expire/hold decision so future custom plan families can override behavior
in one place.
"""
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum

BONUS_CREDIT_TYPE = "bonus"
PAID_TOPUP_CREDIT_TYPE = "paid_topup"
CREDIT_STATUS_ACTIVE = "active"
CREDIT_STATUS_EXPIRED = "expired"
SUBSCRIPTION_EXPIRES_MODE = "subscription"
FREE_PLAN_CODE = "free"
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
    def __init__(self, db, policy: SubscriptionLifecyclePolicy | None = None):
        self.db = db
        self.policy = policy or SubscriptionLifecyclePolicy()

    async def refresh_for_user(self, email: str, now: datetime | None = None) -> int:
        now = as_utc(now or datetime.now(timezone.utc))
        changed = 0
        user = await self.db["users"].find_one(
            {"email": email},
            {"subscription_plan_code": 1, "plan_code": 1, "tier": 1, "subscription_expires_at": 1, "plan_expires_at": 1},
        )
        if user:
            changed += await self.apply_linked_grants(email, self.policy.snapshot_from_user(user), now)
        changed += await self.expire_standalone_grants(email, now)
        return changed

    async def apply_subscription_activation(
        self,
        email: str,
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
            changed["paid_topups"] += await self.extend_paid_topups(email, snapshot.expires_at, now)
        changed["subscription_linked"] += await self.apply_linked_grants(email, snapshot, now)
        if self.policy.is_free_state(snapshot):
            changed["paid_topups"] += await self.expire_paid_topups(email, now)
        return changed

    async def apply_linked_grants(self, email: str, snapshot: SubscriptionSnapshot, now: datetime) -> int:
        action = self.policy.linked_grant_action(snapshot, now)
        if action == LinkedGrantAction.SYNC and snapshot.expires_at:
            return await self.sync_subscription_linked_grants(email, snapshot.plan_code, snapshot.expires_at, now)
        if action == LinkedGrantAction.EXPIRE:
            return await self.expire_subscription_linked_grants(email, now)
        return 0

    async def expire_standalone_grants(self, email: str, now: datetime) -> int:
        result = await self.db["credit_grants"].update_many(
            {
                "user_email": email,
                "status": CREDIT_STATUS_ACTIVE,
                "expires_at": {"$ne": None, "$lte": now},
                "$or": [
                    {"metadata.expires_at_mode": {"$exists": False}},
                    {"metadata.expires_at_mode": {"$ne": SUBSCRIPTION_EXPIRES_MODE}},
                ],
            },
            {"$set": {"status": CREDIT_STATUS_EXPIRED, "expired_reason": EXPIRE_REASON_EXPIRES_AT, "updated_at": now}},
        )
        return result.modified_count

    async def sync_subscription_linked_grants(self, email: str, plan_code: str, expires_at: datetime, now: datetime) -> int:
        expires_at = as_utc(expires_at)
        result = await self.db["credit_grants"].update_many(
            {
                "user_email": email,
                "status": CREDIT_STATUS_ACTIVE,
                "metadata.expires_at_mode": SUBSCRIPTION_EXPIRES_MODE,
            },
            {"$set": {
                "expires_at": expires_at,
                "metadata.subscription_plan_code": plan_code,
                "metadata.subscription_expires_at": expires_at,
                "updated_at": now,
            }},
        )
        return result.modified_count

    async def expire_subscription_linked_grants(self, email: str, now: datetime) -> int:
        result = await self.db["credit_grants"].update_many(
            {
                "user_email": email,
                "status": CREDIT_STATUS_ACTIVE,
                "metadata.expires_at_mode": SUBSCRIPTION_EXPIRES_MODE,
            },
            {"$set": {
                "status": CREDIT_STATUS_EXPIRED,
                "expires_at": now,
                "expired_reason": EXPIRE_REASON_SUBSCRIPTION_TO_FREE,
                "updated_at": now,
            }},
        )
        return result.modified_count

    async def extend_paid_topups(self, email: str, expires_at: datetime, now: datetime | None = None) -> int:
        now = as_utc(now or datetime.now(timezone.utc))
        result = await self.db["credit_grants"].update_many(
            {
                "user_email": email,
                "credit_type": PAID_TOPUP_CREDIT_TYPE,
                "status": CREDIT_STATUS_ACTIVE,
                "$expr": {"$lt": ["$amount_used", "$amount_total"]},
            },
            {"$set": {"expires_at": as_utc(expires_at), "updated_at": now}},
        )
        return result.modified_count

    async def expire_paid_topups(self, email: str, now: datetime) -> int:
        result = await self.db["credit_grants"].update_many(
            {
                "user_email": email,
                "credit_type": PAID_TOPUP_CREDIT_TYPE,
                "status": CREDIT_STATUS_ACTIVE,
                "$expr": {"$lt": ["$amount_used", "$amount_total"]},
            },
            {"$set": {
                "status": CREDIT_STATUS_EXPIRED,
                "expires_at": now,
                "expired_reason": EXPIRE_REASON_SUBSCRIPTION_TO_FREE,
                "updated_at": now,
            }},
        )
        return result.modified_count
