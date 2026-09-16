"""InviteRepository — 共享主库 invite_codes 集合（官网版）。

与主后端 app/repositories/invite_repository.py 一致：邀请码 8 位、字符集排除
易混淆字符；校验可用、标记已用、为用户生成 3 个邀请码。
"""
import logging
import secrets
from datetime import datetime, timezone
from typing import Optional

from pymongo import ReturnDocument
from pymongo.errors import DuplicateKeyError
from app.core.database import get_db

COLLECTION = "invite_codes"
INVITE_CHARSET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
INVITE_CODE_LENGTH = 8
CODES_PER_USER = 3

logger = logging.getLogger("lobster_landing.invite")


def _generate_code() -> str:
    return "".join(secrets.choice(INVITE_CHARSET) for _ in range(INVITE_CODE_LENGTH))


def normalize_invite_code(code: str) -> str:
    return "".join(ch for ch in (code or "").strip().upper() if ch in INVITE_CHARSET)


class InviteRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def get_codes_by_owner(self, owner_email: str) -> list[dict]:
        cursor = self.col.find({"owner_email": owner_email}, {"_id": 0})
        return await cursor.to_list(length=CODES_PER_USER + 5)

    async def create_codes_for_user(self, owner_email: str) -> list[dict]:
        existing = await self.get_codes_by_owner(owner_email)
        if len(existing) >= CODES_PER_USER:
            return existing[:CODES_PER_USER]
        needed = CODES_PER_USER - len(existing)
        created: list[dict] = []
        attempts = 0
        while len(created) < needed and attempts < 50:
            attempts += 1
            code = _generate_code()
            if await self.col.find_one({"code": code}):
                continue
            now = datetime.now(timezone.utc)
            doc = {
                "code": code,
                "owner_email": owner_email,
                "is_used": False,
                "used_by": None,
                "used_at": None,
                "updated_at": now,
                "created_at": now,
            }
            try:
                await self.col.insert_one(doc)
                doc.pop("_id", None)
                created.append(doc)
            except DuplicateKeyError:
                logger.warning("[invite] duplicate key on insert code=%s, retrying", code)
                continue
        return (existing + created)[:CODES_PER_USER]

    async def find_available_code(self, code: str) -> Optional[dict]:
        normalized = normalize_invite_code(code)
        if len(normalized) != INVITE_CODE_LENGTH:
            return None
        return await self.col.find_one({"code": normalized, "is_used": False}, {"_id": 0})

    async def mark_code_used(self, code: str, used_by_email: str) -> Optional[dict]:
        normalized = normalize_invite_code(code)
        if len(normalized) != INVITE_CODE_LENGTH:
            return None
        now = datetime.now(timezone.utc)
        return await self.col.find_one_and_update(
            {"code": normalized, "$or": [{"is_used": False}, {"used_by": used_by_email}]},
            {"$set": {"is_used": True, "used_by": used_by_email, "used_at": now, "updated_at": now}},
            projection={"_id": 0},
            return_document=ReturnDocument.AFTER,
        )
