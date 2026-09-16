"""Mongo persistence for realtime ASR sessions.

Only session lifecycle and final transcript are persisted. Realtime partials
stay in memory and are streamed to the client only.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from app.core.database import get_db

COLLECTION = "realtime_asr_sessions"
TTL_HOURS = 24


class RealtimeASRSessionRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def ensure_indexes(self) -> None:
        await self.col.create_index("asr_session_id", unique=True)
        await self.col.create_index([("user_email", 1), ("asr_session_id", 1)])
        await self.col.create_index([("status", 1), ("updated_at", -1)])
        await self.col.create_index("expires_at", expireAfterSeconds=0)

    async def create_streaming(
        self,
        *,
        asr_session_id: str,
        user_email: str,
        platform: str,
        language: str = "",
        audio_format: str = "pcm",
        sample_rate: int = 16000,
        max_duration_sec: int = 60,
    ) -> None:
        now = _now()
        existing = await self.col.find_one({"asr_session_id": asr_session_id})
        if existing and (
            existing.get("user_email") != user_email or existing.get("platform") != platform
        ):
            raise ValueError("ASR session id already belongs to another owner")
        await self.col.update_one(
            {"asr_session_id": asr_session_id},
            {
                "$set": {
                    "asr_session_id": asr_session_id,
                    "user_email": user_email,
                    "platform": platform,
                    "status": "streaming",
                    "language": language,
                    "audio_format": audio_format,
                    "sample_rate": sample_rate,
                    "max_duration_sec": max_duration_sec,
                    "final_text": "",
                    "duration_sec": None,
                    "bytes_received": 0,
                    "updated_at": now,
                    "expires_at": now + timedelta(hours=TTL_HOURS),
                },
                "$setOnInsert": {"started_at": now},
            },
            upsert=True,
        )

    async def complete(
        self,
        *,
        asr_session_id: str,
        user_email: str,
        platform: str,
        final_text: str,
        language: str = "",
        duration_sec: float = 0.0,
        bytes_received: int = 0,
    ) -> None:
        now = _now()
        await self.col.update_one(
            {
                "asr_session_id": asr_session_id,
                "user_email": user_email,
                "platform": platform,
            },
            {
                "$set": {
                    "status": "completed",
                    "final_text": final_text or "",
                    "language": language or "",
                    "duration_sec": duration_sec,
                    "bytes_received": bytes_received,
                    "finished_at": now,
                    "updated_at": now,
                    "expires_at": now + timedelta(hours=TTL_HOURS),
                }
            },
            upsert=False,
        )

    async def fail(
        self,
        *,
        asr_session_id: str,
        user_email: str,
        platform: str,
        error_message: str,
    ) -> None:
        now = _now()
        await self.col.update_one(
            {
                "asr_session_id": asr_session_id,
                "user_email": user_email,
                "platform": platform,
            },
            {
                "$set": {
                    "status": "failed",
                    "error_message": (error_message or "")[:500],
                    "finished_at": now,
                    "updated_at": now,
                    "expires_at": now + timedelta(hours=TTL_HOURS),
                }
            },
            upsert=False,
        )

    async def find_by_session_id(self, asr_session_id: str) -> Optional[dict[str, Any]]:
        if not asr_session_id:
            return None
        return await self.col.find_one({"asr_session_id": asr_session_id})

    async def find_for_owner(
        self,
        *,
        asr_session_id: str,
        user_email: str,
        platform: str,
    ) -> Optional[dict[str, Any]]:
        if not asr_session_id:
            return None
        return await self.col.find_one({
            "asr_session_id": asr_session_id,
            "user_email": user_email,
            "platform": platform,
        })


def _now() -> datetime:
    return datetime.now(timezone.utc)
