"""
IntentRouter — Agent 意图识别路由器。

职责：
  1. 通过 PromptManager.get_intent_system_prompt() 获取系统提示词
     （内置 agent_intent.txt + 用户 intent_hint 追加，如有配置）
  2. 调用 LLM（小模型，低延迟）对用户语音文本进行意图分类
  3. 将 LLM 输出解析为 IntentType 枚举
  4. 输出不合法时执行兜底策略（默认降级为 TRANSCRIBE）

IntentType 枚举（5 种意图 + fallback）：
  TRANSCRIBE   — 语音转文字（第1种快捷键流程）
  REWRITE      — 改写选中文本（第2种快捷键流程）
  SEARCH       — 搜索引擎查询（Tavily）
  OPENCLAW_ON          — 开启 OpenClaw 对话会话
  OPENCLAW_OFF         — 关闭 OpenClaw 对话会话
  OPENCLAW_NEW_SESSION — 开启新的 OpenClaw 对话会话
"""
import asyncio
import logging
import time
from enum import Enum
from typing import Optional, List

from langchain_core.messages import SystemMessage, HumanMessage
from langchain_core.runnables.config import RunnableConfig

from app.providers.llm.runtime import get_llm_for_node
from app.prompts.prompt_manager import PromptManager
from app.services.infra.api_pool_client import report_usage, report_error, PoolKeyInfo
from app.data.usage.extractors.openai_llm_extractor import OpenAILLMExtractor
from app.data.usage.extractors.groq_llm_extractor import GroqLLMExtractor
from app.data.usage.queue import emit as usage_emit

logger = logging.getLogger("voice_input.intent_router")

_VALID_INTENTS = {
    "TRANSCRIBE",
    "REWRITE",
    "SEARCH",
    "OPENCLAW_ON",
    "OPENCLAW_OFF",
    "OPENCLAW_NEW_SESSION",
}
_FALLBACK_INTENT_RAW = "TRANSCRIBE"


class IntentType(str, Enum):
    """Agent 意图分类枚举。"""
    TRANSCRIBE = "TRANSCRIBE"
    REWRITE = "REWRITE"
    SEARCH = "SEARCH"
    OPENCLAW_ON = "OPENCLAW_ON"
    OPENCLAW_OFF = "OPENCLAW_OFF"
    OPENCLAW_NEW_SESSION = "OPENCLAW_NEW_SESSION"


class IntentRouter:
    """
    LLM 驱动的意图分类路由器。
    通过 PromptManager.get_intent_system_prompt() 获取提示词
    （内置模板 + 用户 intent_hint 追加），LLM 输出不合规时自动兜底为 TRANSCRIBE。
    """

    async def classify(
        self,
        transcript: str,
        user_email: Optional[str] = None,
        provider: Optional[str] = None,
        model: Optional[str] = None,
        client_platform: str = "",
        langchain_callbacks: Optional[List] = None,
        return_key_info: bool = False,
        flow_name: str = "",
        transcript_language: str = "",
    ) -> IntentType:
        """
        对用户语音文本进行意图分类。

        Args:
            transcript:          Whisper 识别的语音文本
            user_email:          当前用户邮箱（用于读取 intent_hint 配置）
            provider:            LLM 提供商（留空使用默认值）
            model:               模型名称（留空使用默认值，意图分类可用小模型节省成本）
            langchain_callbacks: 外部父 trace 传入的 LangChain callback，用于 LangWatch child span
            flow_name:           当前处理流程名称，供 PromptManager 路由提示词目录和号池标签筛选
            transcript_language: ASR 识别语言代码，供 PromptManager 路由提示词目录

        Returns:
            IntentType 枚举，LLM 输出不合规时返回 IntentType.TRANSCRIBE（兜底）
        """
        system_prompt = await PromptManager.get_intent_system_prompt(
            user_email, client_platform=client_platform,
            flow_name=flow_name, transcript_language=transcript_language,
        )
        llm, key_info = await get_llm_for_node(node_id="intent_router", model_override=model or "")

        messages = [
            SystemMessage(content=system_prompt),
            HumanMessage(content=transcript),
        ]

        try:
            t0 = time.monotonic()
            config = RunnableConfig(callbacks=langchain_callbacks) if langchain_callbacks else {}
            response = await llm.ainvoke(messages, config=config)
            latency_ms = int((time.monotonic() - t0) * 1000)

            raw = response.content.strip().upper() if hasattr(response, "content") else ""
            raw = raw.split()[0] if raw else ""

            if user_email:
                self._emit_usage(response, user_email, provider, latency_ms, client_platform, key_info)

            if raw in _VALID_INTENTS:
                intent = IntentType(raw)
                logger.info(
                    "[IntentRouter] user=%s classified=[%s] transcript=[%s] system_prompt_len=%d",
                    user_email or "<anonymous>", intent.value,
                    transcript[:60], len(system_prompt),
                )
                return (intent, key_info) if return_key_info else intent
            else:
                logger.warning(
                    "[IntentRouter] user=%s LLM output=[%s] not valid → fallback to %s",
                    user_email or "<anonymous>", raw, _FALLBACK_INTENT_RAW,
                )
                intent = IntentType(_FALLBACK_INTENT_RAW)
                return (intent, key_info) if return_key_info else intent

        except Exception as e:
            logger.error(
                "[IntentRouter] user=%s classification failed: %s → fallback to %s",
                user_email or "<anonymous>", e, _FALLBACK_INTENT_RAW,
            )
            await report_error(key_info, str(e))
            intent = IntentType(_FALLBACK_INTENT_RAW)
            return (intent, key_info) if return_key_info else intent

    @staticmethod
    def _emit_usage(response, user_email: str, provider: Optional[str], latency_ms: int,
                    client_platform: str = "",
                    key_info: Optional[PoolKeyInfo] = None) -> None:
        """提取意图分类 LLM 调用的 token 用量并投递到统计队列。"""
        effective_provider = ((key_info.platform_code if key_info else provider) or "openai").lower()
        if effective_provider == "groq":
            extractor = GroqLLMExtractor()
        else:
            extractor = OpenAILLMExtractor()

        api_key = key_info.api_key if key_info else ""
        event = extractor.extract(
            response,
            user_email=user_email,
            operation="intent_classify",
            latency_ms=latency_ms,
            api_key=api_key,
            client_platform=client_platform,
        )
        if event:
            usage_emit(event)
            if key_info:
                asyncio.ensure_future(report_usage(
                    key_info,
                    tokens_used=event.input_tokens + event.output_tokens,
                    operation="intent_classify",
                    user_email=user_email,
                    latency_ms=latency_ms,
                    client_platform=client_platform,
                ))
