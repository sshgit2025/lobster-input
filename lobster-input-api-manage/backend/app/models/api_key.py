"""
API Key 号池数据模型。

新架构分三层：
  Platform — 业务平台目录，例如 aliyun / groq / tavily。号池端动态维护，
             管理端通过内部接口读取目录，因此新增平台不需要改管理端代码。
  Group    — 负载均衡分组。一个 provider 在管理端只绑定一个 group_id，
             该分组内的多把 Key 由号池按权重、优先级、额度和状态调度。
  Key      — 真实密钥。Key 只归属一个 Group，继承所属 Platform 的分类和默认模型配置。

分类 category（可扩展）:
  asr          — 语音识别
  asr_realtime — 实时语音识别
  llm_chat     — LLM 文本对话
  web_search   — 联网搜索
  embedding    — 向量 Embedding
  tts          — 音频合成（未来扩展示例）

状态机设计（6种状态）:
  active      — 正常服务中，可被负载均衡分发
  cooldown    — 冷却中（触发限频后自动进入，冷却结束自动恢复 active）
  exhausted   — 额度耗尽（任一开启的额度维度用尽即进入此状态）
  disabled    — 手动禁用（管理员手动禁用，需手动恢复）
  error       — 异常（调用端上报频繁错误后自动置为此状态）
  expired     — 已过期（超过 expires_at 时间）

额度维度（3种，可任选1种或多种同时生效）:
  token_quota     — Token 额度（适用于按 Token 计费的平台如 OpenAI）
  seconds_quota   — 秒数额度（适用于按音频时长计费的平台如 Groq Whisper）
  requests_quota  — 请求次数额度（适用于按次计费的平台如 Tavily）

负载均衡权重:
  weight — 权重值，0 表示不参与负载均衡，数值越大被选中概率越高
  默认权重为 10，调节范围 0~100

优先级:
  priority — 数值越小优先级越高，同优先级按权重分发
  默认优先级为 0（最高），可设置 0~99
"""
from datetime import datetime
from typing import Optional, List
from enum import Enum
from pydantic import BaseModel, Field


class KeyStatus(str, Enum):
    active = "active"
    cooldown = "cooldown"
    exhausted = "exhausted"
    disabled = "disabled"
    error = "error"
    expired = "expired"


class QuotaConfig(BaseModel):
    """
    单个额度维度的配置（含自动重置策略）。

    auto_reset_period 枚举:
      none    — 不自动重置（默认）
      daily   — 每天 UTC 00:00 重置
      weekly  — 每周一 UTC 00:00 重置
      monthly — 每月 1 日 UTC 00:00 重置
    """
    enabled: bool = False
    total: float = 0
    used: float = 0
    auto_reset_period: str = "none"   # none / daily / weekly / monthly
    last_reset_at: Optional[datetime] = None

    @property
    def remaining(self) -> float:
        return max(0, self.total - self.used)

    @property
    def is_exhausted(self) -> bool:
        return self.enabled and self.remaining <= 0


class ProxyConfig(BaseModel):
    """API Key 专属代理配置。proxy_url 形如 http://host:port。"""
    enabled: bool = False
    proxy_url: str = ""
    username: str = ""
    password: str = ""


class ApiPlatformRecord(BaseModel):
    """号池端可被管理端实时感知的业务平台目录。"""
    code: str
    category: str
    name: str = ""
    description: str = ""
    default_base_url: str = ""
    default_model: str = ""
    default_extra_config: dict = Field(default_factory=dict)
    enabled: bool = True
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None


class ApiKeyGroupRecord(BaseModel):
    """同一平台下用于负载均衡的一组 API Key。"""
    group_id: str
    platform_code: str
    category: str
    name: str = ""
    description: str = ""
    enabled: bool = True
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None


class ApiKeyRecord(BaseModel):
    """
    号池中的一条 API Key 记录。

    Key 不再直接参与 provider 绑定。管理端绑定 provider -> group_id，
    后端运行时只向号池请求 group_id，号池在组内完成负载均衡。
    """
    group_id: str
    platform_code: str
    category: str
    api_key: str
    name: str = ""
    description: str = ""

    status: KeyStatus = KeyStatus.active
    status_reason: str = ""
    status_updated_at: Optional[datetime] = None

    token_quota: QuotaConfig = Field(default_factory=QuotaConfig)
    seconds_quota: QuotaConfig = Field(default_factory=QuotaConfig)
    requests_quota: QuotaConfig = Field(default_factory=QuotaConfig)

    weight: int = Field(default=10, ge=0, le=100)
    priority: int = Field(default=0, ge=0, le=99)

    base_url: str = ""
    model: str = ""
    extra_config: dict = Field(default_factory=dict)
    proxy_config: ProxyConfig = Field(default_factory=ProxyConfig)

    cooldown_until: Optional[datetime] = None
    cooldown_seconds: int = Field(default=60, ge=0)
    expires_at: Optional[datetime] = None

    error_count: int = 0
    error_threshold: int = Field(default=30, ge=30)
    last_error_at: Optional[datetime] = None
    last_used_at: Optional[datetime] = None
    total_requests: int = 0

    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None


class UsageRecord(BaseModel):
    """单次 API Key 消费记录。"""
    group_id: str = ""
    category: str = ""
    platform_code: str = ""
    api_key_id: str
    api_key_hint: str = ""

    tokens_used: float = 0
    seconds_used: float = 0
    requests_used: int = 1

    operation: str = ""
    user_email: str = ""
    latency_ms: int = 0
    success: bool = True
    error_message: str = ""
    client_platform: str = ""

    created_at: Optional[datetime] = None
