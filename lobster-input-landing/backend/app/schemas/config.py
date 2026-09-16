"""客户端启动配置模型（与主后端 AppStartupConfig 字段一致）。"""
from pydantic import BaseModel


class StartupConfig(BaseModel):
    registration_enabled: bool
    invite_code_enabled: bool
    show_invite_codes_enabled: bool
    show_subscription_module_enabled: bool
    registration_limit_enabled: bool
    registration_limit_count: int
