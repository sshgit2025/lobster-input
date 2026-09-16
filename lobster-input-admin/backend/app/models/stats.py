from pydantic import BaseModel
from typing import Optional, List


class UsageStatItem(BaseModel):
    user_email: str
    date: str
    platform: str
    operation: str
    api_key_hint: Optional[str] = None
    input_tokens: int = 0
    output_tokens: int = 0
    audio_duration_sec: float = 0
    audio_chars: int = 0
    search_count: int = 0
    request_count: int = 0
    latency_ms: int = 0


class UsageSummary(BaseModel):
    total_users: int
    total_requests: int
    total_input_tokens: int
    total_output_tokens: int
    total_audio_duration_sec: float
    total_search_count: int


class DailyStatItem(BaseModel):
    date: str
    request_count: int
    input_tokens: int
    output_tokens: int


class PaginatedStats(BaseModel):
    total: int
    page: int
    page_size: int
    items: List[UsageStatItem]
