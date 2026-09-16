from pydantic import Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    MONGODB_URI: str = "mongodb://localhost:27017"
    MONGODB_DB_NAME: str = "voice_input"
    ADMIN_DB_NAME: str = "lobster_admin"
    ADMIN_USERNAME: str = "admin"
    SECRET_KEY: str = Field(min_length=32)
    # 与号池管理端区分，避免同 host（如 localhost）下 Cookie 按域名共享导致互相覆盖
    AUTH_COOKIE_NAME: str = "lobster_admin_access"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 480
    PORT: int = 8888
    HOST: str = "0.0.0.0"
    BASE_URL: str = ""
    BACKEND_URL: str = "http://127.0.0.1:8000"
    BACKEND_API_KEY: str = ""
    API_POOL_URL: str = "http://127.0.0.1:8889"
    API_POOL_INTERNAL_KEY: str = ""
    PROVIDER_CONFIG_INTERNAL_KEY: str = ""
    # 内部告警写入密钥（备份脚本等内部服务调用）
    ALERT_INTERNAL_KEY: str = "lobster-alert-internal-key-change-me"
    COOKIE_SECURE: bool = True
    EXPOSE_API_DOCS: bool = False

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
