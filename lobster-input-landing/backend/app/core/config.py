"""
官网后端全局配置。

官网后端是独立服务（参照管理端 lobster-input-admin/backend 的模式），
与主后端共享同一个 MongoDB（voice_input 库），但自己签发、自己校验
独立的网页登录态 JWT（lobster_site_token Cookie），不依赖也不改动主后端的
单平台单设备会话体系。
"""
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # ── 监听 ──────────────────────────────────────────────
    PORT: int = 8891
    HOST: str = "0.0.0.0"
    # 对外公共前缀（Nginx rewrite 掉），仅用于文档/参考
    BASE_URL: str = "/lobster/site"

    # ── 共享主库 ──────────────────────────────────────────
    MONGODB_URI: str = "mongodb://localhost:27017"
    MONGODB_DB_NAME: str = "voice_input"

    # ── 官网独立会话 JWT ──────────────────────────────────
    SITE_JWT_SECRET: str = Field(min_length=32)
    SITE_JWT_ALGORITHM: str = "HS256"
    SITE_JWT_EXPIRE_MINUTES: int = 60 * 24 * 7  # 7 天
    AUTH_COOKIE_NAME: str = "lobster_site_token"
    COOKIE_SECURE: bool = True
    COOKIE_PATH: str = "/"

    # ── 主后端（仅代理发送验证码，复用真实邮件与频率限制）──
    BACKEND_URL: str = "http://127.0.0.1:8000"

    # ── 可信代理（从 X-Forwarded-For 还原真实客户端 IP）──
    TRUSTED_PROXY_CIDRS: str = "127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

    EXPOSE_API_DOCS: bool = False


settings = Settings()
