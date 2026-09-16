from app.services.billing.plan_policy import PlanPolicy


def test_plan_policy_disables_archived_checkout():
    policy = PlanPolicy.from_config({
        "code": "business",
        "paid": True,
        "enabled": True,
        "lifecycle_status": "archived",
        "self_checkout_enabled": True,
    })

    assert not policy.can_self_checkout_subscription


def test_plan_policy_rejects_stackable_as_base_subscription_checkout():
    policy = PlanPolicy.from_config({
        "code": "addon_credits",
        "paid": True,
        "enabled": True,
        "plan_family": "addon",
        "stackable": True,
        "self_checkout_enabled": True,
    })

    assert not policy.can_self_checkout_subscription


def test_plan_policy_rank_allows_equal_or_higher_immediate_replacement():
    free = PlanPolicy.from_config({"code": "free", "paid": False, "rank": 0}, "free")
    trial = PlanPolicy.from_config({"code": "trial", "paid": False, "rank": 0}, "trial")
    lite = PlanPolicy.from_config({"code": "lite", "paid": True, "rank": 10}, "lite")

    assert trial.can_replace_immediately(free)
    assert lite.can_replace_immediately(trial)
    assert not free.can_replace_immediately(lite)


def test_plan_policy_uses_catalog_auto_renew_capability_not_user_state():
    unsupported = PlanPolicy.from_config(
        {"code": "lite", "paid": True, "rank": 10, "auto_renew_supported": False},
        "lite",
    )
    legacy_supported = PlanPolicy.from_config(
        {"code": "lite", "paid": True, "rank": 10, "auto_renew_supported": True},
        "lite",
    )

    assert not unsupported.can_auto_renew
    assert legacy_supported.can_auto_renew


def test_plan_policy_empty_code_is_not_paid_by_default():
    policy = PlanPolicy.from_config({})

    assert not policy.paid
    assert not policy.can_self_checkout_subscription
