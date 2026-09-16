"""幂等迁移：套餐模板 + 用户订阅模型 v3。"""
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.database import close_db, connect_db, get_db
from app.repositories.plan_repository import DEFAULT_PLAN_CONFIGS, PLAN_CONFIGS_KEY


def clean_plan_configs(configs: dict) -> dict:
    cleaned = {}
    for code, cfg in (configs or {}).items():
        if not isinstance(cfg, dict):
            continue
        row = dict(cfg)
        row["code"] = row.get("code") or code
        row.pop("duration_period", None)
        row.pop("duration_count", None)
        cleaned[code] = row
    return cleaned


async def migrate_plan_configs(db) -> None:
    doc = await db["system_config"].find_one({"key": PLAN_CONFIGS_KEY})
    current = doc.get("value") if doc else DEFAULT_PLAN_CONFIGS
    await db["system_config"].update_one(
        {"key": PLAN_CONFIGS_KEY},
        {"$set": {
            "value": clean_plan_configs(current),
            "updated_at": datetime.now(timezone.utc),
        }},
        upsert=True,
    )


async def migrate_users(db) -> tuple[int, int]:
    matched = 0
    modified = 0
    cursor = db["users"].find({}, {"hashed_password": 0})
    async for user in cursor:
        matched += 1
        plan_code = user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier") or "free"
        started_at = user.get("subscription_started_at") or user.get("plan_started_at") or user.get("created_at")
        expires_at = user.get("subscription_expires_at", user.get("plan_expires_at"))
        update = {
            "subscription_plan_code": plan_code,
            "subscription_started_at": started_at,
            "subscription_expires_at": expires_at,
            "subscription_status": user.get("subscription_status") or "active",
            "subscription_auto_renew": bool(user.get("subscription_auto_renew", False)),
            "plan_code": plan_code,
            "plan_expires_at": expires_at,
            "tier": plan_code,
            "updated_at": datetime.now(timezone.utc),
        }
        result = await db["users"].update_one({"_id": user["_id"]}, {"$set": update})
        modified += result.modified_count
    return matched, modified


async def ensure_indexes(db) -> None:
    await db["users"].create_index("subscription_plan_code")
    await db["users"].create_index("subscription_expires_at")
    await db["users"].create_index("pending_effective_at")


async def main():
    await connect_db()
    try:
        db = get_db()
        await migrate_plan_configs(db)
        matched, modified = await migrate_users(db)
        await ensure_indexes(db)
        print(f"migrated subscription users: matched={matched}, modified={modified}")
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
