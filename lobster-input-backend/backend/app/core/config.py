"""
全局配置模块。
通过 pydantic-settings 从 .env 文件和环境变量中加载配置，
所有配置项均可通过 settings 单例访问。

设计原则：
  所有 AI 服务（LLM / ASR / Search）的 API Key 统一由号池管理，
  本地配置文件不保存任何 AI 服务 Key，不支持本地降级路径。
  唯一例外：LangWatch 可观测性 Key 不经号池，直接在 .env 中配置。
"""
from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import Literal


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # ── 应用基础 ──────────────────────────────────────────
    app_env: Literal["development", "uat", "preview", "production", "test"] = "development"

    # ── 内部 API 鉴权（仅服务间调用，客户端不得携带）──────────────
    api_key: str = ""
    internal_signature_tolerance_sec: int = 300
    trusted_proxy_cidrs: str = "127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

    # ── 数据库 ────────────────────────────────────────────
    mongodb_uri: str = "mongodb://localhost:27017"
    mongodb_db_name: str = "voice_input"

    # ── JWT 认证 ──────────────────────────────────────────
    jwt_secret_key: str = "change-me-jwt-secret"
    jwt_algorithm: str = "HS256"
    # 失效闸门已移交 active_sessions.{platform}.expires_at 滑动窗口
    # （15 天无活跃即失效，活跃自动续期）；JWT exp 仅作兜底，默认 10 年，保留可配置
    jwt_expire_minutes: int = 60 * 24 * 3650  # 10 年

    # ── 邮件（AokSend HTTP API，发送验证码）──────────────
    aoksend_api_key: str = ""
    aoksend_template_id: str = ""
    aoksend_api_url: str = "https://apiv2.aoksend.com/index/api/send_email"

    # ── 验证码有效期（秒）─────────────────────────────────
    verify_code_ttl: int = 300
    auth_fixed_verify_code_enabled: bool = False
    auth_fixed_verify_code_emails: str = ""
    auth_fixed_verify_code_value: str = ""

    # ── 音频上传 ──────────────────────────────────────────
    audio_max_size_mb: int = 25
    audio_upload_dir: str = "./uploads/audio"
    audio_max_duration_sec: int = 65

    # ── v2 实时 ASR（默认 Qwen-ASR-Realtime，可由 Provider 配置切换）────
    realtime_asr_default_base_url: str = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    realtime_asr_default_model: str = "qwen3-asr-flash-realtime"
    realtime_asr_max_duration_sec: int = 60
    realtime_asr_v2_final_wait_ms: int = 3000

    # ── Whisper 语言（ASR 语言提示，留空=自动检测）────────
    # 不用于指定提供商，仅作为语言 hint 传给 ASR provider
    whisper_language: str = ""

    # ── ASR 用户词典纠偏 ─────────────────────────────────
    # 纠偏只使用用户词典发音索引，不依赖公共词库。
    asr_correction_enabled: bool = True

    # ── 词典（热词）限制 ──────────────────────────────────
    hotword_max_count: int = 2000
    hotword_max_length: int = 20

    # ── API Key 号池（lobster-input-api-manage）─────────
    api_pool_url: str = ""
    api_pool_internal_key: str = ""

    # ── 管理端运行时 Provider 配置 ───────────────────────
    admin_config_url: str = "http://127.0.0.1:8888"
    admin_config_internal_key: str = ""
    provider_config_cache_ttl_sec: int = 600
    # 计费规则/策略进程内 TTL 缓存秒数（消除每请求多次无缓存 system_config 读取）
    credit_pricing_cache_ttl_sec: int = 60
    # ── LangWatch LLM 可观测性 ────────────────────────────
    langwatch_api_key: str = ""
    langwatch_enabled: bool = True
    # 自建 LangWatch 实例地址；留空时默认连接官方云端 app.langwatch.ai
    langwatch_endpoint: str = ""

    # ── Redis（通用队列/缓存）────────────────────────────
    redis_url: str = "redis://localhost:6379/0"


settings = Settings()
