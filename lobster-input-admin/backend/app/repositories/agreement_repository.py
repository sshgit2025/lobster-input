"""
协议内容仓库（管理端版本，通过传入 db 实例操作主库的 agreements 集合）。
"""
from datetime import datetime, timezone
from motor.motor_asyncio import AsyncIOMotorDatabase


class AgreementRepository:
    COLLECTION = "agreements"

    def __init__(self, db: AsyncIOMotorDatabase):
        self.col = db[self.COLLECTION]

    async def get(self, agreement_type: str, lang: str):
        doc = await self.col.find_one(
            {"type": agreement_type, "lang": lang},
            {"_id": 0},
        )
        return doc

    async def upsert(self, agreement_type: str, lang: str, content: str):
        now = datetime.now(timezone.utc)
        await self.col.update_one(
            {"type": agreement_type, "lang": lang},
            {"$set": {"content": content, "updated_at": now}},
            upsert=True,
        )

    async def list_all(self):
        cursor = self.col.find({}, {"_id": 0})
        return await cursor.to_list(length=None)

    async def delete(self, agreement_type: str, lang: str) -> bool:
        result = await self.col.delete_one(
            {"type": agreement_type, "lang": lang}
        )
        return result.deleted_count > 0
