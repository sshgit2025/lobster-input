"""
HotWordRepository — 热词词典的 MongoDB 数据访问层。
集合名: hotwords | 按 user_email 隔离 | 唯一索引: (user_email, word)
"""
import uuid
from typing import Optional
from datetime import datetime, timezone

from app.core.config import settings
from app.core.database import get_db
from app.models.schemas import HotWord

COLLECTION = "hotwords"


class HotWordRepository:
    """热词仓库，提供按用户隔离的 CRUD 操作。"""

    @property
    def max_count(self) -> int:
        return settings.hotword_max_count

    @property
    def col(self):
        return get_db()[COLLECTION]

    async def ensure_indexes(self) -> None:
        await self.col.create_index(
            [("user_email", 1), ("word", 1)], unique=True
        )
        await self.col.create_index(
            [("user_email", 1), ("id", 1)],
        )

    async def list_by_user(self, user_email: str) -> list[HotWord]:
        docs = await self.col.find(
            {"user_email": user_email}, {"_id": 0, "user_email": 0}
        ).to_list(length=None)
        return [HotWord(**doc) for doc in docs]

    async def list_all(
        self,
        *,
        user_email: str | None = None,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[dict], int]:
        query = {}
        if user_email:
            query["user_email"] = user_email
        total = await self.col.count_documents(query)
        skip = max(0, page - 1) * page_size
        docs = await self.col.find(
            query,
            {"_id": 0},
        ).sort("created_at", -1).skip(skip).limit(page_size).to_list(length=page_size)
        return docs, total

    async def get_by_id(self, user_email: str, hw_id: str) -> Optional[HotWord]:
        doc = await self.col.find_one(
            {"user_email": user_email, "id": hw_id},
            {"_id": 0, "user_email": 0},
        )
        return HotWord(**doc) if doc else None

    async def count_by_user(self, user_email: str) -> int:
        return await self.col.count_documents({"user_email": user_email})

    async def create(self, user_email: str, word: str) -> HotWord:
        count = await self.count_by_user(user_email)
        if count >= settings.hotword_max_count:
            raise ValueError(
                f"热词数量已达上限（{settings.hotword_max_count}条），"
                "请删除不需要的热词后再添加"
            )
        hw = HotWord(
            id=uuid.uuid4().hex[:12],
            word=word,
            created_at=datetime.now(timezone.utc),
        )
        await self.col.insert_one({"user_email": user_email, **hw.model_dump()})
        return hw

    async def update(self, user_email: str, hw_id: str, word: str) -> Optional[HotWord]:
        result = await self.col.update_one(
            {"user_email": user_email, "id": hw_id},
            {"$set": {"word": word}},
        )
        if result.matched_count == 0:
            return None
        return await self.get_by_id(user_email, hw_id)

    async def delete(self, user_email: str, hw_id: str) -> bool:
        result = await self.col.delete_one(
            {"user_email": user_email, "id": hw_id}
        )
        return result.deleted_count > 0
