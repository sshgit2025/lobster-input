"""
TavilyExtractor — Tavily 搜索引擎用量提取器。

Tavily 按搜索次数计费，每次调用记录：
  - search_count: 本次搜索次数（固定为 1）
  - latency_ms: 搜索耗时
"""
import logging
from typing import Any, Optional

from app.data.usage.extractors.base import BaseUsageExtractor
from app.data.usage.models import UsageEvent

logger = logging.getLogger("voice_input.usage.tavily")


class TavilyExtractor(BaseUsageExtractor):
    """记录 Tavily 搜索调用次数和耗时。"""

    def extract(self, response: Any, **kwargs) -> Optional[UsageEvent]:
        """
        Args:
            response: Tavily 搜索响应 dict（当前仅用于确认调用成功）
            kwargs:
              user_email      (str): 用户邮箱
              operation       (str): 固定为 "search"
              latency_ms      (int): 搜索耗时
              api_key         (str): 调用使用的 Tavily API Key 原文（将被脱敏存储）
              client_platform (str): 客户端平台标识（来自请求头 X-Client-Platform）
        """
        user_email = kwargs.get("user_email", "")
        operation = kwargs.get("operation", "search")
        latency_ms = kwargs.get("latency_ms", 0)
        api_key = kwargs.get("api_key", "")
        client_platform = kwargs.get("client_platform", "")

        if not user_email:
            return None

        return UsageEvent(
            user_email=user_email,
            platform="tavily",
            operation=operation,
            date=self._utc_date(),
            search_count=1,
            request_count=1,
            latency_ms=latency_ms,
            api_key_hint=self._mask_api_key(api_key),
            client_platform=client_platform,
        )
