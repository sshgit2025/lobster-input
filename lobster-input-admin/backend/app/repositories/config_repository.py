from datetime import datetime, timezone
from typing import List, Optional
from motor.motor_asyncio import AsyncIOMotorDatabase


class ConfigRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.col = db["system_config"]

    async def get_all(self) -> List[dict]:
        cursor = self.col.find({})
        return await cursor.to_list(length=100)

    async def get(self, key: str) -> Optional[dict]:
        return await self.col.find_one({"key": key})

    async def set(self, key: str, value) -> bool:
        result = await self.col.update_one(
            {"key": key},
            {"$set": {"value": value, "updated_at": datetime.now(timezone.utc)}},
            upsert=True,
        )
        return result.acknowledged

    async def delete(self, key: str) -> bool:
        result = await self.col.delete_one({"key": key})
        return result.deleted_count > 0
