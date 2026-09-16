from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.api.v1.deps import get_config_repo, get_current_admin, get_main_db
from app.repositories.config_repository import ConfigRepository

router = APIRouter(prefix="/api/v1/config", tags=["config"])

OBSOLETE_CONFIG_KEYS = {
    "platform_credit_ratio",
    "trial_credits_total",
    "registration_reward_enabled",
    "registration_reward_credits",
    "invite_reward_enabled",
    "invite_reward_credits",
    "flow_node_configs",
}

SYSTEM_SETTING_DEFS = [
    {
        "key": "registration_enabled",
        "label": "开放注册",
        "type": "bool",
        "default": True,
        "description": "关闭后新用户无法注册，后端返回 REGISTRATION_DISABLED；老用户仍可登录。",
    },
    {
        "key": "invite_code_enabled",
        "label": "邀请码注册",
        "type": "bool",
        "default": True,
        "description": "开启后新用户注册必须填写有效邀请码。",
    },
    {
        "key": "show_invite_codes_enabled",
        "label": "客户端展示邀请码",
        "type": "bool",
        "default": False,
        "description": "开启后已登录用户可以在客户端账号面板查看自己的邀请码。",
    },
    {
        "key": "show_subscription_module_enabled",
        "label": "客户端展示订阅模块",
        "type": "bool",
        "default": True,
        "description": "开启后客户端设置页展示套餐订阅入口；关闭后客户端隐藏订阅和积分加购入口。",
    },
    {
        "key": "registration_limit_enabled",
        "label": "注册总人数上限",
        "type": "bool",
        "default": False,
        "description": "开启后达到注册人数上限时拒绝新注册。",
    },
    {
        "key": "registration_limit_count",
        "label": "注册人数上限值",
        "type": "int",
        "default": 1000,
        "min": 1,
        "max": 100000000,
        "description": "registration_limit_enabled 开启时生效。",
    },
    {
        "key": "max_accounts_per_device",
        "label": "单设备注册账号上限",
        "type": "int",
        "default": 3,
        "min": 1,
        "max": 50,
        "description": "同一设备/IP/硬件指纹任一维度达到该上限时触发联动封禁。",
    },
]

class SetConfigRequest(BaseModel):
    key: str
    value: Any


class SystemSettingsRequest(BaseModel):
    settings: dict[str, Any]


@router.get("/system-settings")
async def get_system_settings(_: str = Depends(get_current_admin)):
    await _cleanup_obsolete_configs()
    db = get_main_db()
    values = {}
    for item in SYSTEM_SETTING_DEFS:
        doc = await db["system_config"].find_one({"key": item["key"]})
        values[item["key"]] = _clean_setting_value(item, doc.get("value") if doc else item["default"])
    return {"definitions": SYSTEM_SETTING_DEFS, "values": values}


@router.post("/system-settings")
async def save_system_settings(data: SystemSettingsRequest, _: str = Depends(get_current_admin)):
    db = get_main_db()
    definitions = {item["key"]: item for item in SYSTEM_SETTING_DEFS}
    now = datetime.now(timezone.utc)
    for key, value in (data.settings or {}).items():
        definition = definitions.get(key)
        if not definition:
            raise HTTPException(status_code=400, detail=f"不支持的系统配置项: {key}")
        cleaned = _clean_setting_value(definition, value)
        await db["system_config"].update_one(
            {"key": key},
            {"$set": {"value": cleaned, "updated_at": now}},
            upsert=True,
        )
    await _cleanup_obsolete_configs()
    return {"message": "系统配置已保存"}


@router.post("/cleanup-obsolete")
async def cleanup_obsolete(_: str = Depends(get_current_admin)):
    deleted = await _cleanup_obsolete_configs()
    return {"deleted": deleted}


# 已删除裸键值配置端点 GET/POST/DELETE /config/system(计费重构安全收口):
# 它们可读/写任意 system_config key(含 plan_configs、payment_billing_config、内部密钥明文),
# 是绕过"套餐/计费配置单一入口"的后门,会重新制造被消除的双真源,且前端/模板均无调用方。
# 系统配置统一走 /config/system-settings(白名单键)+ /config/cleanup-obsolete。


def _clean_setting_value(definition: dict[str, Any], value: Any):
    if definition["type"] == "bool":
        return bool(value)
    if definition["type"] == "int":
        try:
            number = int(value)
        except Exception:
            number = int(definition["default"])
        if "min" in definition:
            number = max(int(definition["min"]), number)
        if "max" in definition:
            number = min(int(definition["max"]), number)
        return number
    return value


async def _cleanup_obsolete_configs() -> int:
    result = await get_main_db()["system_config"].delete_many({"key": {"$in": list(OBSOLETE_CONFIG_KEYS)}})
    return int(result.deleted_count or 0)
