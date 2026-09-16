from datetime import datetime, timezone
from typing import Optional

from bson import ObjectId
from motor.motor_asyncio import AsyncIOMotorDatabase


class SecurityRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.identities_col = db["security_identities"]
        self.events_col = db["security_events"]
        self.counters_col = db["security_counters"]

    async def ensure_indexes(self) -> None:
        await self.identities_col.create_index(
            [("identity_type", 1), ("identity_value", 1)],
            unique=True,
        )
        await self.identities_col.create_index("status")
        await self.identities_col.create_index("user_email")
        await self.identities_col.create_index([("last_seen_at", -1)])
        await self.events_col.create_index([("created_at", -1)])
        await self.events_col.create_index("user_email")
        await self.events_col.create_index("ip")
        await self.events_col.create_index("reason_code")
        await self.events_col.create_index("action")
        await self.counters_col.create_index(
            [("scope", 1), ("key", 1), ("path_group", 1), ("bucket", 1)],
            unique=True,
        )
        await self.counters_col.create_index("expires_at", expireAfterSeconds=0)

    async def list_identities(
        self,
        *,
        status: Optional[str],
        email: Optional[str],
        ip: Optional[str],
        reason: Optional[str],
        page: int,
        page_size: int,
    ) -> tuple[int, list[dict]]:
        q: dict = {}
        if status == "active":
            q["status"] = {"$in": ["limited", "blocked"]}
        elif status:
            q["status"] = status
        if email:
            q["$or"] = [
                {"user_email": {"$regex": email, "$options": "i"}},
                {"user_emails": {"$elemMatch": {"$regex": email, "$options": "i"}}},
            ]
        if ip:
            q["ips"] = ip
        if reason:
            q["reasons"] = reason
        skip = (page - 1) * page_size
        total = await self.identities_col.count_documents(q)
        cursor = (
            self.identities_col.find(q)
            .sort("last_seen_at", -1)
            .skip(skip)
            .limit(page_size)
        )
        return total, [self._fmt(d) async for d in cursor]

    async def get_identity_detail(self, identity_id: str) -> Optional[dict]:
        try:
            oid = ObjectId(identity_id)
        except Exception:
            return None
        doc = await self.identities_col.find_one({"_id": oid})
        if not doc:
            return None
        item = self._fmt(doc)
        event_query: dict = {"$or": []}
        if item.get("identity_type") == "account":
            event_query["$or"].append({"user_email": item.get("identity_value")})
        if item.get("identity_type") == "ip":
            event_query["$or"].append({"ip": item.get("identity_value")})
        for ip in item.get("ips") or []:
            event_query["$or"].append({"ip": ip})
        for email in item.get("user_emails") or []:
            event_query["$or"].append({"user_email": email})
        if not event_query["$or"]:
            event_query = {"_id": None}
        cursor = self.events_col.find(event_query).sort("created_at", -1).limit(50)
        item["events"] = [self._fmt(d) async for d in cursor]
        return item

    async def list_events(
        self,
        *,
        email: Optional[str],
        ip: Optional[str],
        reason: Optional[str],
        action: Optional[str],
        page: int,
        page_size: int,
    ) -> tuple[int, list[dict]]:
        q: dict = {}
        if email:
            q["user_email"] = {"$regex": email, "$options": "i"}
        if ip:
            q["ip"] = ip
        if reason:
            q["reason_code"] = reason
        if action:
            q["action"] = action
        skip = (page - 1) * page_size
        total = await self.events_col.count_documents(q)
        cursor = (
            self.events_col.find(q)
            .sort("created_at", -1)
            .skip(skip)
            .limit(page_size)
        )
        return total, [self._fmt(d) async for d in cursor]

    async def clear_identity(self, identity_id: str) -> bool:
        try:
            oid = ObjectId(identity_id)
        except Exception:
            return False
        now = datetime.now(timezone.utc)
        result = await self.identities_col.update_one(
            {"_id": oid},
            {"$set": {
                "status": "normal",
                "risk_score": 0,
                "limited_until": None,
                "blocked_until": None,
                "last_action": "manual_clear",
                "cleared_at": now,
            }, "$unset": {"last_reason": ""}},
        )
        return result.modified_count > 0

    @staticmethod
    def _fmt(doc: dict) -> dict:
        doc["id"] = str(doc.pop("_id"))
        for key in ("created_at", "first_seen_at", "last_seen_at",
                    "limited_until", "blocked_until", "cleared_at"):
            if doc.get(key):
                doc[key] = doc[key].isoformat()
        return doc
