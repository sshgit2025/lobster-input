from datetime import datetime, timezone
from typing import Optional
from motor.motor_asyncio import AsyncIOMotorDatabase
from app.core.security import hash_password, verify_password


class AdminRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.col = db["admin_users"]

    async def find_by_username(self, username: str) -> Optional[dict]:
        return await self.col.find_one({"username": username})

    async def verify_login(self, username: str, password: str) -> Optional[dict]:
        user = await self.find_by_username(username)
        if not user:
            return None
        if not verify_password(password, user["hashed_password"]):
            return None
        return user

    async def change_password(self, username: str, old_password: str, new_password: str) -> bool:
        user = await self.find_by_username(username)
        if not user or not verify_password(old_password, user["hashed_password"]):
            return False
        await self.col.update_one(
            {"username": username},
            {"$set": {
                "hashed_password": hash_password(new_password),
                "updated_at": datetime.now(timezone.utc),
            }}
        )
        return True
