"""
UserRepository — 用户数据访问层。
集合名: users | 唯一索引: email
新用户默认等级为 trial，密码字段预留（当前使用验证码登录）。
注册时记录设备 ID、硬件指纹和 IP（全部明文存储），支持三维度联动封禁注册限制。
明文存储目的：运营排查误封禁、关联同设备账号、人工解封。
"""
from typing import Optional
from datetime import datetime, timezone
from app.core.database import get_db

COLLECTION = "users"
SYSTEM_CONFIG_COLLECTION = "system_config"


class UserRepository:
    """用户仓库，提供按邮箱查询、创建用户及多维度设备注册限制功能。"""

    @property
    def col(self):
        return get_db()[COLLECTION]

    @property
    def config_col(self):
        return get_db()[SYSTEM_CONFIG_COLLECTION]

    async def ensure_indexes(self) -> None:
        """确保必要索引存在（应用启动时调用）。"""
        await self.col.create_index("email", unique=True)
        await self.col.create_index(
            "used_invite_code",
            unique=True,
            partialFilterExpression={"used_invite_code": {"$exists": True, "$gt": ""}},
        )
        await self.col.create_index("reg_device_id")
        await self.col.create_index("reg_ip")
        await self.col.create_index("reg_hw_fingerprint")
        await self.col.create_index("plan_code")
        await self.col.create_index("subscription_plan_code")
        await self.col.create_index("subscription_expires_at")
        await self.col.create_index("subscription_auto_renew")
        await self.col.create_index("pending_effective_at")
        await self.col.create_index("plan_current_period_end")

    async def find_by_email(self, email: str) -> Optional[dict]:
        return await self.col.find_one({"email": email}, {"_id": 0})

    async def find_by_invite_code(self, invite_code: str) -> Optional[dict]:
        if not invite_code:
            return None
        return await self.col.find_one({"used_invite_code": invite_code}, {"_id": 0})

    async def set_active_session(
        self,
        email: str,
        platform: str,
        session_id: str,
        expires_at: Optional[datetime] = None,
        renewed_date: Optional[str] = None,
    ) -> bool:
        """
        记录指定平台当前有效登录态；同平台新登录会覆盖旧 session。
        expires_at / renewed_date 为滑动续期字段（由 session_service 计算后传入）。
        """
        now = datetime.now(timezone.utc)
        session_doc: dict = {
            "session_id": session_id,
            "login_at": now,
        }
        if expires_at is not None:
            session_doc["expires_at"] = expires_at
        if renewed_date is not None:
            session_doc["renewed_date"] = renewed_date
        result = await self.col.update_one(
            {"email": email},
            {"$set": {
                f"active_sessions.{platform}": session_doc,
                "updated_at": now,
            }},
        )
        return result.modified_count > 0

    async def renew_active_session(
        self,
        email: str,
        platform: str,
        session_id: str,
        expires_at: datetime,
        renewed_date: str,
    ) -> bool:
        """
        滑动续期：仅当该平台当前活跃 session 仍是 session_id 时才更新
        （条件过滤防止旧 token 给重新登录后的新 session 续期）。
        """
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email, f"active_sessions.{platform}.session_id": session_id},
            {"$set": {
                f"active_sessions.{platform}.expires_at": expires_at,
                f"active_sessions.{platform}.renewed_date": renewed_date,
                "updated_at": now,
            }},
        )
        return result.modified_count > 0

    async def clear_active_session(self, email: str, platform: str) -> bool:
        """退出登录：移除该账号该平台的活跃 session（幂等，重复调用无副作用）。"""
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email},
            {
                "$unset": {f"active_sessions.{platform}": ""},
                "$set": {"updated_at": now},
            },
        )
        return result.modified_count > 0

    # ── 注册限制计数 ─────────────────────────────────────────

    async def count_by_device_id(self, device_id: str) -> int:
        """统计同设备 UUID 已注册账号数量。"""
        if not device_id:
            return 0
        return await self.col.count_documents({"reg_device_id": device_id})

    async def count_by_ip(self, ip: str) -> int:
        """统计同注册 IP 已注册账号数量。"""
        if not ip or ip in ("unknown", ""):
            return 0
        return await self.col.count_documents({"reg_ip": ip})

    async def count_by_hw_fingerprint(self, fingerprint: str) -> int:
        """统计同硬件指纹已注册账号数量。"""
        if not fingerprint:
            return 0
        return await self.col.count_documents({"reg_hw_fingerprint": fingerprint})

    # ── 关联账号查询（管理/运营用，返回明文信息） ────────────

    async def find_by_device_id(self, device_id: str) -> list[dict]:
        """按设备 UUID 查找所有关联账号（含明文注册信息）。"""
        cursor = self.col.find(
            {"reg_device_id": device_id},
            {"_id": 0, "hashed_password": 0},
        ).sort("created_at", 1)
        return await cursor.to_list(length=None)

    async def find_by_ip(self, ip: str) -> list[dict]:
        """按注册 IP 查找所有关联账号。"""
        cursor = self.col.find(
            {"reg_ip": ip},
            {"_id": 0, "hashed_password": 0},
        ).sort("created_at", 1)
        return await cursor.to_list(length=None)

    async def find_by_hw_fingerprint(self, fingerprint: str) -> list[dict]:
        """按硬件指纹查找所有关联账号。"""
        cursor = self.col.find(
            {"reg_hw_fingerprint": fingerprint},
            {"_id": 0, "hashed_password": 0},
        ).sort("created_at", 1)
        return await cursor.to_list(length=None)

    async def find_by_email_prefix(self, email_prefix: str) -> list[dict]:
        """按邮箱前缀模糊搜索（管理端排查用）。"""
        import re
        pattern = re.compile(re.escape(email_prefix), re.IGNORECASE)
        cursor = self.col.find(
            {"email": {"$regex": pattern}},
            {"_id": 0, "hashed_password": 0},
        ).sort("created_at", 1).limit(50)
        return await cursor.to_list(length=None)

    async def find_due_plan_users(self, now, limit: int = 200) -> list[dict]:
        cursor = self.col.find(
            {
                "is_active": True,
                "$or": [
                    {"plan_current_period_end": {"$lte": now}},
                    {"subscription_expires_at": {"$lte": now}},
                    {"pending_effective_at": {"$lte": now}},
                ],
            },
            {"hashed_password": 0},
        ).sort("plan_current_period_end", 1).limit(limit)
        return await cursor.to_list(length=limit)

    async def get_all_device_groups(self, min_count: int = 2, limit: int = 100) -> list[dict]:
        """
        聚合所有设备码下注册账号数 >= min_count 的分组（用于运营巡检）。
        返回格式：[{device_id, account_count, accounts: [...]}]
        """
        pipeline = [
            {"$match": {"reg_device_id": {"$nin": [None, ""]}}},
            {"$group": {
                "_id": "$reg_device_id",
                "account_count": {"$sum": 1},
                "accounts": {"$push": {
                    "email": "$email",
                    "tier": "$tier",
                    "reg_ip": "$reg_ip",
                    "reg_hw_fingerprint": "$reg_hw_fingerprint",
                    "invited_by": "$invited_by",
                    "created_at": "$created_at",
                    "is_active": "$is_active",
                }},
            }},
            {"$match": {"account_count": {"$gte": min_count}}},
            {"$sort": {"account_count": -1}},
            {"$limit": limit},
        ]
        cursor = self.col.aggregate(pipeline)
        results = await cursor.to_list(length=None)
        return [
            {
                "device_id": r["_id"],
                "account_count": r["account_count"],
                "accounts": r["accounts"],
            }
            for r in results
        ]

    # ── 系统配置 ─────────────────────────────────────────────

    async def get_max_accounts_per_device(self) -> int:
        """从系统配置中读取每设备最大注册账号数，默认 3。"""
        doc = await self.config_col.find_one({"key": "max_accounts_per_device"})
        if doc and isinstance(doc.get("value"), int):
            return doc["value"]
        return 3

    # ── 积分 / 套餐操作 ──────────────────────────────────────

    async def update_plan_fields(
        self,
        email: str,
        credits_total: int,
        credits_used: int,
        credits_reset_at,
    ) -> bool:
        """更新用户套餐积分字段（重置时调用）。"""
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email},
            {"$set": {
                "credits_total": credits_total,
                "credits_used": credits_used,
                "credits_reset_at": credits_reset_at,
                "plan_credits_total": credits_total,
                "plan_credits_used": credits_used,
                "plan_current_period_end": credits_reset_at,
                "updated_at": now,
            }},
        )
        return result.modified_count > 0

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

    async def update_subscription(self, email: str, fields: dict) -> bool:
        now = datetime.now(timezone.utc)
        set_fields = {**fields, "updated_at": now}
        plan_code = fields.get("subscription_plan_code") or fields.get("plan_code")
        if plan_code:
            set_fields["tier"] = plan_code
            set_fields["plan_code"] = plan_code
        result = await self.col.update_one({"email": email}, {"$set": set_fields})
        return result.modified_count > 0

    async def clear_pending_plan(self, email: str) -> bool:
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email},
            {"$set": {
                "pending_plan_code": None,
                "pending_effective_at": None,
                "pending_duration_count": None,
                "pending_duration_period": None,
                "pending_billing_cycle": None,
                "pending_requires_payment": None,
                "pending_payment_status": None,
                "pending_payment_due_at": None,
                "pending_payment_provider": None,
                "pending_schedule_event_id": None,
                "pending_from_plan_code": None,
                "pending_payment_charge_type": None,
                "pending_payment_amount_cents": None,
                "pending_payment_blocked_reason": None,
                "updated_at": now,
            }},
        )
        return result.modified_count > 0

    async def reset_plan_period(
        self,
        email: str,
        period_start,
        period_end,
        credits_total: int,
    ) -> bool:
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email},
            {"$set": {
                "plan_current_period_start": period_start,
                "plan_current_period_end": period_end,
                "plan_credits_total": credits_total,
                "plan_credits_used": 0,
                "credits_total": credits_total,
                "credits_used": 0,
                "credits_reset_at": period_end,
                "updated_at": now,
            }},
        )
        return result.modified_count > 0

    async def increment_plan_credits_used(self, email: str, amount: int) -> bool:
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email},
            {
                "$inc": {"plan_credits_used": amount, "credits_used": amount},
                "$set": {"updated_at": now},
            },
        )
        return result.modified_count > 0

    async def increment_credits_used(self, email: str, amount: int) -> bool:
        """增加用户已消耗积分（原子操作）。"""
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email},
            {"$inc": {"credits_used": amount}, "$set": {"updated_at": now}},
        )
        return result.modified_count > 0

    async def grant_credits(self, email: str, amount: int) -> bool:
        """赠送积分：增加 credits_total（原子操作）。"""
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email},
            {
                "$inc": {"credits_total": amount},
                "$set": {"updated_at": now},
            },
        )
        return result.modified_count > 0

    # ── 用户创建 / 删除 ──────────────────────────────────────

    async def create(
        self,
        email: str,
        hashed_password: str = "",
        reg_device_id: str = "",
        reg_ip: str = "",
        reg_hw_fingerprint: str = "",
        invited_by: str = "",
        used_invite_code: str = "",
    ) -> dict:
        """
        创建新用户，明文存储注册设备 ID、注册 IP、硬件指纹，便于后续运营排查关联。
        积分字段在注册后由 PlanService.init_user_plan() 单独初始化。
        """
        now = datetime.now(timezone.utc)
        doc = {
            "email": email,
            "hashed_password": hashed_password,
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

    async def delete_by_email(self, email: str) -> bool:
        """
        硬删除指定邮箱账号（解封操作入口）。
        同时会使该账号对应的设备码/IP 计数自动降低，从而解除封禁。
        返回是否实际删除了文档。
        """
        result = await self.col.delete_one({"email": email})
        return result.deleted_count > 0

    async def deactivate_by_email(self, email: str) -> bool:
        """
        软禁用账号（is_active=False），不删除注册记录，保留封禁计数。
        用于单账号封号但不释放设备名额。
        """
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {"email": email},
            {"$set": {"is_active": False, "updated_at": now}},
        )
        return result.modified_count > 0
