"""幂等迁移：套餐/积分账户 v2。"""
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

from dateutil.relativedelta import relativedelta

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.database import connect_db, close_db, get_db
from app.repositories.plan_repository import (
    BONUS_CREDIT_POLICY_KEY,
    CREDIT_PRICING_RULES_KEY,
    DEFAULT_BONUS_CREDIT_POLICY,
    DEFAULT_CREDIT_PRICING_RULES,
    DEFAULT_PLAN_CONFIGS,
    PLAN_CONFIGS_KEY,
)


async def upsert_config(db, key, value):
    await db["system_config"].update_one(
        {"key": key},
        {"$setOnInsert": {"value": value, "created_at": datetime.now(timezone.utc)},
         "$set": {"updated_at": datetime.now(timezone.utc)}},
        upsert=True,
    )


async def main():
    await connect_db()
    try:
        db = get_db()
        now = datetime.now(timezone.utc)
        period_end = now + relativedelta(months=1)
        await upsert_config(db, PLAN_CONFIGS_KEY, DEFAULT_PLAN_CONFIGS)
        await upsert_config(db, CREDIT_PRICING_RULES_KEY, DEFAULT_CREDIT_PRICING_RULES)
        await upsert_config(db, BONUS_CREDIT_POLICY_KEY, DEFAULT_BONUS_CREDIT_POLICY)
        result = await db["users"].update_many(
            {},
            {"$set": {
                "tier": "trial",
                "plan_code": "trial",
                "plan_started_at": now,
                "plan_expires_at": period_end,
                "plan_current_period_start": now,
                "plan_current_period_end": period_end,
                "plan_credits_total": 10000,
                "plan_credits_used": 0,
                "credits_total": 10000,
                "credits_used": 0,
                "credits_reset_at": period_end,
                "updated_at": now,
            }},
        )
        await db["credit_grants"].create_index([("user_email", 1), ("expires_at", 1)])
        await db["credit_grants"].create_index("source")
        print(f"migrated users: matched={result.matched_count}, modified={result.modified_count}")
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
