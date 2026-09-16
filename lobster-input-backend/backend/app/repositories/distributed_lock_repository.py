"""Small Mongo-backed distributed lock for short critical sections."""
from __future__ import annotations

import asyncio
import secrets
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

from pymongo import ReturnDocument
from pymongo.errors import DuplicateKeyError

from app.core.database import get_db

COLLECTION = "distributed_locks"


class DistributedLockRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def ensure_indexes(self) -> None:
        await self.col.create_index("expires_at", expireAfterSeconds=0)

    @asynccontextmanager
    async def lock(self, key: str, ttl_seconds: int = 15, wait_seconds: float = 5.0):
        owner = secrets.token_urlsafe(16)
        deadline = asyncio.get_running_loop().time() + wait_seconds
        acquired = False
        try:
            while True:
                now = datetime.now(timezone.utc)
                try:
                    doc = await self.col.find_one_and_update(
                        {
                            "_id": key,
                            "$or": [
                                {"owner": owner},
                                {"expires_at": {"$lte": now}},
                                {"expires_at": {"$exists": False}},
                            ],
                        },
                        {
                            "$set": {
                                "owner": owner,
                                "expires_at": now + timedelta(seconds=ttl_seconds),
                                "updated_at": now,
                            },
                            "$setOnInsert": {"created_at": now},
                        },
                        upsert=True,
                        return_document=ReturnDocument.AFTER,
                    )
                except DuplicateKeyError:
                    doc = None
                if doc and doc.get("owner") == owner:
                    acquired = True
                    break
                if asyncio.get_running_loop().time() >= deadline:
                    raise TimeoutError(f"Could not acquire lock: {key}")
                await asyncio.sleep(0.05)
            yield
        finally:
            if acquired:
                await self.col.delete_one({"_id": key, "owner": owner})
