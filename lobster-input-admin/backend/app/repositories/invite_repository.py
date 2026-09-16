import secrets
from datetime import datetime, timezone
from typing import List, Optional
from motor.motor_asyncio import AsyncIOMotorDatabase
from pymongo.errors import DuplicateKeyError


def _gen_code(length: int = 8) -> str:
    chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(chars) for _ in range(length))


class InviteRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.col = db["invite_codes"]

    async def count(self, query: dict) -> int:
        return await self.col.count_documents(query)

    async def find_paginated(self, query: dict, page: int, page_size: int) -> List[dict]:
        skip = (page - 1) * page_size
        cursor = self.col.find(query).sort("created_at", -1).skip(skip).limit(page_size)
        return await cursor.to_list(length=page_size)

    async def create_codes(self, owner_email: str, count: int = 1) -> List[str]:
        codes = []
        attempts = 0
        while len(codes) < count and attempts < count * 10:
            attempts += 1
            code = _gen_code()
            existing = await self.col.find_one({"code": code})
            if existing:
                continue
            try:
                await self.col.insert_one({
                    "code": code,
                    "owner_email": owner_email,
                    "is_used": False,
                    "used_by": None,
                    "used_at": None,
                    "created_at": datetime.now(timezone.utc),
                })
                codes.append(code)
            except DuplicateKeyError:
                # 极小概率并发竞争导致唯一索引冲突，重新生成即可
                continue
        return codes

    async def delete_code(self, code: str) -> bool:
        result = await self.col.delete_one({"code": code, "is_used": False})
        return result.deleted_count > 0

    async def get_stats(self) -> dict:
        total = await self.col.count_documents({})
        used = await self.col.count_documents({"is_used": True})
        return {"total": total, "used": used, "unused": total - used}
