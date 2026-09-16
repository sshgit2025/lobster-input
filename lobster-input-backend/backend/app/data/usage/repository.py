"""
UsageRepository — 用量统计 MongoDB 数据访问层。

集合：usage_stats
文档结构（按 user_email + date + platform + operation + api_key_hint + client_platform 六元组唯一）：
  {
    "user_email":         "user@example.com",
    "date":               "2026-03-17",
    "platform":           "openai_llm",
    "operation":          "rewrite",
    "api_key_hint":       "sk-abcde****",
    "client_platform":    "macos_standard",
    "input_tokens":       1200,
    "output_tokens":      350,
    "audio_duration_sec": 0.0,
    "audio_chars":        0,
    "search_count":       0,
    "request_count":      5,
    "latency_ms":         12300,
    "credits_deducted":   0
  }


api_key_hint 说明：
  记录本次调用使用的 API Key 脱敏标识（前8位 + "****"），
  作为唯一索引的一个维度，使不同 key 的用量数据分开统计，
  便于后续号池负载均衡分析（各 key 的调用次数、token 消耗、延迟分布等）。

client_platform 说明：
  来自请求头 X-Client-Platform，标识发起请求的客户端类型，
  作为唯一索引的一个维度，使不同客户端的用量数据分开统计。
  取值：macos_standard | macos_diy | ios | ""（旧版客户端兼容）

写入策略：$inc 原子累加，upsert=True，天级别自动聚合。
"""
import logging
from datetime import datetime, timezone
from pymongo import ASCENDING

from app.core.database import get_db
from app.data.usage.models import UsageEvent

logger = logging.getLogger("voice_input.usage.repository")

_COLLECTION = "usage_stats"


class UsageRepository:
    """用量统计数据访问，负责 $inc upsert 和索引初始化。"""

    def _col(self):
        return get_db()[_COLLECTION]

    async def ensure_indexes(self) -> None:
        """初始化复合唯一索引（应用启动时调用一次）。"""
        col = self._col()

        existing = await col.index_information()
        old_idx = existing.get("usage_stats_unique")
        if old_idx:
            old_keys = [k for k, _ in old_idx.get("key", [])]
            if "client_platform" not in old_keys:
                logger.info("Dropping outdated usage_stats_unique index (missing client_platform)...")
                await col.drop_index("usage_stats_unique")

        await col.create_index(
            [
                ("user_email", ASCENDING),
                ("date", ASCENDING),
                ("platform", ASCENDING),
                ("operation", ASCENDING),
                ("api_key_hint", ASCENDING),
                ("client_platform", ASCENDING),
            ],
            unique=True,
            name="usage_stats_unique",
        )
        await col.create_index(
            [("user_email", ASCENDING), ("date", ASCENDING)],
            name="usage_stats_user_date",
        )
        await col.create_index(
            [("api_key_hint", ASCENDING), ("date", ASCENDING)],
            name="usage_stats_key_date",
        )
        await col.create_index(
            [("client_platform", ASCENDING), ("date", ASCENDING)],
            name="usage_stats_client_date",
        )
        logger.info("UsageRepository: indexes ensured.")

    async def increment(self, event: UsageEvent) -> None:
        """
        按六元组 (user_email, date, platform, operation, api_key_hint, client_platform) 原子累加用量指标。
        文档不存在时自动创建（upsert）。
        """
        col = self._col()
        filter_doc = {
            "user_email": event.user_email,
            "date": event.date,
            "platform": event.platform,
            "operation": event.operation,
            "api_key_hint": event.api_key_hint,
            "client_platform": event.client_platform,
        }
        inc_doc = {
            "input_tokens": event.input_tokens,
            "output_tokens": event.output_tokens,
            "audio_chars": event.audio_chars,
            "search_count": event.search_count,
            "request_count": event.request_count,
            "latency_ms": event.latency_ms,
        }
        # audio_duration_sec 使用浮点累加
        if event.audio_duration_sec > 0:
            inc_doc["audio_duration_sec"] = event.audio_duration_sec

        now = datetime.now(timezone.utc)
        await col.update_one(
            filter_doc,
            {
                "$inc": inc_doc,
                "$set": {"updated_at": now},
                "$setOnInsert": {"created_at": now},
            },
            upsert=True,
        )
