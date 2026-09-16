"""
BaseUsageExtractor — 用量提取器抽象基类。

设计原则：
  - 每种平台实现一个子类，只需重写 extract() 方法
  - 将来切换平台时，只需新增子类并注册到调用方，无需修改其他代码
  - extract() 返回 None 表示该次调用无法提取用量（静默跳过，不影响主流程）
"""
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from typing import Any, Optional

from app.data.usage.models import UsageEvent


class BaseUsageExtractor(ABC):
    """用量提取器抽象基类。子类实现 extract() 从 API 响应中提取用量指标。"""

    @abstractmethod
    def extract(self, response: Any, **kwargs) -> Optional[UsageEvent]:
        """
        从 API 响应中提取用量指标，返回 UsageEvent。

        Args:
            response: API 原始响应对象（LangChain AIMessage / dict / str 等）
            **kwargs: 额外上下文参数，如 user_email、operation、provider、
                      audio_path、latency_ms 等，各子类按需使用

        Returns:
            UsageEvent 实例，或 None（响应不含用量信息时跳过）
        """

    @staticmethod
    def _utc_date() -> str:
        """返回当前 UTC 日期字符串，格式 YYYY-MM-DD。"""
        return datetime.now(timezone.utc).strftime("%Y-%m-%d")

    @staticmethod
    def _mask_api_key(api_key: str) -> str:
        """
        对 API Key 进行脱敏处理，保留前4位 + "****" + 后4位。

        示例：
          "sk-abcdefghijklmnop"  → "sk-a****mnop"
          "gsk_abc123xyz789"     → "gsk_****789"（不足12位时只保留前4位）
          ""                     → ""

        设计原则：首尾各4位便于人工核对具体是哪个 key，
        中间遮盖保证密钥安全，不暴露完整内容。
        """
        if not api_key:
            return ""
        if len(api_key) <= 8:
            return f"{api_key[:4]}****"
        return f"{api_key[:4]}****{api_key[-4:]}"
