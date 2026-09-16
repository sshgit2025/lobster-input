import unittest
from fastapi import HTTPException

from app.api.v1.payments import _resolve_change_mode
from app.api.v1.plans import _can_auto_renew, _can_replace_immediately, _clean_plan_configs


class PlanPriorityTests(unittest.TestCase):
    def test_admin_plan_rank_allows_trial_to_cover_free(self):
        configs = _clean_plan_configs({
            "free": {"paid": False, "rank": 0},
            "trial": {"paid": False, "rank": 0},
        })

        self.assertTrue(_can_replace_immediately(configs["free"], configs["trial"]))

    def test_admin_plan_rank_rejects_lower_priority_manual_cover(self):
        configs = _clean_plan_configs({
            "free": {"paid": False, "rank": 0},
            "lite": {"paid": True, "rank": 10},
        })

        self.assertFalse(_can_replace_immediately(configs["lite"], configs["free"]))

    def test_payment_rank_allows_paid_plan_to_cover_trial(self):
        active = {"code": "trial", "paid": False, "rank": 0}
        target = {"code": "lite", "paid": True, "rank": 10}

        self.assertEqual(
            _resolve_change_mode(
                {"subscription_plan_code": "trial"},
                "trial",
                active,
                "lite",
                target,
                "monthly",
                1,
                "month",
            ),
            "activate_now",
        )

    def test_payment_rank_rejects_paid_plan_downgrade(self):
        active = {"code": "pro", "paid": True, "rank": 30}
        target = {"code": "lite", "paid": True, "rank": 10}

        with self.assertRaises(HTTPException) as ctx:
            _resolve_change_mode(
                {"subscription_plan_code": "pro", "subscription_billing_cycle": "monthly"},
                "pro",
                active,
                "lite",
                target,
                "monthly",
                1,
                "month",
            )

        self.assertEqual(ctx.exception.status_code, 400)
        self.assertIn("降级", ctx.exception.detail)

    def test_plan_auto_renew_supported_is_catalog_capability(self):
        configs = _clean_plan_configs({
            "lite": {"paid": True, "rank": 10, "auto_renew_supported": False},
            "pro": {"paid": True, "rank": 30, "auto_renew_supported": True},
        })

        self.assertFalse(_can_auto_renew(configs["lite"]))
        self.assertTrue(_can_auto_renew(configs["pro"]))
        self.assertFalse(configs["lite"]["auto_renew_supported"])

    def test_plan_validity_period_is_distinct_from_reset_period(self):
        configs = _clean_plan_configs({
            "trial": {"paid": False, "reset_period": "month", "validity_period": "day", "validity_count": 7},
            "free": {"paid": False, "reset_period": "week", "validity_period": "forever", "validity_count": 99},
        })

        self.assertEqual(configs["trial"]["reset_period"], "month")
        self.assertEqual(configs["trial"]["validity_period"], "day")
        self.assertEqual(configs["trial"]["validity_count"], 7)
        self.assertEqual(configs["free"]["validity_period"], "forever")
        self.assertEqual(configs["free"]["validity_count"], 0)


if __name__ == "__main__":
    unittest.main()
