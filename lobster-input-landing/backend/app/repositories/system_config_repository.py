"""SystemConfigRepository — 读取共享主库 system_config 集合。

官网的注册/邀请码/人数上限等开关，以及套餐配置、奖励积分策略，全部来自
主库 system_config（管理端直接写入这里，是配置的"真相源"）。本仓库的默认值
与读取逻辑与主后端 app/repositories/plan_repository.py 保持一致，保证官网行为
与客户端口径相同。
"""
from app.core.database import get_db

COLLECTION = "system_config"
USERS_COLLECTION = "users"

PLAN_CONFIGS_KEY = "plan_configs"
BONUS_CREDIT_POLICY_KEY = "bonus_credit_policy"

# 与主后端 plan_repository.DEFAULT_PLAN_CONFIGS 对齐（官网注册初始化套餐用）
DEFAULT_PLAN_CONFIGS = {
    "trial": {
        "code": "trial", "name": "免费试用", "enabled": True,
        "credits": 3000, "reset_period": "month", "auto_assign_on_register": True,
        "validity_period": "day", "validity_count": 7, "paid": False,
    },
    "free": {
        "code": "free", "name": "免费套餐", "enabled": True,
        "credits": 500, "reset_period": "week", "auto_assign_on_register": False,
        "validity_period": "forever", "validity_count": 0, "paid": False,
    },
    "lite": {
        "code": "lite", "name": "轻量套餐", "enabled": True,
        "credits": 9000, "reset_period": "month", "auto_assign_on_register": False,
        "validity_period": "month", "validity_count": 1, "paid": True,
    },
    "standard": {
        "code": "standard", "name": "标准套餐", "enabled": True,
        "credits": 30000, "reset_period": "month", "auto_assign_on_register": False,
        "validity_period": "month", "validity_count": 1, "paid": True,
    },
    "pro": {
        "code": "pro", "name": "专业套餐", "enabled": True,
        "credits": 75000, "reset_period": "month", "auto_assign_on_register": False,
        "validity_period": "month", "validity_count": 1, "paid": True,
    },
}

DEFAULT_BONUS_CREDIT_POLICY = {
    "registration_reward": {"enabled": False, "credits": 0, "expires_days": 7},
    "invite_reward": {"enabled": False, "credits": 0, "expires_days": 365},
    "admin_grant": {"expires_days": 365},
}

_RESET_PERIODS = {"week", "month", "year"}
_VALIDITY_PERIODS = {"day", "week", "month", "year", "forever"}


class SystemConfigRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def _bool(self, key: str, default: bool) -> bool:
        doc = await self.col.find_one({"key": key})
        if doc and isinstance(doc.get("value"), bool):
            return doc["value"]
        return default

    async def _int(self, key: str, default: int) -> int:
        doc = await self.col.find_one({"key": key})
        if doc and isinstance(doc.get("value"), int):
            return doc["value"]
        return default

    # ── 注册/邀请/订阅相关开关（默认值与主后端一致）──────────
    async def get_invite_code_enabled(self) -> bool:
        return await self._bool("invite_code_enabled", True)

    async def get_registration_enabled(self) -> bool:
        return await self._bool("registration_enabled", True)

    async def get_show_invite_codes_enabled(self) -> bool:
        return await self._bool("show_invite_codes_enabled", False)

    async def get_show_subscription_module_enabled(self) -> bool:
        return await self._bool("show_subscription_module_enabled", True)

    async def get_registration_limit_enabled(self) -> bool:
        return await self._bool("registration_limit_enabled", False)

    async def get_registration_limit_count(self) -> int:
        return await self._int("registration_limit_count", 1000)

    async def get_max_accounts_per_device(self) -> int:
        return await self._int("max_accounts_per_device", 3)

    async def get_current_user_count(self) -> int:
        return await get_db()[USERS_COLLECTION].count_documents({})

    # ── 套餐配置 ──────────────────────────────────────────
    async def _raw_value(self, key: str):
        doc = await self.col.find_one({"key": key})
        return doc.get("value") if doc else None

    async def get_plan_config(self, code: str) -> dict:
        """读取指定套餐配置：存储覆盖叠加在默认之上，并对关键字段做与主后端一致的归一。"""
        value = await self._raw_value(PLAN_CONFIGS_KEY)
        plans = {k: dict(v) for k, v in DEFAULT_PLAN_CONFIGS.items()}
        if isinstance(value, dict):
            for c, cfg in value.items():
                if isinstance(cfg, dict):
                    merged = dict(plans.get(c, {"code": c}))
                    merged.update(cfg)
                    plans[c] = merged
        cfg = plans.get(code) or plans.get("free") or DEFAULT_PLAN_CONFIGS["free"]
        return self._coerce_plan(code if code in plans else cfg.get("code", "free"), cfg)

    @staticmethod
    def _coerce_plan(code: str, cfg: dict) -> dict:
        row = dict(cfg or {})
        row["code"] = code
        paid = bool(row.get("paid", code not in {"trial", "free"}))
        row["paid"] = paid
        row["credits"] = max(0, int(row.get("credits") or 0))
        row["reset_period"] = row.get("reset_period") if row.get("reset_period") in _RESET_PERIODS else "month"
        vp = row.get("validity_period")
        row["validity_period"] = vp if vp in _VALIDITY_PERIODS else ("month" if paid else "forever")
        row["validity_count"] = 0 if row["validity_period"] == "forever" else max(1, int(row.get("validity_count") or 1))
        return row

    async def get_bonus_credit_policy(self) -> dict:
        value = await self._raw_value(BONUS_CREDIT_POLICY_KEY)
        policy = {k: dict(v) for k, v in DEFAULT_BONUS_CREDIT_POLICY.items()}
        if isinstance(value, dict):
            for source, cfg in value.items():
                if isinstance(cfg, dict):
                    merged = dict(policy.get(source, {}))
                    merged.update(cfg)
                    merged["expires_days"] = max(1, int(merged.get("expires_days") or 365))
                    policy[source] = merged
        return policy
