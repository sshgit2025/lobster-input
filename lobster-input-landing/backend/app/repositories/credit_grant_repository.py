"""CreditGrantRepository — 共享主库 credit_grants 集合（官网版）。

官网只需两类操作：
  1) 发放注册/邀请奖励积分（grant，含幂等键，与主后端 grant 一致）；
  2) 只读查询有效余额与明细（供个人中心展示）。

只读查询不触发主后端的订阅生命周期 refresh（那属于计费侧职责），官网不应
改动计费状态，只按"status=active 且未过期"口径展示，避免越权写库。
"""
from datetime import datetime, timezone
from typing import Optional

from pymongo import ASCENDING
from pymongo.errors import DuplicateKeyError
from app.core.database import get_db

COLLECTION = "credit_grants"
BONUS_CREDIT_TYPE = "bonus"
PAID_TOPUP_CREDIT_TYPE = "paid_topup"
CREDIT_STATUS_ACTIVE = "active"


class CreditGrantRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def grant(
        self,
        user_email: str,
        amount: int,
        source: str,
        expires_at: Optional[datetime] = None,
        metadata: Optional[dict] = None,
        credit_type: str = BONUS_CREDIT_TYPE,
        idempotency_key: str = "",
    ) -> bool:
        now = datetime.now(timezone.utc)
        metadata = dict(metadata or {})
        if idempotency_key:
            metadata["idempotency_key"] = idempotency_key
        try:
            await self.col.insert_one({
                "user_email": user_email,
                "source": source,
                "credit_type": credit_type,
                "status": CREDIT_STATUS_ACTIVE,
                "amount_total": amount,
                "amount_used": 0,
                "expires_at": expires_at,
                "metadata": metadata,
                "created_at": now,
                "updated_at": now,
            })
        except DuplicateKeyError:
            return False
        return True

    def _type_filter(self, credit_type: Optional[str]) -> dict:
        if credit_type == BONUS_CREDIT_TYPE:
            return {"$or": [{"credit_type": BONUS_CREDIT_TYPE}, {"credit_type": {"$exists": False}}]}
        if credit_type:
            return {"credit_type": credit_type}
        return {}

    def _available_query(self, user_email: str, now: datetime, credit_type: Optional[str] = None) -> dict:
        return {
            "user_email": user_email,
            "status": CREDIT_STATUS_ACTIVE,
            "$and": [
                self._type_filter(credit_type),
                {"$or": [{"expires_at": None}, {"expires_at": {"$gt": now}}]},
            ],
        }

    async def get_available_total(self, user_email: str, credit_type: Optional[str] = None) -> int:
        now = datetime.now(timezone.utc)
        pipeline = [
            {"$match": self._available_query(user_email, now, credit_type)},
            {"$project": {"remaining": {"$subtract": ["$amount_total", "$amount_used"]}}},
            {"$match": {"remaining": {"$gt": 0}}},
            {"$group": {"_id": None, "total": {"$sum": "$remaining"}}},
        ]
        result = await self.col.aggregate(pipeline).to_list(length=1)
        return int(result[0]["total"]) if result else 0

    async def list_active_grants(self, user_email: str) -> list[dict]:
        now = datetime.now(timezone.utc)
        cursor = self.col.find(
            self._available_query(user_email, now),
        ).sort([("expires_at", ASCENDING), ("created_at", ASCENDING)])
        grants = []
        for grant in await cursor.to_list(length=None):
            total = int(grant.get("amount_total", 0) or 0)
            used = int(grant.get("amount_used", 0) or 0)
            if max(0, total - used) <= 0:
                continue
            grants.append(grant)
        return grants
