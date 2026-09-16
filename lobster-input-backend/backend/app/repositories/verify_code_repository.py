"""
VerifyCodeRepository — 邮箱验证码数据访问层。
集合名: verify_codes
利用 MongoDB TTL 索引实现验证码自动过期删除，无需手动清理。
"""
from datetime import datetime, timezone, timedelta
from app.core.database import get_db
from app.core.config import settings

COLLECTION = "verify_codes"


class VerifyCodeRepository:
    """验证码仓库，提供保存、校验和自动过期功能。"""

    @property
    def col(self):
        """获取 MongoDB verify_codes 集合。"""
        return get_db()[COLLECTION]

    async def ensure_indexes(self) -> None:
        """
        确保索引存在（应用启动时调用）:
          - expires_at TTL 索引: 文档过期后自动删除
          - (email, purpose) 复合索引: 加速查询
        """
        await self.col.create_index("expires_at", expireAfterSeconds=0)
        await self.col.create_index([("email", 1), ("purpose", 1)])

    async def save(self, email: str, code: str, purpose: str) -> None:
        """保存验证码，同一邮箱+用途的旧验证码会被覆盖（upsert）。"""
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=settings.verify_code_ttl)
        await self.col.update_one(
            {"email": email, "purpose": purpose},
            {"$set": {"code": code, "expires_at": expires_at}},
            upsert=True,
        )

    async def verify_and_delete(self, email: str, code: str, purpose: str) -> bool:
        """校验验证码: 匹配且未过期则删除并返回 True，否则返回 False。"""
        result = await self.col.find_one_and_delete(
            {
                "email": email,
                "purpose": purpose,
                "code": code,
                "expires_at": {"$gt": datetime.now(timezone.utc)},
            }
        )
        return result is not None
