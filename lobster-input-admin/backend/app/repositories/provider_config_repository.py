"""Provider runtime configuration stored in main system_config."""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from motor.motor_asyncio import AsyncIOMotorDatabase

PROVIDER_RUNTIME_CONFIG_KEY = "provider_runtime_config"

DEFAULT_PROVIDER_RUNTIME_CONFIG: dict[str, Any] = {
    "version": 1,
    "providers": {
        "asr_dashscope": {
            "provider_id": "asr_dashscope",
            "name": "DashScope ASR",
            "category": "asr",
            "implementation": "dashscope",
            "pool_group_id": "asr_dashscope_default",
            "enabled": True,
            "config": {},
        },
        "asr_openai": {
            "provider_id": "asr_openai",
            "name": "OpenAI Whisper ASR",
            "category": "asr",
            "implementation": "openai",
            "pool_group_id": "asr_openai_default",
            "enabled": True,
            "config": {},
        },
        "asr_groq": {
            "provider_id": "asr_groq",
            "name": "Groq Whisper ASR",
            "category": "asr",
            "implementation": "groq",
            "pool_group_id": "asr_groq_default",
            "enabled": True,
            "config": {},
        },
        "asr_volcengine": {
            "provider_id": "asr_volcengine",
            "name": "Volcengine ASR",
            "category": "asr",
            "implementation": "volcengine",
            "pool_group_id": "asr_volcengine_default",
            "enabled": True,
            "config": {},
        },
        "asr_qwen_realtime": {
            "provider_id": "asr_qwen_realtime",
            "name": "Qwen Realtime ASR",
            "category": "asr_realtime",
            "implementation": "dashscope_realtime",
            "pool_group_id": "asr_realtime_dashscope_realtime_default",
            "enabled": True,
            "config": {},
        },
        "asr_volcengine_realtime": {
            "provider_id": "asr_volcengine_realtime",
            "name": "Volcengine Seed-ASR Realtime",
            "category": "asr_realtime",
            "implementation": "volcengine_realtime",
            "pool_group_id": "asr_realtime_volcengine_realtime_default",
            "enabled": True,
            "config": {},
        },
        "llm_aliyun": {
            "provider_id": "llm_aliyun",
            "name": "Aliyun Qwen Chat",
            "category": "llm_chat",
            "implementation": "aliyun",
            "pool_group_id": "llm_chat_aliyun_default",
            "enabled": True,
            "config": {},
        },
        "search_qwen": {
            "provider_id": "search_qwen",
            "name": "Qwen Web Search",
            "category": "web_search",
            "implementation": "dashscope_web_search",
            "pool_group_id": "web_search_aliyun_search_default",
            "enabled": True,
            "config": {"search_strategy": "agent"},
        },
        "search_tavily": {
            "provider_id": "search_tavily",
            "name": "Tavily Search",
            "category": "web_search",
            "implementation": "tavily",
            "pool_group_id": "web_search_tavily_default",
            "enabled": True,
            "config": {},
        },
    },
    "nodes": {
        "asr_transcribe": {
            "node_id": "asr_transcribe",
            "name": "语音识别",
            "category": "asr",
            "provider_id": "asr_dashscope",
            "enabled": True,
            "input_schema": {"audio": "file"},
            "output_schema": {"text": "string", "language": "string"},
        },
        "asr_realtime_transcribe": {
            "node_id": "asr_realtime_transcribe",
            "name": "实时语音识别",
            "category": "asr_realtime",
            "provider_id": "asr_qwen_realtime",
            "enabled": True,
            "input_schema": {
                "audio_stream": "pcm16|opus",
                "sample_rate": "int",
                "language": "string",
                "vad": "boolean",
            },
            "output_schema": {
                "partial": "string",
                "final": "string",
                "language": "string",
            },
        },
        "llm_transcribe": {
            "node_id": "llm_transcribe",
            "name": "转写文本整理",
            "category": "llm_chat",
            "provider_id": "llm_aliyun",
            "enabled": True,
            "input_schema": {"transcript": "string", "context": "object"},
            "output_schema": {"text": "string"},
        },
        "llm_rewrite": {
            "node_id": "llm_rewrite",
            "name": "改写/生成",
            "category": "llm_chat",
            "provider_id": "llm_aliyun",
            "enabled": True,
            "input_schema": {"transcript": "string", "selected_text": "string"},
            "output_schema": {"text": "string"},
        },
        "intent_router": {
            "node_id": "intent_router",
            "name": "Agent 意图识别",
            "category": "llm_chat",
            "provider_id": "llm_aliyun",
            "enabled": True,
            "input_schema": {"transcript": "string"},
            "output_schema": {"intent": "enum"},
        },
        "openclaw_transcribe": {
            "node_id": "openclaw_transcribe",
            "name": "OpenClaw 命令整理",
            "category": "llm_chat",
            "provider_id": "llm_aliyun",
            "enabled": True,
            "input_schema": {"transcript": "string"},
            "output_schema": {"command_or_text": "string"},
        },
        "android_quick_action": {
            "node_id": "android_quick_action",
            "name": "Android 文本快捷动作",
            "category": "llm_chat",
            "provider_id": "llm_aliyun",
            "enabled": True,
            "input_schema": {"text": "string", "action": "enum"},
            "output_schema": {"text": "string"},
        },
        "web_search": {
            "node_id": "web_search",
            "name": "联网搜索",
            "category": "web_search",
            "provider_id": "search_tavily",
            "enabled": True,
            "input_schema": {"query": "string"},
            "output_schema": {"markdown": "string"},
        },
    },
}


class ProviderConfigRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.col = db["system_config"]

    async def ensure_default(self) -> None:
        doc = await self.col.find_one({"key": PROVIDER_RUNTIME_CONFIG_KEY})
        if doc is None:
            await self.save(DEFAULT_PROVIDER_RUNTIME_CONFIG)

    async def get(self) -> dict[str, Any]:
        doc = await self.col.find_one({"key": PROVIDER_RUNTIME_CONFIG_KEY})
        value = doc.get("value") if doc else None
        return self._clean(value if isinstance(value, dict) else DEFAULT_PROVIDER_RUNTIME_CONFIG)

    async def save(self, value: dict[str, Any]) -> dict[str, Any]:
        current = await self.get() if await self.col.find_one({"key": PROVIDER_RUNTIME_CONFIG_KEY}) else DEFAULT_PROVIDER_RUNTIME_CONFIG
        cleaned = self._clean(value)
        cleaned["version"] = int(current.get("version", 0)) + 1
        cleaned["updated_at"] = datetime.now(timezone.utc).isoformat()
        await self.col.update_one(
            {"key": PROVIDER_RUNTIME_CONFIG_KEY},
            {"$set": {"value": cleaned, "updated_at": datetime.now(timezone.utc)}},
            upsert=True,
        )
        return cleaned

    def _clean(self, raw: dict[str, Any]) -> dict[str, Any]:
        data = dict(raw or {})
        retired_provider_ids = {"embedding_aliyun"}
        retired_node_ids = {"embedding_correction"}
        retired_categories = {"embedding"}
        providers = {}
        for pid, cfg in (data.get("providers") or {}).items():
            if not isinstance(cfg, dict):
                continue
            provider_id = self._norm(cfg.get("provider_id") or pid)
            category = self._norm(cfg.get("category"))
            implementation = self._norm(cfg.get("implementation"))
            pool_group_id = self._norm(cfg.get("pool_group_id"))
            if provider_id in retired_provider_ids or category in retired_categories:
                continue
            if not provider_id or not category or not implementation or not pool_group_id:
                continue
            providers[provider_id] = {
                "provider_id": provider_id,
                "name": str(cfg.get("name") or provider_id).strip(),
                "category": category,
                "implementation": implementation,
                "pool_group_id": pool_group_id,
                "enabled": bool(cfg.get("enabled", True)),
                "config": cfg.get("config") if isinstance(cfg.get("config"), dict) else {},
            }
        nodes = {}
        for nid, cfg in (data.get("nodes") or {}).items():
            if not isinstance(cfg, dict):
                continue
            node_id = self._norm(cfg.get("node_id") or nid)
            category = self._norm(cfg.get("category"))
            provider_id = self._norm(cfg.get("provider_id"))
            if node_id in retired_node_ids or category in retired_categories or provider_id in retired_provider_ids:
                continue
            if not node_id or not category or not provider_id:
                continue
            nodes[node_id] = {
                "node_id": node_id,
                "name": str(cfg.get("name") or node_id).strip(),
                "category": category,
                "provider_id": provider_id,
                "enabled": bool(cfg.get("enabled", True)),
                "input_schema": cfg.get("input_schema") if isinstance(cfg.get("input_schema"), dict) else {},
                "output_schema": cfg.get("output_schema") if isinstance(cfg.get("output_schema"), dict) else {},
                "config": cfg.get("config") if isinstance(cfg.get("config"), dict) else {},
            }
        defaults = DEFAULT_PROVIDER_RUNTIME_CONFIG
        for pid, cfg in defaults["providers"].items():
            providers.setdefault(pid, dict(cfg))
        for nid, cfg in defaults["nodes"].items():
            nodes.setdefault(nid, dict(cfg))
        return {
            "version": int(data.get("version") or 1),
            "providers": providers,
            "nodes": nodes,
        }

    @staticmethod
    def _norm(value: Any) -> str:
        return str(value or "").strip().lower().replace(" ", "_")
