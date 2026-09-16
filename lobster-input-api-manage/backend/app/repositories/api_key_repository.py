"""
API Key 号池数据访问层。

职责边界：
  - 号池端维护平台目录、Key 分组和真实 Key。
  - 管理端只挂载 group_id，不管理多 Key 负载均衡细节。
  - 后端运行时只按 group_id pick，号池在组内按状态/额度/优先级/权重选 Key。
"""
import logging
import random
from datetime import datetime, timedelta, timezone
from typing import Optional, List

from bson import ObjectId
from motor.motor_asyncio import AsyncIOMotorDatabase
from pymongo import ReturnDocument

from app.models.api_key import KeyStatus

logger = logging.getLogger(__name__)

KEY_COLLECTION = "api_keys"
PLATFORM_COLLECTION = "api_platforms"
GROUP_COLLECTION = "api_key_groups"
USAGE_COLLECTION = "usage_records"

ERROR_WINDOW_SECONDS = 60
MIN_ERROR_THRESHOLD = 30
VALID_KEY_STATUSES = {status.value for status in KeyStatus}

DEFAULT_PLATFORMS = [
    {
        "code": "dashscope",
        "category": "asr",
        "name": "DashScope ASR",
        "default_base_url": "https://dashscope.aliyuncs.com/api/v1",
        "default_model": "qwen3-asr-flash",
    },
    {
        "code": "groq",
        "category": "asr",
        "name": "Groq Whisper",
        "default_base_url": "https://api.groq.com/openai/v1",
        "default_model": "whisper-large-v3",
    },
    {
        "code": "openai",
        "category": "asr",
        "name": "OpenAI Whisper",
        "default_base_url": "https://api.openai.com/v1",
        "default_model": "whisper-1",
    },
    {
        "code": "volcengine",
        "category": "asr",
        "name": "Volcengine Seed-ASR 2.0",
        "default_base_url": "https://openspeech.bytedance.com",
        "default_model": "volc.seedasr.auc",
    },
    {
        "code": "dashscope_realtime",
        "category": "asr_realtime",
        "name": "DashScope Qwen Realtime ASR",
        "default_base_url": "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
        "default_model": "qwen3-asr-flash-realtime",
    },
    {
        "code": "volcengine_realtime",
        "category": "asr_realtime",
        "name": "Volcengine Seed-ASR Realtime",
        "default_base_url": "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async",
        "default_model": "volc.seedasr.sauc.duration",
    },
    {
        "code": "aliyun",
        "category": "llm_chat",
        "name": "Aliyun DashScope Chat",
        "default_base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "default_model": "qwen-plus",
    },
    {
        "code": "openai",
        "category": "llm_chat",
        "name": "OpenAI Chat",
        "default_base_url": "https://api.openai.com/v1",
        "default_model": "gpt-4o",
    },
    {
        "code": "deepseek",
        "category": "llm_chat",
        "name": "DeepSeek Chat",
        "default_base_url": "https://api.deepseek.com/v1",
        "default_model": "deepseek-chat",
    },
    {
        "code": "groq",
        "category": "llm_chat",
        "name": "Groq Chat",
        "default_base_url": "https://api.groq.com/openai/v1",
        "default_model": "llama-3.3-70b-versatile",
    },
    {
        "code": "aliyun_search",
        "category": "web_search",
        "name": "Aliyun Qwen Web Search",
        "default_base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "default_model": "qwen-plus",
    },
    {
        "code": "tavily",
        "category": "web_search",
        "name": "Tavily Search",
        "default_base_url": "",
        "default_model": "",
    },
    {
        "code": "aliyun_embedding",
        "category": "embedding",
        "name": "Aliyun Embedding",
        "default_base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "default_model": "text-embedding-v4",
    },
]


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _normalize_code(value: str) -> str:
    return str(value or "").strip().lower().replace(" ", "_")


def _normalize_status(value: str) -> str:
    status = _normalize_code(value)
    if status and status not in VALID_KEY_STATUSES:
        raise ValueError(f"invalid key status: {value}")
    return status


def _default_group_id(category: str, platform_code: str) -> str:
    return f"{category}_{platform_code}_default".replace("__", "_")


class ApiKeyRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self._keys = db[KEY_COLLECTION]
        self._platforms = db[PLATFORM_COLLECTION]
        self._groups = db[GROUP_COLLECTION]
        self._usage = db[USAGE_COLLECTION]

    async def ensure_indexes(self, seed_default_catalog: bool = False):
        await self._platforms.create_index([("category", 1), ("code", 1)], unique=True)
        await self._platforms.create_index("enabled")
        await self._groups.create_index("group_id", unique=True)
        await self._groups.create_index([("category", 1), ("platform_code", 1)])
        await self._groups.create_index("enabled")
        await self._keys.create_index("group_id")
        await self._keys.create_index([("group_id", 1), ("status", 1)])
        await self._keys.create_index([("category", 1), ("status", 1)])
        await self._keys.create_index([("category", 1), ("platform_code", 1)])
        await self._keys.create_index("status")
        await self._usage.create_index([("api_key_id", 1), ("created_at", -1)])
        await self._usage.create_index([("group_id", 1), ("created_at", -1)])
        await self._usage.create_index([("category", 1), ("created_at", -1)])
        await self._usage.create_index("created_at")
        if seed_default_catalog:
            await self.ensure_default_catalog()

    async def ensure_default_catalog(self) -> None:
        now = _now()
        for item in DEFAULT_PLATFORMS:
            row = {
                "code": _normalize_code(item["code"]),
                "category": _normalize_code(item["category"]),
                "name": item.get("name") or item["code"],
                "description": item.get("description", ""),
                "default_base_url": item.get("default_base_url", ""),
                "default_model": item.get("default_model", ""),
                "default_extra_config": item.get("default_extra_config", {}),
                "enabled": item.get("enabled", True),
            }
            await self._platforms.update_one(
                {"code": row["code"], "category": row["category"]},
                {"$setOnInsert": {**row, "created_at": now}, "$set": {"updated_at": now}},
                upsert=True,
            )
            group_id = _default_group_id(row["category"], row["code"])
            await self._groups.update_one(
                {"group_id": group_id},
                {
                    "$setOnInsert": {
                        "group_id": group_id,
                        "platform_code": row["code"],
                        "category": row["category"],
                        "name": f"{row['name']} 默认分组",
                        "description": "默认负载均衡分组",
                        "enabled": True,
                        "created_at": now,
                    },
                    "$set": {"updated_at": now},
                },
                upsert=True,
            )

    # ── 平台与分组 ──────────────────────────────────────────

    async def upsert_platform(self, data: dict) -> str:
        now = _now()
        code = _normalize_code(data.get("code"))
        category = _normalize_code(data.get("category"))
        if not code or not category:
            raise ValueError("platform code and category are required")
        row = {
            "code": code,
            "category": category,
            "name": data.get("name") or code,
            "description": data.get("description", ""),
            "default_base_url": data.get("default_base_url", ""),
            "default_model": data.get("default_model", ""),
            "default_extra_config": data.get("default_extra_config") or {},
            "enabled": bool(data.get("enabled", True)),
            "updated_at": now,
        }
        await self._platforms.update_one(
            {"code": code, "category": category},
            {"$set": row, "$setOnInsert": {"created_at": now}},
            upsert=True,
        )
        return code

    async def list_platform_records(self, category: str = "") -> list[dict]:
        query = {}
        if category:
            query["category"] = _normalize_code(category)
        cursor = self._platforms.find(query).sort([("category", 1), ("code", 1)])
        return [self._strip_id(doc) async for doc in cursor]

    async def upsert_group(self, data: dict) -> str:
        now = _now()
        group_id = _normalize_code(data.get("group_id"))
        platform_code = _normalize_code(data.get("platform_code"))
        category = _normalize_code(data.get("category"))
        if not group_id or not platform_code or not category:
            raise ValueError("group_id, platform_code and category are required")
        platform = await self._platforms.find_one({"code": platform_code, "category": category})
        if not platform:
            raise ValueError(f"platform not found: {category}/{platform_code}")
        row = {
            "group_id": group_id,
            "platform_code": platform_code,
            "category": category,
            "name": data.get("name") or group_id,
            "description": data.get("description", ""),
            "enabled": bool(data.get("enabled", True)),
            "updated_at": now,
        }
        await self._groups.update_one(
            {"group_id": group_id},
            {"$set": row, "$setOnInsert": {"created_at": now}},
            upsert=True,
        )
        return group_id

    async def list_group_records(self, category: str = "", platform_code: str = "") -> list[dict]:
        query = {}
        if category:
            query["category"] = _normalize_code(category)
        if platform_code:
            query["platform_code"] = _normalize_code(platform_code)
        await self.refresh_runtime_statuses(category, platform_code)
        cursor = self._groups.find(query).sort([("category", 1), ("platform_code", 1), ("group_id", 1)])
        groups = []
        async for doc in cursor:
            row = self._strip_id(doc)
            row["active_key_count"] = await self._keys.count_documents({
                "group_id": row["group_id"],
                "status": KeyStatus.active.value,
            })
            row["total_key_count"] = await self._keys.count_documents({"group_id": row["group_id"]})
            groups.append(row)
        return groups

    async def get_group(self, group_id: str) -> Optional[dict]:
        doc = await self._groups.find_one({"group_id": _normalize_code(group_id)})
        return self._strip_id(doc) if doc else None

    # ── Key CRUD ─────────────────────────────────────────────

    async def create(self, data: dict) -> str:
        now = _now()
        data = await self._clean_key_payload(data)
        data.setdefault("status", KeyStatus.active.value)
        data.setdefault("error_count", 0)
        data.setdefault("total_requests", 0)
        data.setdefault("last_used_at", None)
        data.setdefault("last_error_at", None)
        data["created_at"] = now
        data["updated_at"] = now
        data.setdefault("status_updated_at", now)
        result = await self._keys.insert_one(data)
        return str(result.inserted_id)

    async def get_by_id(self, key_id: str) -> Optional[dict]:
        doc = await self._keys.find_one({"_id": ObjectId(key_id)})
        if not doc:
            return None
        return await self._enrich_key(self._strip_id(doc))

    async def update(self, key_id: str, data: dict) -> bool:
        data = await self._clean_key_payload(data, partial=True)
        if not data:
            return False
        data["updated_at"] = _now()
        result = await self._keys.update_one({"_id": ObjectId(key_id)}, {"$set": data})
        return result.modified_count > 0

    async def delete(self, key_id: str) -> bool:
        result = await self._keys.delete_one({"_id": ObjectId(key_id)})
        return result.deleted_count > 0

    async def _clean_key_payload(self, data: dict, partial: bool = False) -> dict:
        row = dict(data or {})
        if "group_id" in row:
            row["group_id"] = _normalize_code(row["group_id"])
        if not partial and not row.get("group_id"):
            raise ValueError("group_id is required")
        if row.get("group_id"):
            group = await self.get_group(row["group_id"])
            if not group or not group.get("enabled", True):
                raise ValueError(f"group not found or disabled: {row['group_id']}")
            row["category"] = group["category"]
            row["platform_code"] = group["platform_code"]
        return row

    async def list_keys(
        self,
        category: str = "",
        platform_code: str = "",
        group_id: str = "",
        status: str = "",
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[dict], int]:
        status = _normalize_status(status)
        await self.refresh_runtime_statuses(category, platform_code, group_id)
        query = {}
        if category:
            query["category"] = _normalize_code(category)
        if platform_code:
            query["platform_code"] = _normalize_code(platform_code)
        if group_id:
            query["group_id"] = _normalize_code(group_id)
        if status:
            query["status"] = status
        total = await self._keys.count_documents(query)
        cursor = (
            self._keys.find(query)
            .sort([("priority", 1), ("created_at", -1)])
            .skip((page - 1) * page_size)
            .limit(page_size)
        )
        items = []
        async for doc in cursor:
            items.append(await self._enrich_key(self._strip_id(doc)))
        return items, total

    async def refresh_runtime_statuses(
        self,
        category: str = "",
        platform_code: str = "",
        group_id: str = "",
    ) -> int:
        """Refresh derived key statuses before management list/count queries."""
        now = _now()
        group_ids = await self._resolve_group_ids(category, platform_code, group_id)
        has_scope = bool(_normalize_code(category) or _normalize_code(platform_code) or _normalize_code(group_id))
        if has_scope and not group_ids:
            return 0
        changed = 0
        for gid in group_ids:
            before = now
            await self._auto_recover_cooldown(gid, before)
            await self._auto_expire_keys(gid, before)
        changed += await self._mark_exhausted_keys(group_ids, now)
        return changed

    async def _resolve_group_ids(self, category: str = "", platform_code: str = "", group_id: str = "") -> list[str]:
        query = {}
        if group_id:
            query["group_id"] = _normalize_code(group_id)
        if category:
            query["category"] = _normalize_code(category)
        if platform_code:
            query["platform_code"] = _normalize_code(platform_code)
        cursor = self._groups.find(query, {"group_id": 1})
        return [doc["group_id"] async for doc in cursor if doc.get("group_id")]

    async def _mark_exhausted_keys(self, group_ids: list[str], now: datetime) -> int:
        query = {"status": KeyStatus.active.value}
        if group_ids:
            query["group_id"] = {"$in": group_ids}
        changed = 0
        async for doc in self._keys.find(query):
            if self._has_available_quota(doc):
                continue
            result = await self._keys.update_one(
                {"_id": doc["_id"], "status": KeyStatus.active.value},
                {"$set": {
                    "status": KeyStatus.exhausted.value,
                    "status_reason": "额度耗尽",
                    "status_updated_at": now,
                    "updated_at": now,
                }},
            )
            changed += result.modified_count
        return changed

    # ── Pick 与负载均衡 ──────────────────────────────────────

    async def pick_key(self, group_id: str) -> Optional[dict]:
        group_id = _normalize_code(group_id)
        now = _now()
        group = await self._groups.find_one({"group_id": group_id, "enabled": True})
        if not group:
            return None
        await self._auto_recover_cooldown(group_id, now)
        await self._auto_expire_keys(group_id, now)
        base_query = {
            "group_id": group_id,
            "status": KeyStatus.active.value,
            "weight": {"$gt": 0},
        }
        candidates_by_priority: dict[int, list] = {}
        async for doc in self._keys.find(base_query).sort("priority", 1):
            doc = self._strip_id(doc)
            if self._has_available_quota(doc):
                candidates_by_priority.setdefault(doc.get("priority", 0), []).append(doc)
        for priority in sorted(candidates_by_priority.keys()):
            selected = self._weighted_random_pick(candidates_by_priority[priority])
            if selected:
                claimed = await self._claim_selected_key(selected, now)
                if claimed:
                    return await self._enrich_key(claimed)
        return None

    async def _claim_selected_key(self, selected: dict, now: datetime) -> Optional[dict]:
        query = {
            "_id": ObjectId(selected["_id"]),
            "status": KeyStatus.active.value,
            "weight": {"$gt": 0},
        }
        inc_ops = {"total_requests": 1}
        request_quota = selected.get("requests_quota", {})
        if request_quota.get("enabled", False):
            query["$expr"] = {"$lt": ["$requests_quota.used", "$requests_quota.total"]}
            inc_ops["requests_quota.used"] = 1
        doc = await self._keys.find_one_and_update(
            query,
            {"$set": {"last_used_at": now}, "$inc": inc_ops},
            return_document=ReturnDocument.AFTER,
        )
        return self._strip_id(doc) if doc else None

    @staticmethod
    def _weighted_random_pick(candidates: List[dict]) -> Optional[dict]:
        if not candidates:
            return None
        weights = [c.get("weight", 10) for c in candidates]
        total = sum(weights)
        if total <= 0:
            return None
        return random.choices(candidates, weights=weights, k=1)[0]

    @staticmethod
    def _has_available_quota(doc: dict) -> bool:
        for field in ("token_quota", "seconds_quota", "requests_quota"):
            q = doc.get(field, {})
            if q.get("enabled", False) and q.get("total", 0) - q.get("used", 0) <= 0:
                return False
        return True

    async def _auto_recover_cooldown(self, group_id: str, now: datetime):
        await self._keys.update_many(
            {
                "group_id": group_id,
                "status": KeyStatus.cooldown.value,
                "cooldown_until": {"$lte": now},
            },
            {"$set": {
                "status": KeyStatus.active.value,
                "status_reason": "冷却结束自动恢复",
                "status_updated_at": now,
                "error_count": 0,
            }},
        )

    async def _auto_expire_keys(self, group_id: str, now: datetime):
        await self._keys.update_many(
            {
                "group_id": group_id,
                "status": {"$nin": [KeyStatus.expired.value, KeyStatus.disabled.value]},
                "expires_at": {"$ne": None, "$lte": now},
            },
            {"$set": {
                "status": KeyStatus.expired.value,
                "status_reason": "已过期",
                "status_updated_at": now,
            }},
        )

    # ── 消费与错误上报 ──────────────────────────────────────

    async def report_usage(self, key_id: str, usage: dict) -> dict:
        now = _now()
        current_doc = await self.get_by_id(key_id)
        if not current_doc:
            return {}
        usage = dict(usage or {})
        usage["api_key_id"] = key_id
        usage["group_id"] = current_doc.get("group_id", "")
        usage["category"] = current_doc.get("category", "")
        usage["platform_code"] = current_doc.get("platform_code", "")
        usage["created_at"] = now
        await self._usage.insert_one(usage)

        inc_ops = {}
        tokens = usage.get("tokens_used", 0)
        seconds = usage.get("seconds_used", 0)
        requests = usage.get("requests_used", 0)
        if tokens > 0:
            inc_ops["token_quota.used"] = tokens
        if seconds > 0:
            inc_ops["seconds_quota.used"] = seconds
        if requests > 0:
            reserved = 1 if (current_doc.get("requests_quota") or {}).get("enabled", False) else 0
            request_delta = max(0, requests - reserved)
            if request_delta > 0:
                inc_ops["requests_quota.used"] = request_delta

        set_ops = {"updated_at": now}
        if usage.get("success", True):
            set_ops["error_count"] = 0
        update = {"$set": set_ops}
        if inc_ops:
            update["$inc"] = inc_ops
        await self._keys.update_one({"_id": ObjectId(key_id)}, update)

        doc = await self.get_by_id(key_id)
        if doc and self._should_mark_exhausted(doc):
            await self._keys.update_one(
                {"_id": ObjectId(key_id)},
                {"$set": {
                    "status": KeyStatus.exhausted.value,
                    "status_reason": "额度耗尽",
                    "status_updated_at": now,
                }},
            )
            doc["status"] = KeyStatus.exhausted.value
        return doc or {}

    @staticmethod
    def _should_mark_exhausted(doc: dict) -> bool:
        if doc.get("status") != KeyStatus.active.value:
            return False
        return not ApiKeyRepository._has_available_quota(doc)

    async def report_error(self, key_id: str, error_message: str = "") -> dict:
        now = _now()
        doc = await self.get_by_id(key_id)
        if not doc:
            return {}
        last_error_at = doc.get("last_error_at")
        if last_error_at and last_error_at.tzinfo is None:
            last_error_at = last_error_at.replace(tzinfo=timezone.utc)
        within_window = last_error_at is not None and (now - last_error_at).total_seconds() <= ERROR_WINDOW_SECONDS
        err_count = (doc.get("error_count", 0) if within_window else 0) + 1
        await self._keys.update_one(
            {"_id": ObjectId(key_id)},
            {"$set": {"error_count": err_count, "last_error_at": now, "updated_at": now}},
        )
        threshold = max(doc.get("error_threshold") or MIN_ERROR_THRESHOLD, MIN_ERROR_THRESHOLD)
        cooldown_sec = doc.get("cooldown_seconds", 60)
        if err_count >= threshold:
            cooldown_end = now + timedelta(seconds=cooldown_sec)
            await self._keys.update_one(
                {"_id": ObjectId(key_id)},
                {"$set": {
                    "status": KeyStatus.cooldown.value,
                    "status_reason": f"{ERROR_WINDOW_SECONDS}秒内连续错误{err_count}次，冷却{cooldown_sec}秒: {error_message}",
                    "status_updated_at": now,
                    "cooldown_until": cooldown_end,
                    "error_count": 0,
                }},
            )
            doc["status"] = KeyStatus.cooldown.value
            doc["error_count"] = 0
        else:
            doc["error_count"] = err_count
        return doc

    async def reset_status(self, key_id: str, new_status: str = "disabled", reason: str = "") -> bool:
        now = _now()
        new_status = _normalize_status(new_status)
        update_data = {
            "status": new_status,
            "status_reason": reason,
            "status_updated_at": now,
            "updated_at": now,
        }
        if new_status == KeyStatus.active.value:
            update_data["error_count"] = 0
            update_data["cooldown_until"] = None
        result = await self._keys.update_one({"_id": ObjectId(key_id)}, {"$set": update_data})
        return result.modified_count > 0

    async def adjust_quota(
        self,
        key_id: str,
        quota_type: str,
        total: Optional[float] = None,
        used: Optional[float] = None,
        enabled: Optional[bool] = None,
        auto_reset_period: Optional[str] = None,
    ) -> bool:
        update = {}
        if total is not None:
            update[f"{quota_type}.total"] = total
        if used is not None:
            update[f"{quota_type}.used"] = used
        if enabled is not None:
            update[f"{quota_type}.enabled"] = enabled
        if auto_reset_period is not None:
            update[f"{quota_type}.auto_reset_period"] = auto_reset_period
        if not update:
            return False
        update["updated_at"] = _now()
        result = await self._keys.update_one({"_id": ObjectId(key_id)}, {"$set": update})
        doc = await self.get_by_id(key_id)
        if doc:
            if doc.get("status") == KeyStatus.exhausted.value and self._has_available_quota(doc):
                await self.reset_status(key_id, KeyStatus.active.value, "额度调整后恢复")
            elif doc.get("status") == KeyStatus.active.value and self._should_mark_exhausted(doc):
                await self._keys.update_one(
                    {"_id": ObjectId(key_id)},
                    {"$set": {
                        "status": KeyStatus.exhausted.value,
                        "status_reason": "额度调整后耗尽",
                        "status_updated_at": _now(),
                    }},
                )
        return result.modified_count > 0

    # ── 自动重置 ────────────────────────────────────────────

    async def run_auto_reset(self) -> int:
        now = _now()
        reset_count = 0
        async for doc in self._keys.find({}):
            key_id = str(doc["_id"])
            for quota_field in ("token_quota", "seconds_quota", "requests_quota"):
                q = doc.get(quota_field, {})
                if not q.get("enabled", False):
                    continue
                period = q.get("auto_reset_period", "none")
                if period == "none":
                    continue
                if self._should_reset(period, q.get("last_reset_at"), now):
                    await self._keys.update_one(
                        {"_id": doc["_id"]},
                        {"$set": {
                            f"{quota_field}.used": 0,
                            f"{quota_field}.last_reset_at": now,
                            "updated_at": now,
                        }},
                    )
                    if doc.get("status") == KeyStatus.exhausted.value:
                        updated_doc = await self.get_by_id(key_id)
                        if updated_doc and self._has_available_quota(updated_doc):
                            await self.reset_status(key_id, KeyStatus.active.value, "额度自动重置后恢复")
                    reset_count += 1
        return reset_count

    @staticmethod
    def _should_reset(period: str, last_reset, now: datetime) -> bool:
        if last_reset is None:
            return False
        if not hasattr(last_reset, "tzinfo") or last_reset.tzinfo is None:
            last_reset = last_reset.replace(tzinfo=timezone.utc)
        if period == "daily":
            return now.date() > last_reset.date()
        if period == "weekly":
            return (now - timedelta(days=now.weekday())).date() > (last_reset - timedelta(days=last_reset.weekday())).date()
        if period == "monthly":
            return (now.year, now.month) > (last_reset.year, last_reset.month)
        return False

    async def init_last_reset_at(self) -> int:
        now = _now()
        count = 0
        for quota_field in ("token_quota", "seconds_quota", "requests_quota"):
            result = await self._keys.update_many(
                {
                    f"{quota_field}.enabled": True,
                    f"{quota_field}.auto_reset_period": {"$nin": ["none", None, ""]},
                    f"{quota_field}.last_reset_at": None,
                },
                {"$set": {f"{quota_field}.last_reset_at": now}},
            )
            count += result.modified_count
        return count

    # ── 枚举与统计 ──────────────────────────────────────────

    async def list_categories(self) -> List[str]:
        values = set(await self._platforms.distinct("category"))
        values.update(await self._groups.distinct("category"))
        values.update(await self._keys.distinct("category"))
        return sorted(v for v in values if v)

    async def list_platforms(self, category: str = "") -> List[str]:
        query = {"category": _normalize_code(category)} if category else {}
        values = await self._platforms.distinct("code", query)
        return sorted(v for v in values if v)

    async def get_category_stats(self) -> List[dict]:
        pipeline = [
            {"$group": {
                "_id": "$category",
                "total_keys": {"$sum": 1},
                "active_keys": {"$sum": {"$cond": [{"$eq": ["$status", "active"]}, 1, 0]}},
                "total_requests": {"$sum": "$total_requests"},
            }},
            {"$sort": {"_id": 1}},
        ]
        return [doc async for doc in self._keys.aggregate(pipeline)]

    async def get_platform_stats(self, category: str = "") -> List[dict]:
        pipeline = []
        if category:
            pipeline.append({"$match": {"category": _normalize_code(category)}})
        pipeline.extend([
            {"$group": {
                "_id": {"category": "$category", "platform_code": "$platform_code"},
                "total_keys": {"$sum": 1},
                "active_keys": {"$sum": {"$cond": [{"$eq": ["$status", "active"]}, 1, 0]}},
                "total_requests": {"$sum": "$total_requests"},
            }},
            {"$sort": {"_id.category": 1, "_id.platform_code": 1}},
        ])
        return [doc async for doc in self._keys.aggregate(pipeline)]

    async def get_key_stats(self, key_id: str) -> dict:
        doc = await self.get_by_id(key_id)
        if not doc:
            return {}
        pipeline = [
            {"$match": {"api_key_id": key_id}},
            {"$group": {
                "_id": None,
                "total_tokens": {"$sum": "$tokens_used"},
                "total_seconds": {"$sum": "$seconds_used"},
                "total_requests": {"$sum": "$requests_used"},
                "avg_latency": {"$avg": "$latency_ms"},
                "success_count": {"$sum": {"$cond": ["$success", 1, 0]}},
                "error_count": {"$sum": {"$cond": ["$success", 0, 1]}},
            }},
        ]
        usage_stats = {}
        async for s in self._usage.aggregate(pipeline):
            usage_stats = s
            usage_stats.pop("_id", None)
        doc["usage_stats"] = usage_stats
        return doc

    async def list_usage(
        self,
        category: str = "",
        platform_code: str = "",
        group_id: str = "",
        api_key_id: str = "",
        start_date: str = "",
        end_date: str = "",
        page: int = 1,
        page_size: int = 50,
    ) -> tuple[list[dict], int]:
        query = {}
        if category:
            query["category"] = _normalize_code(category)
        if platform_code:
            query["platform_code"] = _normalize_code(platform_code)
        if group_id:
            query["group_id"] = _normalize_code(group_id)
        if api_key_id:
            query["api_key_id"] = api_key_id
        if start_date or end_date:
            date_q = {}
            if start_date:
                date_q["$gte"] = datetime.fromisoformat(start_date).replace(tzinfo=timezone.utc)
            if end_date:
                date_q["$lte"] = datetime.fromisoformat(end_date).replace(tzinfo=timezone.utc)
            if date_q:
                query["created_at"] = date_q
        total = await self._usage.count_documents(query)
        cursor = (
            self._usage.find(query)
            .sort("created_at", -1)
            .skip((page - 1) * page_size)
            .limit(page_size)
        )
        raw_items = []
        async for doc in cursor:
            doc = self._strip_id(doc)
            if isinstance(doc.get("created_at"), datetime):
                doc["created_at"] = doc["created_at"].strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"
            raw_items.append(doc)
        key_ids = list({doc["api_key_id"] for doc in raw_items if doc.get("api_key_id")})
        key_name_map = {}
        if key_ids:
            valid_oids = []
            for kid in key_ids:
                try:
                    valid_oids.append(ObjectId(kid))
                except Exception:
                    pass
            async for k in self._keys.find({"_id": {"$in": valid_oids}}, {"name": 1}):
                key_name_map[str(k["_id"])] = k.get("name") or ""
        for doc in raw_items:
            doc["api_key_name"] = key_name_map.get(doc.get("api_key_id", ""), "")
        return raw_items, total

    async def get_dashboard(self) -> dict:
        total = await self._keys.count_documents({})
        active = await self._keys.count_documents({"status": KeyStatus.active.value})
        exhausted = await self._keys.count_documents({"status": KeyStatus.exhausted.value})
        error = await self._keys.count_documents({"status": KeyStatus.error.value})
        cooldown = await self._keys.count_documents({"status": KeyStatus.cooldown.value})
        disabled = await self._keys.count_documents({"status": KeyStatus.disabled.value})
        expired = await self._keys.count_documents({"status": KeyStatus.expired.value})
        total_usage = await self._usage.count_documents({})
        return {
            "total_keys": total,
            "active_keys": active,
            "exhausted_keys": exhausted,
            "error_keys": error,
            "cooldown_keys": cooldown,
            "disabled_keys": disabled,
            "expired_keys": expired,
            "total_usage_records": total_usage,
        }

    async def _enrich_key(self, doc: dict) -> dict:
        platform = await self._platforms.find_one({
            "code": doc.get("platform_code"),
            "category": doc.get("category"),
        })
        group = await self._groups.find_one({"group_id": doc.get("group_id")})
        doc["platform_name"] = (platform or {}).get("name", doc.get("platform_code", ""))
        doc["group_name"] = (group or {}).get("name", doc.get("group_id", ""))
        if not doc.get("base_url") and platform:
            doc["base_url"] = platform.get("default_base_url", "")
        if not doc.get("model") and platform:
            doc["model"] = platform.get("default_model", "")
        if platform and not doc.get("extra_config"):
            doc["extra_config"] = platform.get("default_extra_config", {})
        return doc

    @staticmethod
    def _strip_id(doc: Optional[dict]) -> dict:
        row = dict(doc or {})
        if "_id" in row:
            row["_id"] = str(row["_id"])
        return row
