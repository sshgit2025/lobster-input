"""幂等迁移：为积分批次补 credit_type 并创建索引。"""
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
        paid = await db["credit_grants"].update_many(
            {"source": "paid_topup", "credit_type": {"$exists": False}},
            {"$set": {"credit_type": "paid_topup", "updated_at": now}},
        )
        bonus = await db["credit_grants"].update_many(
            {"source": {"$ne": "paid_topup"}, "credit_type": {"$exists": False}},
            {"$set": {"credit_type": "bonus", "updated_at": now}},
        )
        await db["credit_grants"].create_index([("user_email", 1), ("credit_type", 1), ("expires_at", 1)])
        await db["payment_callback_events"].create_index("payment_event_id", unique=True)
        print(f"migrated credit grants: paid={paid.modified_count}, bonus={bonus.modified_count}")
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
