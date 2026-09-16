from datetime import datetime, timezone
from motor.motor_asyncio import AsyncIOMotorDatabase


class AdminRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self._col = db["admin_users"]

    async def ensure_indexes(self) -> None:
        await self._col.create_index("username", unique=True)

    async def find_by_username(self, username: str):
        return await self._col.find_one({"username": username})

    async def update_password(
        self, username: str, hashed_password: str
    ):
        await self._col.update_one(
            {"username": username},
            {"$set": {
                "hashed_password": hashed_password,
                "updated_at": datetime.now(timezone.utc),
            }},
        )
