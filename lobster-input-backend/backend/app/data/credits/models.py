"""
CreditLedgerEntry — 积分账本单条记录数据结构。

每次请求成功扣减积分后写入一条记录，记录本次请求各平台分别消耗的积分
以及对应的原始消耗指标（tokens / 音频时长 / 搜索次数），方便管理端
在一个页面内同时看到积分账单和消耗明细，无需跨页对比。

集合：credit_ledger
索引：user_email + created_at（按用户时间倒序查询）

breakdown 结构（数组，每个平台一条，同一平台可出现多次）：
  {
    "platform":           "openai_whisper",  # 平台标识
    "credits":            3,                 # 本平台消耗积分
    "input_tokens":       0,
    "output_tokens":      0,
    "audio_duration_sec": 18.5,
    "audio_chars":        120,
    "search_count":       0,
  }
"""
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import List


@dataclass
class BreakdownItem:
    """单平台积分消耗明细。"""
    platform: str
    credits: int
    input_tokens: int = 0
    output_tokens: int = 0
    audio_duration_sec: float = 0.0
    audio_chars: int = 0
    search_count: int = 0

    def to_dict(self) -> dict:
        return {
            "platform": self.platform,
            "credits": self.credits,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "audio_duration_sec": self.audio_duration_sec,
            "audio_chars": self.audio_chars,
            "search_count": self.search_count,
        }


@dataclass
class CreditLedgerEntry:
    """积分账本单条记录，每次请求扣减积分时写入一条。"""
    user_email: str
    operation: str
    client_platform: str
    total_credits: int
    breakdown: List[BreakdownItem] = field(default_factory=list)
    deductions: list = field(default_factory=list)
    idempotency_key: str = ""
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    date: str = ""

    def __post_init__(self):
        if not self.date:
            self.date = self.created_at.strftime("%Y-%m-%d")

    def to_dict(self) -> dict:
        doc = {
            "user_email": self.user_email,
            "date": self.date,
            "operation": self.operation,
            "client_platform": self.client_platform,
            "total_credits": self.total_credits,
            "breakdown": [b.to_dict() for b in self.breakdown],
            "deductions": self.deductions,
            "created_at": self.created_at,
        }
        if self.idempotency_key:
            doc["idempotency_key"] = self.idempotency_key
        return doc
