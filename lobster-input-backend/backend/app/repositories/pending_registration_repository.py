"""
PendingRegistrationRepository — 已通过邮箱验证、等待完成注册的中间态。

集合名: pending_registrations

这个状态不是验证码，也不是邀请码。它只表示某个邮箱已经完成验证码校验，
可以继续执行邀请码注册流程，因此不能复用 verify_codes 的 TTL 过期策略。
"""
from datetime import datetime, timezone, timedelta

from app.core.database import get_db

COLLECTION = "pending_registrations"


class PendingRegistrationRepository:
    """保存邮箱验证码通过后的注册中间态。"""

    @property
    def col(self):
        return get_db()[COLLECTION]

    async def ensure_indexes(self) -> None:
        await self.col.create_index("email", unique=True)
        await self.col.create_index("updated_at")
        await self.col.create_index("expires_at", expireAfterSeconds=0)

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
