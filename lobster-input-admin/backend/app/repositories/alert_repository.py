from datetime import datetime, timezone
from typing import Optional
from bson import ObjectId
from motor.motor_asyncio import AsyncIOMotorDatabase


class AlertRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.col = db["alerts"]

    async def ensure_indexes(self) -> None:
        await self.col.create_index("status")
        await self.col.create_index([("created_at", -1)])

    async def create(self, source: str, level: str, title: str,
                     message: str, extra: Optional[dict] = None) -> str:
        doc = {
            "source": source,
            "level": level,
            "title": title,
            "message": message,
            "status": "pending",
            "extra": extra or {},
            "created_at": datetime.now(timezone.utc),
            "resolved_at": None,
            "resolve_note": None,
        }
        result = await self.col.insert_one(doc)
        return str(result.inserted_id)

    async def get_latest_pending(self) -> Optional[dict]:
        doc = await self.col.find_one(
            {"status": "pending"},
            sort=[("created_at", -1)],
        )
        return self._fmt(doc)

    async def list_alerts(self, status: Optional[str], page: int,
                          page_size: int) -> tuple[int, list]:
        filt = {}
        if status:
            filt["status"] = status
        skip = (page - 1) * page_size
        total = await self.col.count_documents(filt)
        cursor = self.col.find(filt).sort("created_at", -1).skip(skip).limit(page_size)
        items = [self._fmt(d) async for d in cursor]
        return total, items

    async def resolve(self, alert_id: str, note: Optional[str]) -> bool:
        try:
            oid = ObjectId(alert_id)
        except Exception:
            return False
        result = await self.col.update_one(
            {"_id": oid, "status": "pending"},
            {"$set": {
                "status": "resolved",
                "resolved_at": datetime.now(timezone.utc),
                "resolve_note": note or "",
            }},
        )
        return result.modified_count > 0

    @staticmethod
    def _fmt(doc: Optional[dict]) -> Optional[dict]:
        if not doc:
            return None
        doc["id"] = str(doc.pop("_id"))
        if doc.get("created_at"):
            doc["created_at"] = doc["created_at"].isoformat()
        if doc.get("resolved_at"):
            doc["resolved_at"] = doc["resolved_at"].isoformat()
        return doc
