"""幂等迁移：补齐积分批次 status，后续扣费只消费 active 批次。"""
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.database import close_db, connect_db, get_db


async def main():
    await connect_db()
    try:
        db = get_db()
        now = datetime.now(timezone.utc)
        active = await db["credit_grants"].update_many(
            {
                "status": {"$exists": False},
                "$or": [{"expires_at": None}, {"expires_at": {"$gt": now}}],
            },
            {"$set": {"status": "active", "updated_at": now}},
        )
        expired = await db["credit_grants"].update_many(
            {"status": {"$exists": False}, "expires_at": {"$ne": None, "$lte": now}},
            {"$set": {"status": "expired", "expired_reason": "expires_at", "updated_at": now}},
        )
        await db["credit_grants"].create_index([("user_email", 1), ("credit_type", 1), ("status", 1)])
        print(f"migrated credit grant status: active={active.modified_count}, expired={expired.modified_count}")
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
