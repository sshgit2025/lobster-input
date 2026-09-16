from datetime import datetime, timezone
from typing import Optional, List
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.services.subscription_lifecycle import (
    BONUS_CREDIT_TYPE,
    CREDIT_STATUS_ACTIVE,
    CreditGrantLifecycleCoordinator,
    PAID_TOPUP_CREDIT_TYPE,
)


class UserRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.col = db["users"]

    async def count(self, query: dict) -> int:
        return await self.col.count_documents(query)

    async def find_paginated(self, query: dict, page: int, page_size: int) -> List[dict]:
        skip = (page - 1) * page_size
        cursor = self.col.find(query, {"hashed_password": 0}).sort(
            "created_at", -1
        ).skip(skip).limit(page_size)
        return await cursor.to_list(length=page_size)

    async def find_by_email(self, email: str) -> Optional[dict]:
        return await self.col.find_one({"email": email})

    async def find_by_device_id(self, device_id: str) -> List[dict]:
        cursor = self.col.find({"reg_device_id": device_id}, {"hashed_password": 0})
        return await cursor.to_list(length=100)

    async def find_by_ip(self, ip: str) -> List[dict]:
        cursor = self.col.find({"reg_ip": ip}, {"hashed_password": 0})
        return await cursor.to_list(length=100)

    async def set_active(self, email: str, is_active: bool) -> bool:
        result = await self.col.update_one(
            {"email": email},
            {"$set": {"is_active": is_active, "updated_at": datetime.now(timezone.utc)}}
        )
        return result.matched_count > 0

    async def get_plan_distribution(self) -> List[dict]:
        pipeline = [
            {"$project": {"plan": {"$ifNull": ["$subscription_plan_code", "$plan_code"]}}},
            {"$group": {"_id": "$plan", "count": {"$sum": 1}}},
            {"$sort": {"count": -1}}
        ]
        return await self.col.aggregate(pipeline).to_list(length=50)

    async def get_daily_registrations(self, days: int = 30) -> List[dict]:
        pipeline = [
            {"$group": {
                "_id": {"$dateToString": {"format": "%Y-%m-%d", "date": "$created_at"}},
                "count": {"$sum": 1}
            }},
            {"$sort": {"_id": -1}},
            {"$limit": days}
        ]
        return await self.col.aggregate(pipeline).to_list(length=days)

    async def get_credits_info(self, email: str) -> Optional[dict]:
        """获取用户积分信息。"""
        await self.refresh_credit_grant_statuses(email)
        user = await self.col.find_one(
            {"email": email},
            {"credits_total": 1, "credits_used": 1, "credits_reset_at": 1,
             "plan_code": 1, "plan_credits_total": 1, "plan_credits_used": 1,
             "plan_current_period_end": 1, "plan_expires_at": 1,
             "subscription_plan_code": 1, "subscription_expires_at": 1,
             "pending_plan_code": 1, "pending_effective_at": 1,
             "_id": 0},
        )
        if user:
            bonus = await self.get_grant_remaining(email, BONUS_CREDIT_TYPE)
            paid_topup = await self.get_grant_remaining(email, PAID_TOPUP_CREDIT_TYPE)
            plan_total = user.get("plan_credits_total", user.get("credits_total", 0))
            plan_used = user.get("plan_credits_used", user.get("credits_used", 0))
            user["bonus_credits_remaining"] = bonus
            user["paid_topup_credits_remaining"] = paid_topup
            user["credits_total"] = plan_total + bonus + paid_topup
            user["credits_used"] = plan_used
            user["credits_reset_at"] = user.get("plan_current_period_end", user.get("credits_reset_at"))
            expires_at = user.get("subscription_expires_at") or user.get("plan_expires_at")
            if expires_at and user["credits_reset_at"] and expires_at <= user["credits_reset_at"]:
                user["credits_reset_note"] = "订阅到期前不再重置"
            user["plan_code"] = user.get("subscription_plan_code") or user.get("plan_code") or "none"
        return user

    async def get_bonus_remaining(self, email: str) -> int:
        return await self.get_grant_remaining(email, BONUS_CREDIT_TYPE)

    async def get_grant_remaining(self, email: str, credit_type: str) -> int:
        now = datetime.now(timezone.utc)
        await self.refresh_credit_grant_statuses(email)
        type_filter = {"credit_type": credit_type}
        if credit_type == BONUS_CREDIT_TYPE:
            type_filter = {"$or": [{"credit_type": BONUS_CREDIT_TYPE}, {"credit_type": {"$exists": False}}]}
        pipeline = [
            {"$match": {
                "user_email": email,
                "status": CREDIT_STATUS_ACTIVE,
                "$and": [
                    type_filter,
                    {"$or": [{"expires_at": None}, {"expires_at": {"$gt": now}}]},
                ],
            }},
            {"$project": {"remaining": {"$subtract": ["$amount_total", "$amount_used"]}}},
            {"$match": {"remaining": {"$gt": 0}}},
            {"$group": {"_id": None, "total": {"$sum": "$remaining"}}},
        ]
        data = await self.col.database["credit_grants"].aggregate(pipeline).to_list(length=1)
        return int(data[0]["total"]) if data else 0

    async def list_active_credit_grants(self, email: str) -> list[dict]:
        now = datetime.now(timezone.utc)
        await self.refresh_credit_grant_statuses(email)
        cursor = self.col.database["credit_grants"].find(
            {
                "user_email": email,
                "status": CREDIT_STATUS_ACTIVE,
                "$or": [{"expires_at": None}, {"expires_at": {"$gt": now}}],
            },
            {"_id": 0},
        ).sort([("expires_at", 1), ("created_at", 1)])
        rows = []
        for grant in await cursor.to_list(length=200):
            total = int(grant.get("amount_total", 0) or 0)
            used = int(grant.get("amount_used", 0) or 0)
            remaining = max(0, total - used)
            if remaining <= 0:
                continue
            grant["amount_total"] = total
            grant["amount_used"] = used
            grant["amount_remaining"] = remaining
            grant["credit_type"] = grant.get("credit_type") or BONUS_CREDIT_TYPE
            rows.append(grant)
        return rows

    async def refresh_credit_grant_statuses(self, email: str) -> int:
        now = datetime.now(timezone.utc)
        return await CreditGrantLifecycleCoordinator(self.col.database).refresh_for_user(email, now)

    async def grant_credits(
        self,
        email: str,
        amount: int,
        expires_at: datetime,
        metadata: Optional[dict] = None,
    ) -> bool:
        """赠送 bonus 积分批次，不影响套餐积分。"""
        user = await self.find_by_email(email)
        if not user:
            return False
        now = datetime.now(timezone.utc)
        await self.col.database["credit_grants"].insert_one({
            "user_email": email,
            "source": "admin_grant",
            "credit_type": BONUS_CREDIT_TYPE,
            "status": CREDIT_STATUS_ACTIVE,
            "amount_total": amount,
            "amount_used": 0,
            "expires_at": expires_at,
            "metadata": metadata or {},
            "created_at": now,
            "updated_at": now,
        })
        return True
