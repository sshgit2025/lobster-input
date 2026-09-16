"""
FailureGuard — 连续失败安全计数器（防恶意攻击）。

设计目标：
  防止用户利用"流程总是失败一半 → 不扣积分"的漏洞，
  恶意消耗平台资源（Whisper / LLM tokens）而不付出积分代价。

策略：
  - 按 user_email 维度记录连续失败次数
  - 全流程成功 → 重置计数为 0
  - 流程异常（消耗了平台资源但未成功扣减积分）→ 计数 +1
  - 达到阈值（MAX_CONSECUTIVE_FAILURES）→ 冻结该用户请求，
    在 FREEZE_DURATION_SEC 秒内拒绝新请求
  - 使用内存字典 + TTL，进程重启自动解冻

线程安全：
  单进程多协程环境下 dict 操作天然安全，无需加锁。
"""
import time
import logging
from typing import Dict, Tuple

logger = logging.getLogger("voice_input.failure_guard")

MAX_CONSECUTIVE_FAILURES = 10
FREEZE_DURATION_SEC = 300


class FailureGuard:
    """单例连续失败计数器。"""
    _store: Dict[str, Tuple[int, float]] = {}

    @classmethod
    def is_frozen(cls, user_email: str) -> bool:
        if not user_email:
            return False
        entry = cls._store.get(user_email)
        if entry is None:
            return False
        count, frozen_at = entry
        if count < MAX_CONSECUTIVE_FAILURES:
            return False
        if time.monotonic() - frozen_at > FREEZE_DURATION_SEC:
            cls._store.pop(user_email, None)
            logger.info("FailureGuard: user=%s freeze expired, reset", user_email)
            return False
        return True

    @classmethod
    def record_failure(cls, user_email: str) -> int:
        if not user_email:
            return 0
        entry = cls._store.get(user_email)
        if entry is None:
            count = 1
        else:
            count = entry[0] + 1
        cls._store[user_email] = (count, time.monotonic())
        if count >= MAX_CONSECUTIVE_FAILURES:
            logger.warning(
                "FailureGuard: user=%s reached %d consecutive failures, frozen for %ds",
                user_email, count, FREEZE_DURATION_SEC,
            )
        return count

    @classmethod
    def record_success(cls, user_email: str) -> None:
        if not user_email:
            return
        cls._store.pop(user_email, None)

    @classmethod
    def remaining_freeze_sec(cls, user_email: str) -> int:
        if not user_email:
            return 0
        entry = cls._store.get(user_email)
        if entry is None:
            return 0
        count, frozen_at = entry
        if count < MAX_CONSECUTIVE_FAILURES:
            return 0
        elapsed = time.monotonic() - frozen_at
        remaining = FREEZE_DURATION_SEC - elapsed
        return max(0, int(remaining))
