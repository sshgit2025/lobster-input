"""
协议内容仓库。
存储结构：每条记录 { type, lang, content, updated_at }
type: "terms" | "privacy" | ...
lang: "zh" | "en" | "zh-Hant" | "yue" | "ru" | "ko"
"""
from datetime import datetime, timezone
from app.core.database import get_db


class AgreementRepository:
    COLLECTION = "agreements"

    @property
    def col(self):
        return get_db()[self.COLLECTION]

    async def get(self, agreement_type: str, lang: str):
        """按 type + lang 查询协议内容。"""
        doc = await self.col.find_one(
            {"type": agreement_type, "lang": lang},
            {"_id": 0},
        )
        return doc

    async def upsert(self, agreement_type: str, lang: str, content: str):
        """新增或更新协议内容。"""
        now = datetime.now(timezone.utc)
        await self.col.update_one(
            {"type": agreement_type, "lang": lang},
            {"$set": {"content": content, "updated_at": now}},
            upsert=True,
        )

    async def list_all(self):
        """列出所有协议（不含 _id）。"""
        cursor = self.col.find({}, {"_id": 0})
        return await cursor.to_list(length=None)

    async def delete(self, agreement_type: str, lang: str) -> bool:
        result = await self.col.delete_one(
            {"type": agreement_type, "lang": lang}
        )
        return result.deleted_count > 0

    async def ensure_indexes(self):
        await self.col.create_index(
            [("type", 1), ("lang", 1)], unique=True
        )
