"""
UsageEvent — 用量统计统一数据结构。

所有平台（OpenAI LLM / Groq LLM / Whisper / Tavily）的用量指标
均转换为此统一数据类，再投递到异步队列持久化。

platform 取值约定：
  "openai_llm"     — OpenAI LLM 调用
  "groq_llm"       — Groq LLM 调用
  "openai_whisper" — OpenAI Whisper 语音识别
  "groq_whisper"   — Groq Whisper 语音识别
  "tavily"         — Tavily 搜索引擎

operation 取值约定：
  "transcribe"       — 语音转文字主流程
  "rewrite"          — 改写选中文本
  "agent"            — Agent 智能操作
  "intent_classify"  — Agent 意图分类（IntentRouter）
  "search_optimize"  — 搜索 query 优化（SearchNode）
  "search_summarize" — 搜索结果整理（SearchNode）
  "search"           — Tavily 搜索调用

client_platform 取值约定（来自请求头 X-Client-Platform）：
  "macos_standard" — macOS 标准版客户端
  "macos_diy"      — macOS DIY 定制版客户端
  "ios"            — iOS 客户端（预留）
  ""               — 未知/未传（旧版客户端兼容）

api_key_hint 说明：
  记录本次调用使用的 API Key 脱敏标识，格式为前8位 + "****"，例如 "sk-abc123****"。
  用于号池负载均衡分析：结合调用次数、token 消耗、延迟等指标，
  评估不同 key 的使用频率和健康状态，为后续 key 轮换策略提供数据支撑。
"""
from dataclasses import dataclass


@dataclass
class UsageEvent:
    """用量统计事件，由各平台提取器生成，投递到异步队列。"""

    user_email: str
    platform: str
    operation: str
    date: str

    input_tokens: int = 0
    output_tokens: int = 0
    audio_duration_sec: float = 0.0
    audio_chars: int = 0
    search_count: int = 0
    request_count: int = 1
    latency_ms: int = 0
    api_key_hint: str = ""
    client_platform: str = ""
