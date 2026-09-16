"""PendingRegistrationRepository — 邮箱已验证、等待填邀请码的注册中间态。

集合 pending_registrations 与主后端共享，逻辑保持一致（30 分钟 TTL 由主后端
建立的索引负责，官网只读写文档本身）。
"""
from datetime import datetime, timezone, timedelta
from app.core.database import get_db

COLLECTION = "pending_registrations"


class PendingRegistrationRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def save(self, email: str) -> None:
        now = datetime.now(timezone.utc)
        await self.col.update_one(
            {"email": email},
            {
                "$set": {"updated_at": now, "expires_at": now + timedelta(minutes=30)},
                "$setOnInsert": {"email": email, "verified_at": now},
            },
            upsert=True,
        )

    async def exists(self, email: str) -> bool:
        return await self.col.find_one({"email": email}, {"_id": 1}) is not None

    async def delete(self, email: str) -> None:
        await self.col.delete_one({"email": email})
