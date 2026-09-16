"""VerifyCodeRepository — 校验共享主库 verify_codes 集合里的邮箱验证码。

验证码由主后端的 /auth/send-code 写入（官网代理调用），官网在登录/注册时
直接读取并删除，逻辑与主后端 verify_and_delete 完全一致。
"""
from datetime import datetime, timezone
from app.core.database import get_db

COLLECTION = "verify_codes"
PURPOSE_UNIFIED = "unified"


class VerifyCodeRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def verify_and_delete(self, email: str, code: str, purpose: str = PURPOSE_UNIFIED) -> bool:
        """匹配且未过期则原子删除并返回 True，否则 False。"""
        result = await self.col.find_one_and_delete(
            {
                "email": email,
                "purpose": purpose,
                "code": code,
                "expires_at": {"$gt": datetime.now(timezone.utc)},
            }
        )
        return result is not None
