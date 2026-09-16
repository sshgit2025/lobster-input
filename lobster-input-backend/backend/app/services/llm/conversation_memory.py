"""
ConversationMemory — 基于内存的用户短期对话记忆。

按 namespace（user_email 或 user_email:operation）隔离，每个命名空间保留最近 MAX_TURNS 轮对话。
每轮对话包含 Whisper 原始识别文本、LLM 处理后的结果，以及可选的 selected_text（rewrite 模式用）。
在提交给 LLM 时作为短期记忆一并传入，帮助 LLM 理解用户上下文。

设计决策：
  - 使用进程内存而非 DB，重启后自动清空（短期记忆无需持久化）
  - 使用 TTL 自动过期，避免长时间不活跃用户占用内存
  - 线程安全：asyncio 单线程模型下无需加锁
  - rewrite / agent 操作使用各自独立命名空间（{email}:rewrite / {email}:agent），避免与 transcribe 历史混淆
  - rewrite 的每轮记忆保留 selected_text，帮助 LLM 理解操作对象的上下文
"""
import time
import logging
from dataclasses import dataclass, field
from typing import Optional

logger = logging.getLogger("voice_input.memory")

MAX_TURNS = 0
TTL_SECONDS = 1800  # 30 分钟无活动自动清空


@dataclass
class ConversationTurn:
    """单轮对话记录。"""
    transcript: str
    result: str
    selected_text: Optional[str] = None  # rewrite 模式下记录本轮操作的选中文本
    timestamp: float = field(default_factory=time.time)


class _UserMemory:
    """单个命名空间的对话记忆。"""

    def __init__(self):
        self.turns: list[ConversationTurn] = []
        self.last_active: float = time.time()

    def add(self, transcript: str, result: str, selected_text: Optional[str] = None) -> None:
        if MAX_TURNS == 0:
            self.last_active = time.time()
            return
        self.turns.append(ConversationTurn(
            transcript=transcript,
            result=result,
            selected_text=selected_text,
        ))
        if len(self.turns) > MAX_TURNS:
            self.turns = self.turns[-MAX_TURNS:]
        self.last_active = time.time()

    def get_history(self) -> list[ConversationTurn]:
        return list(self.turns)

    def is_expired(self) -> bool:
        return (time.time() - self.last_active) > TTL_SECONDS


class ConversationMemory:
    """
    全局对话记忆管理器（单例）。
    按 namespace 隔离（transcribe 用 user_email，rewrite 用 user_email:rewrite，agent 用 user_email:agent）。
    每个命名空间最多保留 MAX_TURNS 轮。
    """

    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._store: dict[str, _UserMemory] = {}
        return cls._instance

    @staticmethod
    def _ns(user_email: str, operation: str = "transcribe") -> str:
        """生成命名空间 key。rewrite / agent 使用各自独立命名空间，避免历史污染 transcribe 上下文。"""
        if operation in ("rewrite", "agent"):
            return f"{user_email}:{operation}"
        return user_email

    def add_turn(
        self,
        user_email: str,
        transcript: str,
        result: str,
        operation: str = "transcribe",
        selected_text: Optional[str] = None,
    ) -> None:
        if not user_email:
            return
        self._cleanup_expired()
        ns = self._ns(user_email, operation)
        if ns not in self._store:
            self._store[ns] = _UserMemory()
        self._store[ns].add(transcript, result, selected_text)
        logger.debug(
            "Memory updated for %s (op=%s): %d turns",
            user_email, operation, len(self._store[ns].turns)
        )

    def get_history(self, user_email: str, operation: str = "transcribe") -> list[ConversationTurn]:
        if not user_email:
            return []
        ns = self._ns(user_email, operation)
        if ns not in self._store:
            return []
        mem = self._store[ns]
        if mem.is_expired():
            del self._store[ns]
            return []
        return mem.get_history()

    def clear(self, user_email: str, operation: str = "transcribe") -> None:
        """清空指定用户指定操作的对话历史（用于切断污染正反馈环）。"""
        ns = self._ns(user_email, operation)
        if ns in self._store:
            del self._store[ns]
            logger.info("Memory cleared for %s (op=%s)", user_email, operation)

    def _cleanup_expired(self) -> None:
        """惰性清理过期用户记忆。"""
        expired = [k for k, v in self._store.items() if v.is_expired()]
        for k in expired:
            del self._store[k]
        if expired:
            logger.debug("Cleaned up expired memory for %d namespaces", len(expired))
