from datetime import datetime, timedelta, timezone

from app.services.billing.plan_policy import PlanPolicy
from app.services.billing.subscription_purchase_service import (
    CHARGE_TYPE_AUTO_RENEWAL,
    SubscriptionPurchaseService,
)


def test_billing_cycle_upgrade_is_not_treated_as_renewal():
    service = SubscriptionPurchaseService()
    user = {"subscription_plan_code": "lite", "subscription_billing_cycle": "monthly"}
    plan_config = {
        "code": "lite",
        "paid": True,
        "rank": 10,
        "billing_options": {
            "monthly": {"duration_period": "month", "duration_count": 1},
            "yearly": {"duration_period": "year", "duration_count": 1},
        }
    }

    policy = PlanPolicy.from_config(plan_config, "lite")
    assert service._resolve_mode(user, policy, plan_config, policy, "yearly", 1, "year") == "cycle_upgrade"


def test_billing_cycle_downgrade_requires_scheduled_payment():
    service = SubscriptionPurchaseService()
    user = {"subscription_plan_code": "lite", "subscription_billing_cycle": "yearly"}
    plan_config = {
        "code": "lite",
        "paid": True,
        "rank": 10,
        "billing_options": {
            "monthly": {"duration_period": "month", "duration_count": 1},
            "yearly": {"duration_period": "year", "duration_count": 1},
        }
    }

    policy = PlanPolicy.from_config(plan_config, "lite")
    try:
        service._resolve_mode(user, policy, plan_config, policy, "monthly", 1, "month")
    except ValueError as exc:
        assert "billing-cycle downgrade" in str(exc)
    else:
        raise AssertionError("billing-cycle downgrade should not activate immediately")


def test_configured_rank_controls_paid_tier_direction():
    service = SubscriptionPurchaseService()
    user = {"subscription_plan_code": "business", "subscription_billing_cycle": "monthly"}
    active = PlanPolicy.from_config({"code": "business", "paid": True, "rank": 40}, "business")
    target = PlanPolicy.from_config({"code": "team", "paid": True, "rank": 20}, "team")

    try:
        service._resolve_mode(user, active, {}, target, "monthly", 1, "month")
    except ValueError as exc:
        assert "downgrade" in str(exc)
    else:
        raise AssertionError("lower configured rank should be treated as a downgrade")


def test_paid_purchase_can_replace_free_or_trial_by_configured_rank():
    service = SubscriptionPurchaseService()
    target = PlanPolicy.from_config({"code": "lite", "paid": True, "rank": 10}, "lite")

    for active_code in ("free", "trial"):
        active = PlanPolicy.from_config({"code": active_code, "paid": False, "rank": 0}, active_code)
        assert service._resolve_mode(
            {"subscription_plan_code": active_code},
            active,
            {},
            target,
            "monthly",
            1,
            "month",
        ) == "activate_now"


def test_equal_rank_allows_immediate_replacement_for_admin_configured_peer_plans():
    service = SubscriptionPurchaseService()
    active = PlanPolicy.from_config({"code": "free", "paid": False, "rank": 0}, "free")
    target = PlanPolicy.from_config({"code": "trial", "paid": False, "rank": 0}, "trial")

    assert service._resolve_mode(
        {"subscription_plan_code": "free"},
        active,
        {},
        target,
        "monthly",
        1,
        "month",
    ) == "activate_now"


def test_unused_refund_amount_prorates_remaining_paid_period():
    now = datetime.now(timezone.utc)
    started = now - timedelta(days=10)
    expires = now + timedelta(days=20)
    event = {
        "price_cents": 3000,
        "refunded_cents": 0,
        "entitlement_started_at": started,
        "entitlement_expires_at": expires,
    }

    assert SubscriptionPurchaseService._unused_refund_amount(event, now) == 2000


def test_unused_refund_amount_respects_existing_refunds():
    now = datetime.now(timezone.utc)
    event = {
        "price_cents": 3000,
        "refunded_cents": 2500,
        "entitlement_started_at": now - timedelta(days=1),
        "entitlement_expires_at": now + timedelta(days=29),
    }

    assert SubscriptionPurchaseService._unused_refund_amount(event, now) == 500


def test_auto_charge_event_id_is_stable_for_same_billing_boundary():
    expires = datetime(2026, 5, 18, 10, 30, tzinfo=timezone.utc)

    first = SubscriptionPurchaseService._auto_charge_event_id(
        user_email="user@example.com",
        charge_type=CHARGE_TYPE_AUTO_RENEWAL,
        expires_at=expires,
        target_plan_code="pro",
        billing_cycle="monthly",
    )
    second = SubscriptionPurchaseService._auto_charge_event_id(
        user_email="user@example.com",
        charge_type=CHARGE_TYPE_AUTO_RENEWAL,
        expires_at=expires,
        target_plan_code="pro",
        billing_cycle="monthly",
    )

    assert first == second
    assert first.startswith("auto:auto_renewal:")


def test_charge_type_validation_rejects_unknown_values():
    try:
        SubscriptionPurchaseService._normalize_charge_type("legacy-renew")
    except ValueError as exc:
        assert "charge type" in str(exc)
    else:
        raise AssertionError("unknown charge types should be rejected")
