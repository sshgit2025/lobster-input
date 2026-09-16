"""
ClientLogRepository — 客户端日志数据访问层。
集合名: client_logs
存储客户端上报的运行日志，用于远程排查权限、OpenClaw、网络等问题。
"""
from datetime import datetime, timezone
from app.core.database import get_db

COLLECTION = "client_logs"


class ClientLogRepository:

    @property
    def col(self):
        return get_db()[COLLECTION]

    async def ensure_indexes(self) -> None:
        await self.col.create_index("user_email")
        await self.col.create_index("created_at")
        await self.col.create_index("level")
        await self.col.create_index([("user_email", 1), ("created_at", -1)])

    async def insert(self, doc: dict) -> None:
        doc["created_at"] = datetime.now(timezone.utc)
        await self.col.insert_one(doc)

    async def query(
        self,
        email: str | None = None,
        level: str | None = None,
        limit: int = 100,
        skip: int = 0,
    ) -> list[dict]:
        filt: dict = {}
        if email:
            filt["user_email"] = email
        if level:
            filt["level"] = level
        cursor = self.col.find(filt, {"_id": 0}).sort("created_at", -1).skip(skip).limit(limit)
        return await cursor.to_list(length=limit)

    async def count(self, email: str | None = None, level: str | None = None) -> int:
        filt: dict = {}
        if email:
            filt["user_email"] = email
        if level:
            filt["level"] = level
        return await self.col.count_documents(filt)
