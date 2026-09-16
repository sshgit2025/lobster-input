"""客户端配置接口（无需鉴权）。

返回注册开关、邀请码开关、人数上限等，官网据此决定登录/注册界面的展示与
填邀请码交互，与 Mac 客户端 /config/startup 口径一致。
"""
from fastapi import APIRouter

from app.repositories.system_config_repository import SystemConfigRepository
from app.schemas.config import StartupConfig

router = APIRouter(prefix="/api/v1/config", tags=["config"])
config_repo = SystemConfigRepository()


@router.get("/startup", response_model=StartupConfig)
async def get_startup_config():
    return StartupConfig(
        registration_enabled=await config_repo.get_registration_enabled(),
        invite_code_enabled=await config_repo.get_invite_code_enabled(),
        show_invite_codes_enabled=await config_repo.get_show_invite_codes_enabled(),
        show_subscription_module_enabled=await config_repo.get_show_subscription_module_enabled(),
        registration_limit_enabled=await config_repo.get_registration_limit_enabled(),
        registration_limit_count=await config_repo.get_registration_limit_count(),
    )
