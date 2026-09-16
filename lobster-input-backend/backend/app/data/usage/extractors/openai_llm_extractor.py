"""
OpenAILLMExtractor — OpenAI LLM 用量提取器。

基于 langchain-core >= 1.0 的 UsageMetadata TypedDict 结构提取 token 用量。

UsageMetadata 字段（langchain_core.messages.ai.UsageMetadata）：
  input_tokens:         int   — 输入 token 总数（含缓存命中部分）
  output_tokens:        int   — 输出 token 总数（含 reasoning 部分）
  total_tokens:         int   — 总 token 数
  input_token_details:  dict  — 可选，细节：audio / cache_read / cache_creation 等
  output_token_details: dict  — 可选，细节：audio / reasoning 等

langchain-openai 通过 _create_usage_metadata() 从 OpenAI 原始响应填充此结构。
"""
import logging
from typing import Any, Optional

from app.data.usage.extractors.base import BaseUsageExtractor
from app.data.usage.models import UsageEvent

logger = logging.getLogger("voice_input.usage.openai_llm")


class OpenAILLMExtractor(BaseUsageExtractor):
    """从 OpenAI LangChain AIMessage 中提取 token 用量。"""

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
            logger.debug("OpenAILLMExtractor: no token usage found in response")
            return None

        return UsageEvent(
            user_email=user_email,
            platform="openai_llm",
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

        # 兼容降级路径：response_metadata["token_usage"]（部分旧版 provider 适配层）
        response_meta = getattr(response, "response_metadata", None)
        if response_meta and isinstance(response_meta, dict):
            token_usage = response_meta.get("token_usage", {})
            if token_usage:
                return (
                    token_usage.get("prompt_tokens") or 0,
                    token_usage.get("completion_tokens") or 0,
                )

        return 0, 0
