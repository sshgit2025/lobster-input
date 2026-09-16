"""CreditGrantRepository — 非套餐积分批次。"""
from datetime import datetime, timezone
from typing import Optional

from bson import ObjectId
from pymongo import ASCENDING
from pymongo.errors import DuplicateKeyError

from app.core.database import get_db
from app.services.billing.subscription_lifecycle import (
    BONUS_CREDIT_TYPE,
    CREDIT_STATUS_ACTIVE,
    CREDIT_STATUS_EXPIRED,
    CreditGrantLifecycleCoordinator,
    EXPIRE_REASON_EXPIRES_AT,
    EXPIRE_REASON_SUBSCRIPTION_TO_FREE,
    PAID_TOPUP_CREDIT_TYPE,
    SUBSCRIPTION_EXPIRES_MODE,
    as_utc,
)

COLLECTION = "credit_grants"


class CreditGrantRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def ensure_indexes(self) -> None:
        await self.col.create_index([("user_email", ASCENDING), ("expires_at", ASCENDING)])
        await self.col.create_index([("user_email", ASCENDING), ("credit_type", ASCENDING), ("expires_at", ASCENDING)])
        await self.col.create_index([("user_email", ASCENDING), ("credit_type", ASCENDING), ("status", ASCENDING)])
        await self.col.create_index([("user_email", ASCENDING), ("metadata.expires_at_mode", ASCENDING), ("status", ASCENDING)])
        await self.col.create_index(
            [("metadata.idempotency_key", ASCENDING)],
            unique=True,
            partialFilterExpression={"metadata.idempotency_key": {"$exists": True, "$gt": ""}},
        )
        await self.col.create_index("source")

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

    async def get_available_total(
        self,
        user_email: str,
        now: Optional[datetime] = None,
        credit_type: Optional[str] = None,
    ) -> int:
        now = now or datetime.now(timezone.utc)
        await self.refresh_statuses(user_email, now)
        match = self._available_query(user_email, now, credit_type)
        pipeline = [
            {"$match": match},
            {"$project": {"remaining": {"$subtract": ["$amount_total", "$amount_used"]}}},
            {"$match": {"remaining": {"$gt": 0}}},
            {"$group": {"_id": None, "total": {"$sum": "$remaining"}}},
        ]
        result = await self.col.aggregate(pipeline).to_list(length=1)
        return int(result[0]["total"]) if result else 0

    async def list_active_grants(self, user_email: str) -> list[dict]:
        now = datetime.now(timezone.utc)
        await self.refresh_statuses(user_email, now)
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

    async def refresh_statuses(self, user_email: str, now: Optional[datetime] = None) -> int:
        now = now or datetime.now(timezone.utc)
        async def load_user() -> dict | None:
            return await self.col.database["users"].find_one(
                {"email": user_email},
                {"_id": 0, "subscription_plan_code": 1, "plan_code": 1, "tier": 1, "subscription_expires_at": 1, "plan_expires_at": 1},
            )

        return await CreditGrantLifecycleCoordinator(self).refresh_for_user(user_email, load_user, now)

    async def expire_standalone_grants(self, user_email: str, now: Optional[datetime] = None) -> int:
        now = now or datetime.now(timezone.utc)
        result = await self.col.update_many(
            {
                "user_email": user_email,
                "status": CREDIT_STATUS_ACTIVE,
                "expires_at": {"$ne": None, "$lte": now},
                "$or": [
                    {"metadata.expires_at_mode": {"$exists": False}},
                    {"metadata.expires_at_mode": {"$ne": SUBSCRIPTION_EXPIRES_MODE}},
                ],
            },
            {"$set": {"status": CREDIT_STATUS_EXPIRED, "expired_reason": EXPIRE_REASON_EXPIRES_AT, "updated_at": now}},
        )
        return result.modified_count

    async def sync_subscription_linked_grants(
        self,
        user_email: str,
        expires_at: datetime,
        plan_code: str,
        now: Optional[datetime] = None,
    ) -> int:
        now = now or datetime.now(timezone.utc)
        expires_at = as_utc(expires_at)
        result = await self.col.update_many(
            {
                "user_email": user_email,
                "status": CREDIT_STATUS_ACTIVE,
                "metadata.expires_at_mode": SUBSCRIPTION_EXPIRES_MODE,
            },
            {"$set": {
                "expires_at": expires_at,
                "metadata.subscription_plan_code": plan_code,
                "metadata.subscription_expires_at": expires_at,
                "updated_at": now,
            }},
        )
        return result.modified_count

    async def expire_subscription_linked_grants(self, user_email: str, now: Optional[datetime] = None) -> int:
        now = now or datetime.now(timezone.utc)
        result = await self.col.update_many(
            {
                "user_email": user_email,
                "status": CREDIT_STATUS_ACTIVE,
                "metadata.expires_at_mode": SUBSCRIPTION_EXPIRES_MODE,
            },
            {"$set": {
                "status": CREDIT_STATUS_EXPIRED,
                "expires_at": now,
                "expired_reason": EXPIRE_REASON_SUBSCRIPTION_TO_FREE,
                "updated_at": now,
            }},
        )
        return result.modified_count

    async def deduct(
        self,
        user_email: str,
        amount: int,
        now: Optional[datetime] = None,
        credit_type: Optional[str] = None,
    ) -> list[dict]:
        now = now or datetime.now(timezone.utc)
        await self.refresh_statuses(user_email, now)
        remaining = amount
        rows = []
        query = self._available_query(user_email, now, credit_type)
        cursor = self.col.find(query).sort([("expires_at", ASCENDING), ("created_at", ASCENDING)])
        for grant in await cursor.to_list(length=None):
            available = int(grant.get("amount_total", 0)) - int(grant.get("amount_used", 0))
            if available <= 0:
                continue
            used = min(remaining, available)
            await self.col.update_one(
                {"_id": grant["_id"]},
                {"$inc": {"amount_used": used}, "$set": {"updated_at": now}},
            )
            rows.append({
                "grant_id": str(grant["_id"]),
                "source": grant.get("source", ""),
                "credit_type": grant.get("credit_type", BONUS_CREDIT_TYPE),
                "credits": used,
                "expires_at": grant.get("expires_at"),
            })
            remaining -= used
            if remaining <= 0:
                break
        return rows

    async def refund(self, grant_id: str, amount: int) -> bool:
        amount = max(0, int(amount or 0))
        if amount <= 0:
            return True
        now = datetime.now(timezone.utc)
        result = await self.col.update_one(
            {
                "_id": ObjectId(grant_id),
                "amount_used": {"$gte": amount},
            },
            {
                "$inc": {"amount_used": -amount},
                "$set": {"updated_at": now},
            },
        )
        return result.modified_count > 0

    async def expire_paid_topups(self, user_email: str, now: Optional[datetime] = None) -> int:
        now = now or datetime.now(timezone.utc)
        result = await self.col.update_many(
            {
                "user_email": user_email,
                "credit_type": PAID_TOPUP_CREDIT_TYPE,
                "status": CREDIT_STATUS_ACTIVE,
                "$expr": {"$lt": ["$amount_used", "$amount_total"]},
            },
            {"$set": {
                "status": CREDIT_STATUS_EXPIRED,
                "expires_at": now,
                "expired_reason": EXPIRE_REASON_SUBSCRIPTION_TO_FREE,
                "updated_at": now,
            }},
        )
        return result.modified_count

    async def extend_paid_topups(self, user_email: str, expires_at: datetime) -> int:
        now = datetime.now(timezone.utc)
        result = await self.col.update_many(
            {
                "user_email": user_email,
                "credit_type": PAID_TOPUP_CREDIT_TYPE,
                "status": CREDIT_STATUS_ACTIVE,
                "$expr": {"$lt": ["$amount_used", "$amount_total"]},
            },
            {"$set": {"expires_at": expires_at, "updated_at": now}},
        )
        return result.modified_count
