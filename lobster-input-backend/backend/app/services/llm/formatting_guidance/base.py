"""格式指导策略的公共契约与工具函数。本文件不含任何具体策略的文本或阈值。"""
from abc import ABC, abstractmethod


def language_key(language: str = "") -> str:
    """把 ASR 语言代码归一到提示词字典的键（zh-CN → zh；空值 → default）。"""
    return (language or "default").lower().replace("_", "-").split("-", 1)[0] or "default"


class TranscribeFormattingGuidance(ABC):
    """策略接口：为本轮 transcribe 生成格式指导文本（可为空字符串表示不注入）。"""

    @abstractmethod
    def hint(self, transcript: str, language: str = "") -> str:
        ...
