"""
FeedbackRepository — 用户反馈数据访问层。
集合名: user_feedback
"""
from datetime import datetime, timezone
from bson import ObjectId
from app.core.database import get_db

COLLECTION = "user_feedback"
DEFAULT_STATUS = "未处理"
VALID_STATUSES = {"未处理", "挂起", "忽略", "实现中", "已实现"}


class FeedbackRepository:

    @property
    def col(self):
        return get_db()[COLLECTION]

    async def ensure_indexes(self) -> None:
        await self.col.create_index("user_email")
        await self.col.create_index("status")
        await self.col.create_index("created_at")
        await self.col.create_index("client_platform")
        await self.col.create_index("client_ip")
        await self.col.create_index([("status", 1), ("created_at", -1)])

    async def insert(self, doc: dict) -> str:
        now = datetime.now(timezone.utc)
        doc["status"] = DEFAULT_STATUS
        doc["created_at"] = now
        doc["updated_at"] = now
        result = await self.col.insert_one(doc)
        return str(result.inserted_id)

    async def query(
        self,
        email: str | None = None,
        status: str | None = None,
        limit: int = 100,
        skip: int = 0,
    ) -> list[dict]:
        filt: dict = {}
        if email:
            filt["user_email"] = {"$regex": email, "$options": "i"}
        if status:
            filt["status"] = status
        cursor = self.col.find(filt).sort("created_at", -1).skip(skip).limit(limit)
        items = await cursor.to_list(length=limit)
        return [self.serialize(item) for item in items]

    async def count(self, email: str | None = None, status: str | None = None) -> int:
        filt: dict = {}
        if email:
            filt["user_email"] = {"$regex": email, "$options": "i"}
        if status:
            filt["status"] = status
        return await self.col.count_documents(filt)

    async def update_status(self, feedback_id: str, status: str) -> bool:
        if status not in VALID_STATUSES:
            return False
        result = await self.col.update_one(
            {"_id": ObjectId(feedback_id)},
            {"$set": {"status": status, "updated_at": datetime.now(timezone.utc)}},
        )
        return result.matched_count > 0

    @staticmethod
    def serialize(doc: dict) -> dict:
        doc["id"] = str(doc.pop("_id"))
        for key in ("created_at", "updated_at"):
            if key in doc and hasattr(doc[key], "isoformat"):
                doc[key] = doc[key].isoformat()
        return doc
