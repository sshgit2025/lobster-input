"""套餐购买闸门规则:有效优先级 = (等级 rank, 账期时长),仅允许严格向上购买。"""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException

from app.api.v1.payments import (
    BLOCK_REASON_CYCLE_DOWNGRADE,
    BLOCK_REASON_DUPLICATE,
    BLOCK_REASON_LOWER_TIER,
    _checkout_block_reason,
    _cycle_duration_months,
    _reject_duplicate_or_downgrade_checkout,
)


def _plan(code: str, rank: int, *, paid: bool = True) -> dict:
    return {
        "code": code,
        "paid": paid,
        "rank": rank,
        "billing_options": {
            "monthly": {"enabled": True, "duration_period": "month", "duration_count": 1},
            "yearly": {"enabled": True, "duration_period": "year", "duration_count": 1},
        },
    }


def _user(plan_code: str, cycle: str) -> dict:
    return {
        "subscription_plan_code": plan_code,
        "subscription_billing_cycle": cycle,
        "subscription_expires_at": datetime.now(timezone.utc) + timedelta(days=15),
    }


LITE = _plan("lite", 10)
STANDARD = _plan("standard", 20)
PRO = _plan("pro", 30)
FREE = _plan("free", 0, paid=False)
YEAR = _cycle_duration_months("year", 1)
MONTH = _cycle_duration_months("month", 1)


def test_free_user_can_buy_anything():
    user = {"subscription_plan_code": "free"}
    assert _checkout_block_reason(user, FREE, LITE, MONTH) is None
    assert _checkout_block_reason(user, FREE, PRO, YEAR) is None


def test_monthly_can_upgrade_to_yearly_same_plan():
    assert _checkout_block_reason(_user("lite", "monthly"), LITE, LITE, YEAR) is None


def test_yearly_cannot_downgrade_to_monthly_same_plan():
    assert _checkout_block_reason(_user("lite", "yearly"), LITE, LITE, MONTH) == BLOCK_REASON_CYCLE_DOWNGRADE


def test_same_plan_same_cycle_is_duplicate():
    assert _checkout_block_reason(_user("lite", "monthly"), LITE, LITE, MONTH) == BLOCK_REASON_DUPLICATE


def test_higher_tier_monthly_cannot_buy_lower_tier_yearly():
    assert _checkout_block_reason(_user("pro", "monthly"), PRO, LITE, YEAR) == BLOCK_REASON_LOWER_TIER


def test_yearly_user_cannot_buy_higher_tier_monthly():
    assert _checkout_block_reason(_user("lite", "yearly"), LITE, PRO, MONTH) == BLOCK_REASON_CYCLE_DOWNGRADE


def test_monthly_user_can_buy_higher_tier_monthly_or_yearly():
    user = _user("lite", "monthly")
    assert _checkout_block_reason(user, LITE, STANDARD, MONTH) is None
    assert _checkout_block_reason(user, LITE, STANDARD, YEAR) is None


def test_expired_subscription_is_not_gated():
    user = _user("pro", "yearly")
    user["subscription_expires_at"] = datetime.now(timezone.utc) - timedelta(days=1)
    assert _checkout_block_reason(user, PRO, LITE, MONTH) is None


def test_reject_raises_http_400():
    with pytest.raises(HTTPException) as exc:
        _reject_duplicate_or_downgrade_checkout(_user("lite", "yearly"), LITE, LITE, MONTH)
    assert exc.value.status_code == 400
