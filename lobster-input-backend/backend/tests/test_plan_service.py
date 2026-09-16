import asyncio
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from app.services.billing.plan_service import PlanService


class _FakePlanRepo:
    def __init__(self, overrides=None):
        self.overrides = overrides or {}

    async def get_registration_enabled(self):
        return True

    async def get_invite_code_enabled(self):
        return False

    async def get_show_invite_codes_enabled(self):
        return False

    async def get_plan_config(self, code):
        configs = {
            "trial": {"code": "trial", "credits": 3000, "reset_period": "month", "validity_period": "day", "validity_count": 7},
            "free": {"code": "free", "credits": 500, "reset_period": "week", "validity_period": "forever", "validity_count": 0},
            "lite": {"code": "lite", "credits": 9000, "reset_period": "month", "validity_period": "month", "validity_count": 1, "paid": True, "rank": 10},
            "pro": {"code": "pro", "credits": 75000, "reset_period": "month", "validity_period": "month", "validity_count": 1, "paid": True, "rank": 30},
        }
        for plan_code, override in self.overrides.items():
            configs.setdefault(plan_code, {"code": plan_code}).update(override)
        return configs[code]


class _FakeUserRepo:
    def __init__(self, user):
        self.user = dict(user)

    async def assign_plan(self, email, plan_doc):
        self.user.update(plan_doc)
        self.user["email"] = email
        return True

    async def find_by_email(self, email):
        if self.user.get("email") != email:
            return None
        return dict(self.user)

    async def update_subscription(self, email, fields):
        if self.user.get("email") != email:
            return False
        self.user.update(fields)
        return True

    async def reset_plan_period(self, email, period_start, period_end, credits_total):
        if self.user.get("email") != email:
            return False
        self.user.update({
            "plan_current_period_start": period_start,
            "plan_current_period_end": period_end,
            "plan_credits_total": credits_total,
            "plan_credits_used": 0,
            "credits_total": credits_total,
            "credits_used": 0,
            "credits_reset_at": period_end,
        })
        return True


class _FakeGrantRepo:
    def __init__(self, grant):
        self.grant = dict(grant)
        self.refreshed = 0

    async def refresh_statuses(self, email, now=None):
        self.refreshed += 1
        now = now or datetime.now(timezone.utc)
        if (
            self.grant["user_email"] == email
            and self.grant["status"] == "active"
            and self.grant["expires_at"] is not None
            and self.grant["expires_at"] <= now
            and self.grant.get("metadata", {}).get("expires_at_mode") != "subscription"
        ):
            self.grant["status"] = "expired"
            self.grant["expired_reason"] = "expires_at"
        return 1 if self.grant["status"] == "expired" else 0

    async def extend_paid_topups(self, email, expires_at):
        if (
            self.grant["user_email"] == email
            and self.grant["credit_type"] == "paid_topup"
            and self.grant["status"] == "active"
            and self.grant["amount_used"] < self.grant["amount_total"]
        ):
            self.grant["expires_at"] = expires_at
            return 1
        return 0

    async def expire_paid_topups(self, email, now=None):
        if (
            self.grant["user_email"] == email
            and self.grant["credit_type"] == "paid_topup"
            and self.grant["status"] == "active"
            and self.grant["amount_used"] < self.grant["amount_total"]
        ):
            self.grant["status"] = "expired"
            self.grant["expires_at"] = now
            self.grant["expired_reason"] = "subscription_to_free"
            return 1
        return 0

    async def sync_subscription_linked_grants(self, email, expires_at, plan_code, now=None):
        if (
            self.grant["user_email"] == email
            and self.grant.get("metadata", {}).get("expires_at_mode") == "subscription"
            and self.grant["status"] == "active"
        ):
            self.grant["expires_at"] = expires_at
            self.grant.setdefault("metadata", {})["subscription_plan_code"] = plan_code
            self.grant.setdefault("metadata", {})["subscription_expires_at"] = expires_at
            return 1
        return 0

    async def expire_subscription_linked_grants(self, email, now=None):
        if (
            self.grant["user_email"] == email
            and self.grant.get("metadata", {}).get("expires_at_mode") == "subscription"
            and self.grant["status"] == "active"
        ):
            self.grant["status"] = "expired"
            self.grant["expires_at"] = now
            self.grant["expired_reason"] = "subscription_to_free"
            return 1
        return 0


def test_paid_topup_survives_paid_to_paid_pending_transition():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now - timedelta(minutes=1),
        "subscription_status": "active",
        "pending_plan_code": "lite",
        "pending_effective_at": now - timedelta(minutes=1),
        "pending_duration_count": 1,
        "pending_duration_period": "month",
        "pending_billing_cycle": "monthly",
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "paid_topup",
        "status": "active",
        "amount_total": 500,
        "amount_used": 0,
        "expires_at": now - timedelta(minutes=1),
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.check_and_reset_credits(email, user))

    assert refreshed["subscription_plan_code"] == "lite"
    assert refreshed["pending_plan_code"] is None
    assert service.grant_repo.grant["status"] == "active"
    assert service.grant_repo.grant["expires_at"] == refreshed["subscription_expires_at"]


def test_paid_topup_expires_when_paid_subscription_falls_back_to_free():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now - timedelta(minutes=1),
        "subscription_status": "active",
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "paid_topup",
        "status": "active",
        "amount_total": 500,
        "amount_used": 0,
        "expires_at": now - timedelta(minutes=1),
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.check_and_reset_credits(email, user))

    assert refreshed["subscription_plan_code"] == "free"
    assert service.grant_repo.grant["status"] == "expired"
    assert service.grant_repo.grant["expired_reason"] == "subscription_to_free"


def test_trial_switches_to_free_on_local_expiry_date_before_period_reset():
    now = datetime.now(timezone.utc)
    expires_at = (
        datetime.now(ZoneInfo("Asia/Shanghai"))
        .replace(hour=23, minute=59, second=59, microsecond=0)
        .astimezone(timezone.utc)
    )
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "trial",
        "subscription_expires_at": expires_at,
        "subscription_status": "active",
        "plan_credits_total": 3000,
        "plan_credits_used": 3000,
        "credits_total": 3000,
        "credits_used": 3000,
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "bonus",
        "status": "active",
        "amount_total": 0,
        "amount_used": 0,
        "expires_at": now + timedelta(days=1),
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.check_and_reset_credits(email, user))

    assert refreshed["subscription_plan_code"] == "free"
    assert refreshed["subscription_expires_at"] is None
    assert refreshed["plan_credits_total"] == 500
    assert refreshed["plan_credits_used"] == 0
    assert refreshed["credits_used"] == 0


def test_trial_uses_configured_validity_period_on_registration():
    started_at = datetime(2026, 5, 1, 12, 0, tzinfo=timezone.utc)
    email = "user@example.com"

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo({})
    service.grant_repo = _FakeGrantRepo({
        "user_email": email,
        "credit_type": "bonus",
        "status": "active",
        "amount_total": 0,
        "amount_used": 0,
        "expires_at": started_at + timedelta(days=30),
    })

    asyncio.run(service.init_user_plan(email, started_at))
    refreshed = asyncio.run(service.user_repo.find_by_email(email))

    assert refreshed["subscription_plan_code"] == "trial"
    assert refreshed["subscription_expires_at"] == started_at + timedelta(days=7)
    assert refreshed["plan_current_period_end"] == started_at + timedelta(days=7)
    assert refreshed["plan_credits_total"] == 3000


def test_free_fallback_uses_configured_finite_validity_period():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now - timedelta(minutes=1),
        "subscription_status": "active",
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "paid_topup",
        "status": "active",
        "amount_total": 500,
        "amount_used": 0,
        "expires_at": now - timedelta(minutes=1),
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo({"free": {"validity_period": "day", "validity_count": 3}})
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.check_and_reset_credits(email, user))

    assert refreshed["subscription_plan_code"] == "free"
    assert refreshed["subscription_expires_at"] > now + timedelta(days=2)
    assert refreshed["subscription_expires_at"] <= now + timedelta(days=4)
    assert refreshed["plan_current_period_end"] == refreshed["subscription_expires_at"]


def test_due_period_reset_clears_plan_usage():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now + timedelta(days=30),
        "subscription_status": "active",
        "plan_credits_total": 75000,
        "plan_credits_used": 74000,
        "credits_total": 75000,
        "credits_used": 74000,
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "bonus",
        "status": "active",
        "amount_total": 0,
        "amount_used": 0,
        "expires_at": now + timedelta(days=1),
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.check_and_reset_credits(email, user))

    assert refreshed["subscription_plan_code"] == "pro"
    assert refreshed["plan_credits_total"] == 75000
    assert refreshed["plan_credits_used"] == 0
    assert refreshed["credits_used"] == 0
    assert refreshed["plan_current_period_end"] > now


def test_payment_required_pending_downgrade_does_not_activate_without_payment():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now - timedelta(minutes=1),
        "subscription_status": "active",
        "pending_plan_code": "lite",
        "pending_effective_at": now - timedelta(minutes=1),
        "pending_duration_count": 1,
        "pending_duration_period": "month",
        "pending_billing_cycle": "monthly",
        "pending_requires_payment": True,
        "pending_payment_status": "scheduled",
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "paid_topup",
        "status": "active",
        "amount_total": 500,
        "amount_used": 0,
        "expires_at": now - timedelta(minutes=1),
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.check_and_reset_credits(email, user))

    assert refreshed["subscription_plan_code"] == "free"
    assert refreshed["pending_plan_code"] == "lite"
    assert refreshed["pending_requires_payment"] is True
    assert refreshed["pending_payment_status"] == "payment_due"
    assert refreshed["pending_payment_blocked_reason"] == "auto_renew_disabled"
    assert service.grant_repo.grant["status"] == "expired"
    assert service.grant_repo.grant["expired_reason"] == "subscription_to_free"


def test_payment_required_pending_downgrade_auto_charge_prevents_free_fallback():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now - timedelta(minutes=1),
        "subscription_status": "active",
        "subscription_auto_renew": True,
        "pending_plan_code": "lite",
        "pending_effective_at": now - timedelta(minutes=1),
        "pending_duration_count": 1,
        "pending_duration_period": "month",
        "pending_billing_cycle": "monthly",
        "pending_requires_payment": True,
        "pending_payment_status": "scheduled",
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "paid_topup",
        "status": "active",
        "amount_total": 500,
        "amount_used": 0,
        "expires_at": now - timedelta(minutes=1),
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    async def fake_auto_charge(email_arg, user_arg, now_arg):
        new_expires_at = now_arg + timedelta(days=30)
        await service.user_repo.update_subscription(email_arg, {
            "subscription_plan_code": "lite",
            "plan_code": "lite",
            "subscription_expires_at": new_expires_at,
            "plan_expires_at": new_expires_at,
            "pending_plan_code": None,
            "pending_requires_payment": None,
            "last_auto_charge_status": "applied",
            "last_auto_charge_type": "scheduled_downgrade",
        })
        await service.grant_repo.extend_paid_topups(email_arg, new_expires_at)
        return {"status": "applied", "charge_type": "scheduled_downgrade"}

    service._try_due_auto_charge = fake_auto_charge

    refreshed = asyncio.run(service.check_and_reset_credits(email, user))

    assert refreshed["subscription_plan_code"] == "lite"
    assert refreshed["pending_plan_code"] is None
    assert refreshed["last_auto_charge_type"] == "scheduled_downgrade"
    assert service.grant_repo.grant["status"] == "active"


def test_subscription_linked_grant_survives_paid_to_paid_transition():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now - timedelta(minutes=1),
        "subscription_status": "active",
        "pending_plan_code": "lite",
        "pending_effective_at": now - timedelta(minutes=1),
        "pending_duration_count": 1,
        "pending_duration_period": "month",
        "pending_billing_cycle": "monthly",
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "bonus",
        "status": "active",
        "amount_total": 500,
        "amount_used": 0,
        "expires_at": now - timedelta(minutes=1),
        "metadata": {"expires_at_mode": "subscription", "subscription_plan_code": "pro"},
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.check_and_reset_credits(email, user))

    assert refreshed["subscription_plan_code"] == "lite"
    assert service.grant_repo.grant["status"] == "active"
    assert service.grant_repo.grant["expires_at"] == refreshed["subscription_expires_at"]
    assert service.grant_repo.grant["metadata"]["subscription_plan_code"] == "lite"


def test_subscription_linked_grant_expires_after_confirmed_free_fallback():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now - timedelta(minutes=1),
        "subscription_status": "active",
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "bonus",
        "status": "active",
        "amount_total": 500,
        "amount_used": 0,
        "expires_at": now - timedelta(minutes=1),
        "metadata": {"expires_at_mode": "subscription", "subscription_plan_code": "pro"},
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.check_and_reset_credits(email, user))

    assert refreshed["subscription_plan_code"] == "free"
    assert service.grant_repo.grant["status"] == "expired"
    assert service.grant_repo.grant["expired_reason"] == "subscription_to_free"


def test_subscription_linked_grant_syncs_on_paid_renewal():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now + timedelta(days=10),
        "subscription_status": "active",
        "plan_current_period_end": now + timedelta(days=10),
    }
    grant = {
        "user_email": email,
        "credit_type": "bonus",
        "status": "active",
        "amount_total": 500,
        "amount_used": 0,
        "expires_at": now + timedelta(days=10),
        "metadata": {"expires_at_mode": "subscription", "subscription_plan_code": "pro"},
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.renew_subscription(
        email,
        "pro",
        duration_count=1,
        duration_period="month",
        billing_cycle="monthly",
        auto_renew=True,
    ))

    assert refreshed["subscription_plan_code"] == "pro"
    assert service.grant_repo.grant["status"] == "active"
    assert service.grant_repo.grant["expires_at"] == refreshed["subscription_expires_at"]
    assert service.grant_repo.grant["metadata"]["subscription_expires_at"] == refreshed["subscription_expires_at"]


def test_expired_same_plan_renew_starts_new_period_and_resets_credits():
    now = datetime.now(timezone.utc)
    email = "user@example.com"
    user = {
        "email": email,
        "subscription_plan_code": "pro",
        "subscription_expires_at": now - timedelta(minutes=1),
        "subscription_status": "active",
        "subscription_auto_renew": True,
        "plan_credits_total": 75000,
        "plan_credits_used": 74000,
        "credits_total": 75000,
        "credits_used": 74000,
        "plan_current_period_end": now - timedelta(minutes=1),
    }
    grant = {
        "user_email": email,
        "credit_type": "paid_topup",
        "status": "active",
        "amount_total": 500,
        "amount_used": 0,
        "expires_at": now - timedelta(minutes=1),
    }

    service = PlanService()
    service.plan_repo = _FakePlanRepo()
    service.user_repo = _FakeUserRepo(user)
    service.grant_repo = _FakeGrantRepo(grant)

    refreshed = asyncio.run(service.renew_subscription(
        email,
        "pro",
        duration_count=1,
        duration_period="month",
        billing_cycle="monthly",
        auto_renew=True,
    ))

    assert refreshed["subscription_plan_code"] == "pro"
    assert refreshed["plan_credits_used"] == 0
    assert refreshed["credits_used"] == 0
    assert refreshed["subscription_expires_at"] > now
