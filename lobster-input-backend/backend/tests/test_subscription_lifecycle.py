import asyncio
from datetime import datetime, timedelta, timezone

from app.services.billing.subscription_lifecycle import (
    CreditGrantLifecycleCoordinator,
    LinkedGrantAction,
    SubscriptionLifecyclePolicy,
    SubscriptionSnapshot,
)


class _FakeGrantRepo:
    def __init__(self):
        self.calls = []

    async def extend_paid_topups(self, email, expires_at):
        self.calls.append(("extend_paid_topups", email, expires_at))
        return 1

    async def expire_paid_topups(self, email, now):
        self.calls.append(("expire_paid_topups", email, now))
        return 1

    async def sync_subscription_linked_grants(self, email, expires_at, plan_code, now):
        self.calls.append(("sync_subscription_linked_grants", email, expires_at, plan_code, now))
        return 1

    async def expire_subscription_linked_grants(self, email, now):
        self.calls.append(("expire_subscription_linked_grants", email, now))
        return 1

    async def expire_standalone_grants(self, email, now):
        self.calls.append(("expire_standalone_grants", email, now))
        return 1


def test_subscription_policy_keeps_expired_paid_state_on_hold_until_free_fallback():
    now = datetime.now(timezone.utc)
    policy = SubscriptionLifecyclePolicy()

    assert policy.linked_grant_action(SubscriptionSnapshot("trial", now + timedelta(days=1)), now) == LinkedGrantAction.SYNC
    assert policy.linked_grant_action(SubscriptionSnapshot("pro", now - timedelta(days=1)), now) == LinkedGrantAction.HOLD
    assert policy.linked_grant_action(SubscriptionSnapshot("free", None), now) == LinkedGrantAction.EXPIRE


def test_coordinator_applies_standard_paid_and_free_templates():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    repo = _FakeGrantRepo()
    coordinator = CreditGrantLifecycleCoordinator(repo)

    asyncio.run(coordinator.apply_subscription_activation(
        email,
        "pro",
        now + timedelta(days=30),
        now,
        paid_topup_enabled=True,
    ))

    assert [call[0] for call in repo.calls] == [
        "extend_paid_topups",
        "sync_subscription_linked_grants",
    ]

    repo.calls.clear()
    asyncio.run(coordinator.apply_subscription_activation(email, "free", None, now))

    assert [call[0] for call in repo.calls] == [
        "expire_subscription_linked_grants",
        "expire_paid_topups",
    ]
