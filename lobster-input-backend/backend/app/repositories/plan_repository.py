"""PlanRepository — 套餐、计费和奖励积分策略配置访问层。"""
import re
import time
from datetime import datetime, timezone
from typing import Any
from app.core.config import settings
from app.core.content_i18n import clean_i18n
from app.core.database import get_db

SYSTEM_CONFIG_COLLECTION = "system_config"

# ── 计费规则/策略进程内 TTL 缓存 ─────────────────────────────
# 计费规则读取热路径（每次 ASR/LLM 请求会多次读 system_config），加进程内 TTL 缓存
# 消除重复无缓存 find_one；set_* 写入后立即失效，保证管理端改规则后及时生效。
# 参考 runtime_provider_config._cache 的 TTL 缓存写法。
_MISS = object()
_pricing_cache: dict[str, tuple[float, Any]] = {}


def _pricing_cache_ttl() -> int:
    return max(1, int(getattr(settings, "credit_pricing_cache_ttl_sec", 60) or 60))


def _pricing_cache_get(key: str):
    entry = _pricing_cache.get(key)
    if entry is not None:
        expires_at, value = entry
        if time.monotonic() < expires_at:
            return value
        _pricing_cache.pop(key, None)
    return _MISS


def _pricing_cache_set(key: str, value) -> None:
    _pricing_cache[key] = (time.monotonic() + _pricing_cache_ttl(), value)


def clear_credit_pricing_cache(*keys: str) -> None:
    """失效计费规则/策略缓存；不传 key 时清空全部（set_* 写入后调用）。"""
    if keys:
        for key in keys:
            _pricing_cache.pop(key, None)
    else:
        _pricing_cache.clear()

DEFAULT_TRIAL_CREDITS = 3000

PLAN_CONFIGS_KEY = "plan_configs"
CREDIT_PRICING_RULES_KEY = "credit_pricing_rules"
CREDIT_PRICING_POLICY_KEY = "credit_pricing_policy"
CREDIT_PROVIDER_COSTS_KEY = "credit_provider_costs"
BONUS_CREDIT_POLICY_KEY = "bonus_credit_policy"

# 计费经济性全局策略（默认值，阈值仅用于毛利监控着色，不做任何保存拦截）。
#   image_surcharge_credits — 含图片请求的每图附加积分（P0：图片输入补计费）
#   margin_target_ratio     — 毛利率监控目标线（≥ 该值为 green，仅监控参考）
#   margin_alert_ratio      — 毛利率告警线（< 该值为 red，仅监控参考）
DEFAULT_CREDIT_PRICING_POLICY = {
    "image_surcharge_credits": 15,
    "margin_target_ratio": 0.75,
    "margin_alert_ratio": 0.30,
}

DEFAULT_PLAN_CONFIGS = {
    "trial": {
        "code": "trial", "name": "免费试用", "enabled": True,
        "credits": 3000, "reset_period": "none", "auto_assign_on_register": True,
        "validity_period": "day", "validity_count": 7,
        "manual_assign_enabled": True, "paid": False, "rank": 0, "sort_order": 10,
        "plan_family": "base", "stackable": False, "self_checkout_enabled": False,
        "auto_renew_supported": False, "paid_topup_enabled": False,
        "lifecycle_status": "active", "trial_once_per_user": True,
        "billing_options": {},
    },
    "free": {
        "code": "free", "name": "免费套餐", "enabled": True,
        "credits": 500, "reset_period": "week", "auto_assign_on_register": False,
        "validity_period": "forever", "validity_count": 0,
        "manual_assign_enabled": True, "paid": False, "rank": 0, "sort_order": 20,
        "plan_family": "base", "stackable": False, "self_checkout_enabled": False,
        "auto_renew_supported": False, "paid_topup_enabled": False,
        "lifecycle_status": "active", "trial_once_per_user": False,
        "billing_options": {},
    },
    "lite": {
        "code": "lite", "name": "轻量套餐", "enabled": True,
        "credits": 9000, "reset_period": "month", "auto_assign_on_register": False,
        "validity_period": "month", "validity_count": 1,
        "manual_assign_enabled": True, "paid": True, "rank": 10, "sort_order": 30,
        "plan_family": "base", "stackable": False, "self_checkout_enabled": True,
        "auto_renew_supported": True, "paid_topup_enabled": True,
        "lifecycle_status": "active", "trial_once_per_user": False,
        "billing_options": {
            "monthly": {"cycle": "monthly", "enabled": True, "duration_period": "month", "duration_count": 1},
            "quarterly": {"cycle": "quarterly", "enabled": True, "duration_period": "month", "duration_count": 3},
            "yearly": {"cycle": "yearly", "enabled": True, "duration_period": "year", "duration_count": 1},
        },
    },
    "standard": {
        "code": "standard", "name": "标准套餐", "enabled": True,
        "credits": 30000, "reset_period": "month", "auto_assign_on_register": False,
        "validity_period": "month", "validity_count": 1,
        "manual_assign_enabled": True, "paid": True, "rank": 20, "sort_order": 40,
        "plan_family": "base", "stackable": False, "self_checkout_enabled": True,
        "auto_renew_supported": True, "paid_topup_enabled": True,
        "lifecycle_status": "active", "trial_once_per_user": False,
        "billing_options": {
            "monthly": {"cycle": "monthly", "enabled": True, "duration_period": "month", "duration_count": 1},
            "quarterly": {"cycle": "quarterly", "enabled": True, "duration_period": "month", "duration_count": 3},
            "yearly": {"cycle": "yearly", "enabled": True, "duration_period": "year", "duration_count": 1},
        },
    },
    "pro": {
        "code": "pro", "name": "专业套餐", "enabled": True,
        "credits": 75000, "reset_period": "month", "auto_assign_on_register": False,
        "validity_period": "month", "validity_count": 1,
        "manual_assign_enabled": True, "paid": True, "rank": 30, "sort_order": 50,
        "plan_family": "base", "stackable": False, "self_checkout_enabled": True,
        "auto_renew_supported": True, "paid_topup_enabled": True,
        "lifecycle_status": "active", "trial_once_per_user": False,
        "billing_options": {
            "monthly": {"cycle": "monthly", "enabled": True, "duration_period": "month", "duration_count": 1},
            "quarterly": {"cycle": "quarterly", "enabled": True, "duration_period": "month", "duration_count": 3},
            "yearly": {"cycle": "yearly", "enabled": True, "duration_period": "year", "duration_count": 1},
        },
    },
}

# 计费规则（阶段A）：按业务节点单一稳定价，与 provider 无关。
#   字段 {node_id, category, unit, credits, enabled}；同一节点无论后台走哪个 provider，
#   用户扣费一致。web_search 为特例，保留 provider_id 维度（联网搜索是整包外部服务、
#   成本差异大且用户可感知），qwen/tavily 各按次单独定价。
# 上游成本已拆到独立成本表 DEFAULT_CREDIT_PROVIDER_COSTS（仅供毛利监控，不参与扣费）。
DEFAULT_CREDIT_PRICING_RULES = [
    {"node_id": "asr_transcribe", "category": "asr",
     "unit": "minute", "credits": 100, "enabled": True},
    {"node_id": "asr_realtime_transcribe", "category": "asr_realtime",
     "unit": "minute", "credits": 100, "enabled": True},
    {"node_id": "llm_transcribe", "category": "llm_chat",
     "unit": "1k_tokens", "credits": 40, "enabled": True},
    {"node_id": "llm_rewrite", "category": "llm_chat",
     "unit": "1k_tokens", "credits": 40, "enabled": True},
    {"node_id": "openclaw_transcribe", "category": "llm_chat",
     "unit": "1k_tokens", "credits": 40, "enabled": True},
    {"node_id": "android_quick_action", "category": "llm_chat",
     "unit": "1k_tokens", "credits": 40, "enabled": True},
    {"node_id": "intent_router", "category": "llm_chat",
     "unit": "1k_tokens", "credits": 20, "enabled": True},
    {"node_id": "web_search", "category": "web_search", "provider_id": "search_qwen",
     "unit": "request", "credits": 250, "enabled": True},
    {"node_id": "web_search", "category": "web_search", "provider_id": "search_tavily",
     "unit": "request", "credits": 300, "enabled": True},
]

# 上游参考成本表（阶段A 新增，独立 system_config key，仅供毛利监控，不参与用户扣费）。
#   字段 {node_id, provider_id, platform_code?, model?, unit, upstream_cost_cny, cost_source, updated_at}
#   每节点可多条（一条一个 provider）。成本口径:按量付费(pay-as-you-go)官方公开单价。
#   ⚠️ 火山若走并发包月且利用率低,等效成本会升高,须在管理端按真实账单改成本。
DEFAULT_CREDIT_PROVIDER_COSTS = [
    # ASR 一次性识别（CNY/min）
    {"node_id": "asr_transcribe", "provider_id": "asr_dashscope",
     "platform_code": "dashscope", "model": "qwen3-asr-flash", "unit": "minute",
     "upstream_cost_cny": 0.0132, "cost_source": "aliyun-qwen3-asr-flash-按量", "updated_at": "2026-07"},
    {"node_id": "asr_transcribe", "provider_id": "asr_volcengine",
     "platform_code": "volcengine", "model": "*", "unit": "minute",
     "upstream_cost_cny": 0.0088, "cost_source": "volcengine-asr-按量", "updated_at": "2026-07"},
    {"node_id": "asr_transcribe", "provider_id": "asr_openai",
     "platform_code": "openai", "model": "*", "unit": "minute",
     "upstream_cost_cny": 0.043, "cost_source": "openai-whisper", "updated_at": "2026-07"},
    {"node_id": "asr_transcribe", "provider_id": "asr_groq",
     "platform_code": "groq", "model": "*", "unit": "minute",
     "upstream_cost_cny": 0.0134, "cost_source": "groq-whisper", "updated_at": "2026-07"},
    # ASR 实时识别（CNY/min）
    {"node_id": "asr_realtime_transcribe", "provider_id": "asr_qwen_realtime",
     "platform_code": "dashscope_realtime", "model": "qwen3-asr-flash-realtime", "unit": "minute",
     "upstream_cost_cny": 0.0132, "cost_source": "aliyun-realtime-asr-按量", "updated_at": "2026-07"},
    {"node_id": "asr_realtime_transcribe", "provider_id": "asr_volcengine_realtime",
     "platform_code": "volcengine_realtime", "model": "volc.seedasr.sauc.duration", "unit": "minute",
     "upstream_cost_cny": 0.0088, "cost_source": "volcengine-seed-asr-realtime-按量", "updated_at": "2026-07"},
    # LLM（CNY/1k_tokens）
    {"node_id": "llm_transcribe", "provider_id": "llm_aliyun",
     "platform_code": "aliyun", "model": "*", "unit": "1k_tokens",
     "upstream_cost_cny": 0.002, "cost_source": "aliyun-qwen-plus", "updated_at": "2026-07"},
    {"node_id": "llm_rewrite", "provider_id": "llm_aliyun",
     "platform_code": "aliyun", "model": "*", "unit": "1k_tokens",
     "upstream_cost_cny": 0.002, "cost_source": "aliyun-qwen-plus", "updated_at": "2026-07"},
    {"node_id": "openclaw_transcribe", "provider_id": "llm_aliyun",
     "platform_code": "aliyun", "model": "*", "unit": "1k_tokens",
     "upstream_cost_cny": 0.002, "cost_source": "aliyun-qwen-plus", "updated_at": "2026-07"},
    {"node_id": "android_quick_action", "provider_id": "llm_aliyun",
     "platform_code": "aliyun", "model": "*", "unit": "1k_tokens",
     "upstream_cost_cny": 0.002, "cost_source": "aliyun-qwen-plus", "updated_at": "2026-07"},
    {"node_id": "intent_router", "provider_id": "llm_aliyun",
     "platform_code": "aliyun", "model": "*", "unit": "1k_tokens",
     "upstream_cost_cny": 0.002, "cost_source": "aliyun-qwen-plus", "updated_at": "2026-07"},
    # 联网搜索（CNY/request）
    {"node_id": "web_search", "provider_id": "search_qwen",
     "platform_code": "aliyun_search", "model": "*", "unit": "request",
     "upstream_cost_cny": 0.004, "cost_source": "aliyun-web-search", "updated_at": "2026-07"},
    {"node_id": "web_search", "provider_id": "search_tavily",
     "platform_code": "tavily", "model": "*", "unit": "request",
     "upstream_cost_cny": 0.058, "cost_source": "tavily-advanced", "updated_at": "2026-07"},
]

DEFAULT_BONUS_CREDIT_POLICY = {
    "registration_reward": {"enabled": False, "credits": 0, "expires_days": 7},
    "invite_reward": {"enabled": False, "credits": 0, "expires_days": 365},
    "admin_grant": {"expires_days": 365},
}

PLAN_CODE_RE = re.compile(r"^[A-Za-z0-9_-]+$")


class PlanRepository:
    """套餐配置仓库，提供积分额度、计费规则和奖励策略读写。"""

    @property
    def col(self):
        return get_db()[SYSTEM_CONFIG_COLLECTION]

    async def get_trial_credits_total(self) -> int:
        """获取试用套餐总积分额度，默认 3000。"""
        return int((await self.get_plan_config("trial")).get("credits", DEFAULT_TRIAL_CREDITS))

    async def set_trial_credits_total(self, credits: int) -> bool:
        """设置试用套餐总积分额度。"""
        plans = await self.get_plan_configs()
        plans.setdefault("trial", dict(DEFAULT_PLAN_CONFIGS["trial"]))
        plans["trial"]["credits"] = credits
        return await self.set_plan_configs(plans)

    async def get_platform_credit_ratio(self) -> dict:
        """获取各平台积分消耗映射，返回默认值若未配置。"""
        return {
            "rules": await self.get_credit_pricing_rules(),
            "policy": await self.get_credit_pricing_policy(),
        }

    async def set_platform_credit_ratio(self, ratio: dict) -> bool:
        """设置各平台积分消耗映射。"""
        if isinstance(ratio, dict) and isinstance(ratio.get("rules"), list):
            return await self.set_credit_pricing_rules(ratio["rules"])
        return False

    async def _get_value(self, key: str, default):
        doc = await self.col.find_one({"key": key})
        value = doc.get("value") if doc else None
        return value if value is not None else default

    async def _set_value(self, key: str, value) -> bool:
        result = await self.col.update_one(
            {"key": key},
            {"$set": {"value": value, "updated_at": datetime.now(timezone.utc)}},
            upsert=True,
        )
        return result.acknowledged

    async def get_plan_configs(self) -> dict:
        value = await self._get_value(PLAN_CONFIGS_KEY, {})
        plans = {k: dict(v) for k, v in DEFAULT_PLAN_CONFIGS.items()}
        if isinstance(value, dict):
            for code, cfg in value.items():
                if isinstance(cfg, dict):
                    code = self._normalize_plan_code(code)
                    if not code or code in {"weekly", "monthly", "yearly"}:
                        continue
                    merged = dict(plans.get(code, {"code": code}))
                    merged.update(cfg)
                    plans[code] = self._clean_plan_config(code, merged)
        return {code: self._clean_plan_config(code, cfg) for code, cfg in plans.items()}

    async def set_plan_configs(self, configs: dict) -> bool:
        cleaned = {}
        for code, cfg in (configs or {}).items():
            code = self._normalize_plan_code(code)
            if not code or not isinstance(cfg, dict) or code in {"weekly", "monthly", "yearly"}:
                continue
            cleaned[code] = self._clean_plan_config(code, cfg)
        return await self._set_value(PLAN_CONFIGS_KEY, cleaned)

    async def ensure_default_system_configs(self) -> None:
        """幂等初始化系统计费配置，并清理误把支付周期当套餐 code 的旧配置。"""
        plans = await self.get_plan_configs()
        await self.set_plan_configs(plans)

        if await self._get_value(CREDIT_PRICING_RULES_KEY, None) is None:
            await self.set_credit_pricing_rules(DEFAULT_CREDIT_PRICING_RULES)
        if await self._get_value(CREDIT_PRICING_POLICY_KEY, None) is None:
            await self.set_credit_pricing_policy(DEFAULT_CREDIT_PRICING_POLICY)
        if await self._get_value(CREDIT_PROVIDER_COSTS_KEY, None) is None:
            await self.set_credit_provider_costs(DEFAULT_CREDIT_PROVIDER_COSTS)
        if await self._get_value(BONUS_CREDIT_POLICY_KEY, None) is None:
            await self.set_bonus_credit_policy(DEFAULT_BONUS_CREDIT_POLICY)
        await self.col.delete_many({"key": {"$in": [
            "platform_credit_ratio",
            "trial_credits_total",
            "registration_reward_enabled",
            "registration_reward_credits",
            "invite_reward_enabled",
            "invite_reward_credits",
            "flow_node_configs",
        ]}})
    async def get_plan_config(self, code: str) -> dict:
        plans = await self.get_plan_configs()
        return plans.get(code) or plans["free"]

    async def get_credit_pricing_rules(self) -> list[dict]:
        cached = _pricing_cache_get(CREDIT_PRICING_RULES_KEY)
        if cached is not _MISS:
            return [dict(rule) for rule in cached]
        value = await self._get_value(CREDIT_PRICING_RULES_KEY, None)
        rules = value if isinstance(value, list) else DEFAULT_CREDIT_PRICING_RULES
        cleaned = self._clean_credit_pricing_rules(rules)
        _pricing_cache_set(CREDIT_PRICING_RULES_KEY, cleaned)
        return [dict(rule) for rule in cleaned]

    async def set_credit_pricing_rules(self, rules: list[dict]) -> bool:
        ok = await self._set_value(CREDIT_PRICING_RULES_KEY, self._clean_credit_pricing_rules(rules))
        clear_credit_pricing_cache(CREDIT_PRICING_RULES_KEY)
        return ok

    async def get_credit_pricing_policy(self) -> dict:
        cached = _pricing_cache_get(CREDIT_PRICING_POLICY_KEY)
        if cached is not _MISS:
            return dict(cached)
        value = await self._get_value(CREDIT_PRICING_POLICY_KEY, None)
        cleaned = self._clean_credit_pricing_policy(value if isinstance(value, dict) else {})
        _pricing_cache_set(CREDIT_PRICING_POLICY_KEY, cleaned)
        return dict(cleaned)

    async def set_credit_pricing_policy(self, policy: dict) -> bool:
        ok = await self._set_value(CREDIT_PRICING_POLICY_KEY, self._clean_credit_pricing_policy(policy))
        clear_credit_pricing_cache(CREDIT_PRICING_POLICY_KEY)
        return ok

    async def get_credit_provider_costs(self) -> list[dict]:
        value = await self._get_value(CREDIT_PROVIDER_COSTS_KEY, None)
        costs = value if isinstance(value, list) else DEFAULT_CREDIT_PROVIDER_COSTS
        return self._clean_credit_provider_costs(costs)

    async def set_credit_provider_costs(self, costs: list[dict]) -> bool:
        return await self._set_value(CREDIT_PROVIDER_COSTS_KEY, self._clean_credit_provider_costs(costs))

    @staticmethod
    def _clean_credit_pricing_policy(policy: dict) -> dict:
        merged = dict(DEFAULT_CREDIT_PRICING_POLICY)
        if isinstance(policy, dict):
            for key, default in DEFAULT_CREDIT_PRICING_POLICY.items():
                if key not in policy or policy[key] is None:
                    continue
                try:
                    if key == "image_surcharge_credits":
                        merged[key] = max(0, int(policy[key]))
                    else:
                        merged[key] = max(0.0, float(policy[key]))
                except (TypeError, ValueError):
                    merged[key] = default
        return merged

    @staticmethod
    def _clean_credit_provider_costs(costs: list[dict]) -> list[dict]:
        """清洗上游参考成本表：按 (node_id, provider_id, unit) 去重，缺 node/provider/cost 跳过。"""
        cleaned = []
        seen = set()
        for cost in costs or []:
            if not isinstance(cost, dict):
                continue
            node_id = (cost.get("node_id") or "").lower()
            provider_id = (cost.get("provider_id") or "").lower()
            unit = (cost.get("unit") or "").lower()
            if not node_id or not provider_id or not unit:
                continue
            try:
                upstream = max(0.0, float(cost.get("upstream_cost_cny")))
            except (TypeError, ValueError):
                continue
            key = (node_id, provider_id, unit)
            if key in seen:
                continue
            seen.add(key)
            cleaned.append({
                "node_id": node_id,
                "provider_id": provider_id,
                "platform_code": (cost.get("platform_code") or "").lower(),
                "model": cost.get("model") or "*",
                "unit": unit,
                "upstream_cost_cny": upstream,
                "cost_source": str(cost.get("cost_source") or ""),
                "updated_at": str(cost.get("updated_at") or ""),
            })
        return cleaned

    def _clean_plan_config(self, code: str, cfg: dict) -> dict:
        row = dict(cfg or {})
        row["code"] = code
        row.pop("duration_period", None)
        row.pop("duration_count", None)
        paid_default = bool(code) and code not in {"trial", "free"}
        paid = bool(row.get("paid", paid_default))
        row["paid"] = paid
        enabled = bool(row.get("enabled", True))
        row["enabled"] = enabled
        row["credits"] = max(0, int(row.get("credits") or 0))
        row["reset_period"] = row.get("reset_period") if row.get("reset_period") in {"none", "week", "month", "year"} else "month"
        row["validity_period"] = row.get("validity_period") if row.get("validity_period") in {"day", "week", "month", "year", "forever"} else ("month" if paid else "forever")
        row["validity_count"] = 0 if row["validity_period"] == "forever" else max(1, int(row.get("validity_count") or 1))
        row["rank"] = int(row.get("rank", 0 if not paid else 10) or 0)
        row["sort_order"] = int(row.get("sort_order", row["rank"]) or 0)
        row["manual_assign_enabled"] = bool(row.get("manual_assign_enabled", True))
        row["auto_assign_on_register"] = bool(row.get("auto_assign_on_register", code == "trial"))
        row["plan_family"] = row.get("plan_family") if row.get("plan_family") in {"base", "addon"} else "base"
        row["stackable"] = bool(row.get("stackable", False))
        row["self_checkout_enabled"] = bool(row.get("self_checkout_enabled", paid))
        row["auto_renew_supported"] = bool(row.get("auto_renew_supported", paid))
        row["paid_topup_enabled"] = bool(row.get("paid_topup_enabled", paid))
        row["trial_once_per_user"] = bool(row.get("trial_once_per_user", code == "trial"))
        lifecycle = (row.get("lifecycle_status") or ("active" if enabled else "archived")).strip().lower()
        row["lifecycle_status"] = lifecycle if lifecycle in {"active", "archived"} else "active"
        # ── 可售性(sale_type,显式枚举取代隐式能力位组合)──────────────
        # system:   free/trial 系统套餐(客户端可见、不可购买、自动发放/兜底)
        # external: 付费可购套餐(客户端可见、可自助购买、可自动续费)
        # internal: 仅管理端发放套餐(catalog 不返回、客户端不可购买、无订单、不续费)
        if code in {"free", "trial"}:
            sale_default = "system"
        elif paid:
            sale_default = "external"
        else:
            sale_default = "internal"
        sale_type = str(row.get("sale_type") or "").strip().lower()
        row["sale_type"] = sale_type if sale_type in {"external", "internal", "system"} else sale_default
        # internal 套餐强制不可自助购买/不可自动续费,只能由管理端 comp 发放
        if row["sale_type"] == "internal":
            row["self_checkout_enabled"] = False
            row["auto_renew_supported"] = False
        # ── 展示文案多语言真源(localized_*),旧单语言 name 迁移到 zh 兜底 ──
        row["localized_names"] = clean_i18n(row.get("localized_names") or ({"zh": row.get("name")} if row.get("name") else {}))
        row["localized_descriptions"] = clean_i18n(row.get("localized_descriptions"))
        row["localized_badges"] = clean_i18n(row.get("localized_badges"))
        row["billing_options"] = self._clean_billing_options(row.get("billing_options") or {})
        return row

    def _normalize_plan_code(self, code: str) -> str:
        value = str(code or "").strip().lower()
        return value if PLAN_CODE_RE.match(value) else ""

    def _clean_credit_pricing_rules(self, rules: list[dict]) -> list[dict]:
        """清洗计费规则：按业务节点单一价，与 provider 无关。

        字段收敛为 {node_id, category, unit, credits, enabled}；web_search 为特例，
        保留 provider_id 维度（qwen/tavily 各按次单独定价）。去重键 (node_id, unit, provider_id)。
        缺失的默认节点自动补齐，保证节点单价始终存在。
        """
        cleaned = []
        seen = set()
        for rule in rules or []:
            if not rule.get("node_id"):
                continue
            node_id = (rule.get("node_id") or "").lower()
            category = (rule.get("category") or "").lower()
            unit = (rule.get("unit") or "").lower()
            provider_id = (rule.get("provider_id") or "").lower()
            if node_id == "embedding_correction" or category == "embedding" or provider_id == "embedding_aliyun":
                continue
            if not category or not unit:
                continue
            row = {
                "node_id": node_id,
                "category": category,
                "unit": unit,
                "credits": max(0, int(rule.get("credits") or 0)),
                "enabled": bool(rule.get("enabled", True)),
            }
            # web_search 保留 provider 维度作为特例；ASR/LLM 一律单节点价（剥离 provider）。
            is_web_search = category == "web_search" or node_id == "web_search"
            if is_web_search and provider_id and provider_id != "*":
                row["provider_id"] = provider_id
            key = (node_id, unit, row.get("provider_id", ""))
            if key in seen:
                continue
            seen.add(key)
            cleaned.append(row)
        for rule in DEFAULT_CREDIT_PRICING_RULES:
            key = (
                (rule.get("node_id") or "").lower(),
                (rule.get("unit") or "").lower(),
                (rule.get("provider_id") or "").lower(),
            )
            if key not in seen:
                cleaned.append(dict(rule))
                seen.add(key)
        return cleaned

    def _clean_billing_options(self, options: dict) -> dict:
        cleaned = {}
        for cycle, option in (options or {}).items():
            if not isinstance(option, dict):
                continue
            duration_period = option.get("duration_period")
            if duration_period not in {"month", "year"}:
                duration_period = "year" if cycle == "yearly" else "month"
            cleaned[cycle] = {
                "cycle": cycle,
                "enabled": bool(option.get("enabled", True)),
                "duration_period": duration_period,
                "duration_count": max(1, int(option.get("duration_count") or 1)),
            }
        return cleaned

    async def get_bonus_credit_policy(self) -> dict:
        value = await self._get_value(BONUS_CREDIT_POLICY_KEY, {})
        policy = {k: dict(v) for k, v in DEFAULT_BONUS_CREDIT_POLICY.items()}
        if isinstance(value, dict):
            for source, cfg in value.items():
                if isinstance(cfg, dict):
                    merged = dict(policy.get(source, {}))
                    merged.update(cfg)
                    merged["expires_days"] = max(1, int(merged.get("expires_days") or 365))
                    policy[source] = merged
        return policy

    async def set_bonus_credit_policy(self, policy: dict) -> bool:
        cleaned = {}
        for source, cfg in (policy or {}).items():
            if isinstance(cfg, dict):
                row = dict(cfg)
                row["expires_days"] = max(1, int(row.get("expires_days") or 365))
                cleaned[source] = row
        return await self._set_value(BONUS_CREDIT_POLICY_KEY, cleaned)

    async def get_invite_code_enabled(self) -> bool:
        """获取邀请码注册开关，默认开启。"""
        doc = await self.col.find_one({"key": "invite_code_enabled"})
        if doc and isinstance(doc.get("value"), bool):
            return doc["value"]
        return True

    async def get_registration_enabled(self) -> bool:
        """获取注册总开关，默认开启。关闭后新用户无法注册。"""
        doc = await self.col.find_one({"key": "registration_enabled"})
        if doc and isinstance(doc.get("value"), bool):
            return doc["value"]
        return True

    async def get_show_invite_codes_enabled(self) -> bool:
        """获取客户端展示邀请码按钮开关，默认关闭。"""
        doc = await self.col.find_one({"key": "show_invite_codes_enabled"})
        if doc and isinstance(doc.get("value"), bool):
            return doc["value"]
        return False

    async def get_show_subscription_module_enabled(self) -> bool:
        """获取客户端订阅模块展示开关，默认开启。"""
        doc = await self.col.find_one({"key": "show_subscription_module_enabled"})
        if doc and isinstance(doc.get("value"), bool):
            return doc["value"]
        return True

    async def get_registration_limit_enabled(self) -> bool:
        """获取注册总人数限制开关，默认关闭。"""
        doc = await self.col.find_one({"key": "registration_limit_enabled"})
        if doc and isinstance(doc.get("value"), bool):
            return doc["value"]
        return False

    async def get_registration_limit_count(self) -> int:
        """获取注册总人数上限，默认 1000。"""
        doc = await self.col.find_one({"key": "registration_limit_count"})
        if doc and isinstance(doc.get("value"), int):
            return doc["value"]
        return 1000

    async def get_current_user_count(self) -> int:
        """获取当前已注册用户总数。"""
        users_col = get_db()["users"]
        return await users_col.count_documents({})

    async def get_registration_reward_enabled(self) -> bool:
        """获取注册积分奖励开关，默认关闭。"""
        policy = await self.get_bonus_credit_policy()
        return bool(policy.get("registration_reward", {}).get("enabled", False))

    async def get_registration_reward_credits(self) -> int:
        """获取注册积分奖励额度，默认 0。"""
        policy = await self.get_bonus_credit_policy()
        return int(policy.get("registration_reward", {}).get("credits", 0))

    async def get_invite_reward_enabled(self) -> bool:
        """获取邀请码注册积分奖励开关，默认关闭。"""
        policy = await self.get_bonus_credit_policy()
        return bool(policy.get("invite_reward", {}).get("enabled", False))

    async def get_invite_reward_credits(self) -> int:
        """获取邀请码注册积分奖励额度，默认 0。"""
        policy = await self.get_bonus_credit_policy()
        return int(policy.get("invite_reward", {}).get("credits", 0))
