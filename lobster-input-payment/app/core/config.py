from pydantic_settings import BaseSettings
from pydantic_settings import SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    MONGODB_URI: str = "mongodb://localhost:27017"
    MONGODB_DB_NAME: str = "voice_input"
    PORT: int = 8890
    HOST: str = "0.0.0.0"
    BASE_URL: str = "/lobster/payment"
    COOKIE_SECURE: bool = True
    EXPOSE_API_DOCS: bool = False
    PUBLIC_BASE_URL: str = "https://example.com/lobster/payment"

    # 业务后端内部调用(P3 权益收敛:支付履约改调后端 EntitlementService.grant_paid)
    BACKEND_INTERNAL_URL: str = "http://127.0.0.1:8000"
    BACKEND_INTERNAL_KEY: str = ""  # 与 backend .env 的 API_KEY 一致
    INTERNAL_SIGNATURE_TOLERANCE_SEC: int = 300


settings = Settings()
