"""UserRepository — 共享主库 users 集合访问层（官网版）。

与主后端 app/repositories/user_repository.py 行为一致的子集：按邮箱查询、
创建用户、三维注册计数、套餐字段写入。下发给前端时务必屏蔽敏感明文字段
（密码哈希、设备指纹、注册 IP、会话 id 等）。
"""
from datetime import datetime, timezone
from typing import Optional

from app.core.database import get_db

COLLECTION = "users"

# 绝不可下发给前端的敏感字段投影
SAFE_PROJECTION = {
    "_id": 0,
    "hashed_password": 0,
    "reg_device_id": 0,
    "reg_ip": 0,
    "reg_hw_fingerprint": 0,
    "active_sessions": 0,
    "invited_by": 0,
    "used_invite_code": 0,
}


class UserRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def find_by_email(self, email: str) -> Optional[dict]:
        """内部使用：返回完整文档（含套餐积分字段，用于计算）。"""
        return await self.col.find_one({"email": email}, {"_id": 0})

    async def find_by_email_safe(self, email: str) -> Optional[dict]:
        """对外使用：屏蔽敏感字段。"""
        return await self.col.find_one({"email": email}, SAFE_PROJECTION)

    async def find_by_invite_code(self, invite_code: str) -> Optional[dict]:
        if not invite_code:
            return None
        return await self.col.find_one({"used_invite_code": invite_code}, {"_id": 0})

    # ── 三维注册限制计数（与主后端一致）──────────────────
    async def count_by_device_id(self, device_id: str) -> int:
        if not device_id:
            return 0
        return await self.col.count_documents({"reg_device_id": device_id})

    async def count_by_ip(self, ip: str) -> int:
        if not ip or ip in ("unknown", ""):
            return 0
        return await self.col.count_documents({"reg_ip": ip})

    async def count_by_hw_fingerprint(self, fingerprint: str) -> int:
        if not fingerprint:
            return 0
        return await self.col.count_documents({"reg_hw_fingerprint": fingerprint})

    # ── 创建 / 套餐写入（与主后端 create/assign_plan 一致）──
    async def create(
        self,
        email: str,
        reg_device_id: str = "",
        reg_ip: str = "",
        reg_hw_fingerprint: str = "",
        invited_by: str = "",
        used_invite_code: str = "",
    ) -> dict:
        now = datetime.now(timezone.utc)
        doc = {
            "email": email,
            "hashed_password": "",
            "tier": "trial",
            "is_active": True,
            "reg_device_id": reg_device_id,
            "reg_ip": reg_ip,
            "reg_hw_fingerprint": reg_hw_fingerprint,
            "invited_by": invited_by,
            "used_invite_code": used_invite_code,
            "registration_status": "created",
            "created_at": now,
            "updated_at": now,
            "credits_total": 0,
            "credits_used": 0,
            "credits_reset_at": None,
        }
        await self.col.insert_one(doc)
        doc.pop("_id", None)
        return doc

    async def assign_plan(self, email: str, plan_doc: dict) -> bool:
        now = datetime.now(timezone.utc)
        plan_code = plan_doc.get("subscription_plan_code") or plan_doc.get("plan_code", "none")
        result = await self.col.update_one(
            {"email": email},
            {"$set": {**plan_doc, "tier": plan_code, "plan_code": plan_code, "updated_at": now}},
        )
        return result.modified_count > 0

    async def mark_registration_complete(self, email: str) -> bool:
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email},
            {"$set": {"registration_status": "complete", "updated_at": now}},
        )
        return result.modified_count > 0
