"""
InviteRepository — 邀请码数据访问层。
集合名: invite_codes
每个用户登录成功后生成 3 个唯一 8 位邀请码，新用户注册时需消耗一个有效邀请码。
邀请码字符集: 大写字母 + 数字，排除易混淆字符（O/0/I/1/L）。
总空间 31^8 ≈ 8529亿，5000万上限仅占 0.006%，碰撞概率极低。
"""
import secrets
import logging
from typing import Optional
from datetime import datetime, timezone

from pymongo import ReturnDocument
from pymongo.errors import DuplicateKeyError
from app.core.database import get_db

COLLECTION = "invite_codes"
INVITE_CHARSET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
INVITE_CODE_LENGTH = 8
CODES_PER_USER = 3

logger = logging.getLogger("voice_input.invite")


def _generate_code() -> str:
    return "".join(secrets.choice(INVITE_CHARSET) for _ in range(INVITE_CODE_LENGTH))


def normalize_invite_code(code: str) -> str:
    return "".join(
        ch for ch in (code or "").strip().upper()
        if ch in INVITE_CHARSET
    )


class InviteRepository:
    """邀请码仓库：生成、校验、状态查询。"""

    @property
    def col(self):
        return get_db()[COLLECTION]

    async def ensure_indexes(self) -> None:
        await self.col.create_index("code", unique=True)
        await self.col.create_index("owner_email")
        await self.col.create_index("used_by")
        await self.col.create_index("used_at")

    async def get_codes_by_owner(self, owner_email: str) -> list[dict]:
        cursor = self.col.find({"owner_email": owner_email}, {"_id": 0})
        return await cursor.to_list(length=CODES_PER_USER + 5)

    async def create_codes_for_user(self, owner_email: str) -> list[dict]:
        """为用户生成 CODES_PER_USER 个唯一邀请码（幂等：已有则跳过）。
        
        生成策略：先随机生成，再查库去重，最后依赖唯一索引兜底。
        DuplicateKeyError 视为碰撞重试，其他异常正常上抛。
        """
        existing = await self.get_codes_by_owner(owner_email)
        if len(existing) >= CODES_PER_USER:
            return existing[:CODES_PER_USER]

        needed = CODES_PER_USER - len(existing)
        created = []
        attempts = 0
        while len(created) < needed and attempts < 50:
            attempts += 1
            code = _generate_code()
            existing_code = await self.col.find_one({"code": code})
            if existing_code:
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
                # 极小概率并发竞争导致唯一索引冲突，重新生成即可
                logger.warning("[invite] duplicate key on insert code=%s, retrying", code)
                continue

        logger.info("[invite] created %d codes for %s", len(created), owner_email)
        all_codes = existing + created
        return all_codes[:CODES_PER_USER]

    async def find_available_code(self, code: str) -> Optional[dict]:
        normalized = normalize_invite_code(code)
        if len(normalized) != INVITE_CODE_LENGTH:
            return None
        return await self.col.find_one(
            {"code": normalized, "is_used": False},
            {"_id": 0},
        )

    async def mark_code_used(self, code: str, used_by_email: str) -> Optional[dict]:
        """幂等标记邀请码已被指定邮箱使用。

        邀请码真正的一次性约束由 users.used_invite_code 唯一索引兜底；
        这里更新 invite_codes 只是让展示状态与注册结果保持一致。
        """
        normalized = normalize_invite_code(code)
        if len(normalized) != INVITE_CODE_LENGTH:
            return None
        now = datetime.now(timezone.utc)
        return await self.col.find_one_and_update(
            {
                "code": normalized,
                "$or": [
                    {"is_used": False},
                    {"used_by": used_by_email},
                ],
            },
            {"$set": {
                "is_used": True,
                "used_by": used_by_email,
                "used_at": now,
                "updated_at": now,
            }},
            projection={"_id": 0},
            return_document=ReturnDocument.AFTER,
        )

    async def consume_valid_code(self, code: str, used_by_email: str) -> Optional[dict]:
        """兼容旧调用方：邀请码状态标记。新注册流程不再依赖它做提交点。"""
        return await self.mark_code_used(code, used_by_email)
