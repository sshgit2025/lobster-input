#!/usr/bin/env python3
"""Seed the realtime ASR pool by copying an existing DashScope/Qwen key.

Run on the business server after deploying api-manage:
  cd /opt/lobster-api-pool && venv/bin/python scripts/seed_realtime_asr_key.py
"""
from __future__ import annotations

import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.core.database import close_db, connect_db, get_db  # noqa: E402
from app.models.api_key import KeyStatus  # noqa: E402
from app.repositories.api_key_repository import ApiKeyRepository  # noqa: E402

TARGET_GROUP_ID = "asr_realtime_dashscope_realtime_default"
TARGET_PLATFORM_CODE = "dashscope_realtime"
TARGET_CATEGORY = "asr_realtime"
TARGET_BASE_URL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
TARGET_MODEL = "qwen3-asr-flash-realtime"

SOURCE_GROUPS = [
    "llm_chat_aliyun_default",
    "asr_dashscope_default",
]


async def main() -> int:
    await connect_db()
    try:
        db = get_db()
        repo = ApiKeyRepository(db)
        await repo.ensure_default_catalog()

        existing = await db["api_keys"].find_one({
            "group_id": TARGET_GROUP_ID,
            "status": {"$ne": KeyStatus.disabled.value},
        })
        if existing:
            print(f"realtime ASR key already exists: {existing.get('name') or existing.get('_id')}")
            return 0

        source = None
        for group_id in SOURCE_GROUPS:
            source = await db["api_keys"].find_one({
                "group_id": group_id,
                "status": {"$in": [KeyStatus.active.value, KeyStatus.cooldown.value]},
                "api_key": {"$ne": ""},
            })
            if source:
                break
        if not source:
            print("no source key found in llm_chat_aliyun_default or asr_dashscope_default", file=sys.stderr)
            return 2

        source_is_realtime = source.get("platform_code") == TARGET_PLATFORM_CODE
        now = datetime.now(timezone.utc)
        doc = {
            "group_id": TARGET_GROUP_ID,
            "platform_code": TARGET_PLATFORM_CODE,
            "category": TARGET_CATEGORY,
            "api_key": source.get("api_key", ""),
            "name": "Qwen realtime ASR copied from " + str(source.get("group_id") or "qwen"),
            "description": "Seeded automatically for v2 realtime ASR.",
            "status": KeyStatus.active.value,
            "status_reason": "",
            "status_updated_at": now,
            "token_quota": source.get("token_quota") or {"enabled": False, "total": 0, "used": 0, "auto_reset_period": "none"},
            "seconds_quota": source.get("seconds_quota") or {"enabled": False, "total": 0, "used": 0, "auto_reset_period": "none"},
            "requests_quota": source.get("requests_quota") or {"enabled": False, "total": 0, "used": 0, "auto_reset_period": "none"},
            "weight": int(source.get("weight", 10) or 10),
            "priority": int(source.get("priority", 0) or 0),
            "base_url": (source.get("base_url") if source_is_realtime else "") or TARGET_BASE_URL,
            "model": (source.get("model") if source_is_realtime else "") or TARGET_MODEL,
            "extra_config": source.get("extra_config") or {},
            "proxy_config": source.get("proxy_config") or {"enabled": False, "proxy_url": "", "username": "", "password": ""},
            "cooldown_until": None,
            "cooldown_seconds": int(source.get("cooldown_seconds", 60) or 60),
            "expires_at": source.get("expires_at"),
            "error_count": 0,
            "error_threshold": max(30, int(source.get("error_threshold", 30) or 30)),
            "last_error_at": None,
            "last_used_at": None,
            "total_requests": 0,
            "created_at": now,
            "updated_at": now,
        }
        await db["api_keys"].insert_one(doc)
        print(f"created realtime ASR key in {TARGET_GROUP_ID} from {source.get('group_id')}")
        return 0
    finally:
        await close_db()


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
