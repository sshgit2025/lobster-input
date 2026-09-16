"""
GroqLLMExtractor — Groq LLM 用量提取器。

Groq 通过 langchain-community ChatGroq 调用，同样遵循 langchain-core 的
UsageMetadata TypedDict 标准，字段与 OpenAI 完全一致。

单独实现子类的原因：
  1. platform 字段区分为 "groq_llm"，便于号池分析时按 key 独立统计
  2. Groq 未来若有专属字段（如 tokens_per_second）可在此扩展
"""
import logging
from typing import Any, Optional

from app.data.usage.extractors.base import BaseUsageExtractor
from app.data.usage.models import UsageEvent

logger = logging.getLogger("voice_input.usage.groq_llm")


class GroqLLMExtractor(BaseUsageExtractor):
    """从 Groq LangChain AIMessage 中提取 token 用量。"""

    def extract(self, response: Any, **kwargs) -> Optional[UsageEvent]:
        user_email = kwargs.get("user_email", "")
        operation = kwargs.get("operation", "unknown")
        latency_ms = kwargs.get("latency_ms", 0)
        api_key = kwargs.get("api_key", "")
        client_platform = kwargs.get("client_platform", "")

        if not user_email:
            return None

        input_tokens, output_tokens = self._parse_tokens(response)
        if input_tokens == 0 and output_tokens == 0:
            logger.debug("GroqLLMExtractor: no token usage found in response")
            return None

        return UsageEvent(
            user_email=user_email,
            platform="groq_llm",
            operation=operation,
            date=self._utc_date(),
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            request_count=1,
            latency_ms=latency_ms,
            api_key_hint=self._mask_api_key(api_key),
            client_platform=client_platform,
        )

    @staticmethod
    def _parse_tokens(response: Any) -> tuple[int, int]:
        """
        从 AIMessage.usage_metadata 提取 token 用量。

        langchain-core >= 1.0 中 UsageMetadata 是 TypedDict（即 dict），
        直接用 dict.get() 读取，兼容 None 值。
        """
        usage = getattr(response, "usage_metadata", None)
        if usage and isinstance(usage, dict):
            return (
                usage.get("input_tokens") or 0,
                usage.get("output_tokens") or 0,
            )

        # 兼容降级路径：response_metadata["token_usage"]
        response_meta = getattr(response, "response_metadata", None)
        if response_meta and isinstance(response_meta, dict):
            token_usage = response_meta.get("token_usage", {})
            if token_usage:
                return (
                    token_usage.get("prompt_tokens") or 0,
                    token_usage.get("completion_tokens") or 0,
                )

        return 0, 0
