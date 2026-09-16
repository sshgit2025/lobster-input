"""修复历史套餐和积分的永久有效数据。

规则：
- 当前 trial 用户至少保留从订阅开始起 2 个月有效期。
- 非 free 套餐如果缺失订阅到期时间，按套餐重置周期补一个有限到期时间。
- active 的 bonus/paid_topup 批次如果缺失 expires_at，按来源策略或订阅到期时间补齐。
- 奖励积分策略 expires_days 强制至少 1 天。
"""
import asyncio
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

from dateutil.relativedelta import relativedelta

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.database import connect_db, close_db, get_db


DEFAULT_POLICY = {
    "registration_reward": {"enabled": True, "credits": 5000, "expires_days": 365},
    "invite_reward": {"enabled": False, "credits": 0, "expires_days": 365},
    "admin_grant": {"expires_days": 365},
}
PLAN_PERIODS = {"trial": "month", "weekly": "week", "monthly": "month", "yearly": "year"}


def add_period(start: datetime, period: str, count: int = 1) -> datetime:
    if period == "week":
        return start + timedelta(weeks=count)
    if period == "year":
        return start + relativedelta(years=count)
    return start + relativedelta(months=count)


def clean_policy(raw: dict) -> dict:
    policy = {k: dict(v) for k, v in DEFAULT_POLICY.items()}
    for source, cfg in (raw or {}).items():
        if isinstance(cfg, dict):
            merged = dict(policy.get(source, {}))
            merged.update(cfg)
            merged["expires_days"] = max(1, int(merged.get("expires_days") or 365))
            policy[source] = merged
    return policy


async def main() -> None:
    await connect_db()
    db = get_db()
    now = datetime.now(timezone.utc)
    stats = {"policy": 0, "users": 0, "grants": 0}

    doc = await db["system_config"].find_one({"key": "bonus_credit_policy"})
    policy = clean_policy(doc.get("value", {}) if doc else {})
    await db["system_config"].update_one(
        {"key": "bonus_credit_policy"},
        {"$set": {"value": policy, "updated_at": now}},
        upsert=True,
    )
    stats["policy"] = 1

    cursor = db["users"].find({
        "$or": [{"subscription_plan_code": {"$nin": [None, ""]}}, {"plan_code": {"$nin": [None, ""]}}],
    })
    for user in await cursor.to_list(length=None):
        plan_code = user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier")
        if plan_code == "free":
            continue
        started = user.get("subscription_started_at") or user.get("plan_started_at") or user.get("created_at") or now
        target = user.get("subscription_expires_at") or user.get("plan_expires_at")
        if plan_code == "trial":
            target = max(target or started, started + relativedelta(months=2))
        elif not target:
            target = add_period(started, PLAN_PERIODS.get(plan_code, "month"), 1)
        else:
            continue
        await db["users"].update_one(
            {"_id": user["_id"]},
            {"$set": {
                "subscription_expires_at": target,
                "plan_expires_at": target,
                "subscription_status": "active",
                "updated_at": now,
            }},
        )
        stats["users"] += 1

    cursor = db["credit_grants"].find({
        "status": "active",
        "$or": [{"expires_at": None}, {"expires_at": {"$exists": False}}],
    })
    for grant in await cursor.to_list(length=None):
        credit_type = grant.get("credit_type") or "bonus"
        created_at = grant.get("created_at") or now
        expires_at = None
        if credit_type == "paid_topup":
            user = await db["users"].find_one({"email": grant.get("user_email")})
            expires_at = (user or {}).get("subscription_expires_at") or (user or {}).get("plan_expires_at")
        if not expires_at:
            source = grant.get("source") or "admin_grant"
            days = max(1, int(policy.get(source, policy["admin_grant"]).get("expires_days") or 365))
            expires_at = created_at + timedelta(days=days)
        await db["credit_grants"].update_one(
            {"_id": grant["_id"]},
            {"$set": {"expires_at": expires_at, "updated_at": now}},
        )
        stats["grants"] += 1

    print(stats)
    await close_db()


if __name__ == "__main__":
    asyncio.run(main())
