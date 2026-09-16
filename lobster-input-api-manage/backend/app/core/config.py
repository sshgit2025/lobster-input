from pydantic import Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    MONGODB_URI: str = "mongodb://localhost:27017"
    MONGODB_DB_NAME: str = "lobster_api_pool"
    ADMIN_USERNAME: str = "admin"
    SECRET_KEY: str = Field(min_length=32)
    # 与管理后台区分，避免同 host 下 Cookie 名冲突互相顶掉登录态
    AUTH_COOKIE_NAME: str = "lobster_api_manage_access"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 480
    PORT: int = 8889
    HOST: str = "0.0.0.0"
    BASE_URL: str = ""
    INTERNAL_API_KEY: str = "change-me-internal-api-key"
    INTERNAL_SIGNATURE_TOLERANCE_SEC: int = 300
    COOKIE_SECURE: bool = True
    EXPOSE_API_DOCS: bool = False
    SEED_DEFAULT_CATALOG: bool = False

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
