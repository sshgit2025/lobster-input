"""计费重构阶段A 单测（纯 python，不依赖 mongo/服务）。

覆盖：
  - 计费节点单价匹配：同节点不同 provider 一律同价（ASR/LLM）；web_search 保留 provider 特例。
  - credit_pricing_rules 清洗：ASR/LLM 去掉 provider 维度，web_search 保留 provider_id。
  - credit_provider_costs 成本表清洗/读取。
  - margin_engine.build_margin_report 只读监控（新结构 + 红绿灯着色，不拦截）。
  - 阶段A 已删除线上拦截/校准入口（check_margin_floor / calibrate_credits）。
"""
import asyncio

import pytest

from app.services.billing import margin_engine as me
from app.services.billing.credit_calculator import CreditCalculator
from app.repositories import plan_repository as plan_repo_mod
from app.repositories.plan_repository import (
    PlanRepository,
    DEFAULT_CREDIT_PRICING_RULES,
    DEFAULT_CREDIT_PRICING_POLICY,
    DEFAULT_CREDIT_PROVIDER_COSTS,
)


class _FakeSystemConfigCollection:
    """system_config 集合的内存桩（key/value 文档）。"""

    def __init__(self):
        self.docs = {}

    async def find_one(self, query):
        return self.docs.get(query.get("key"))

    async def update_one(self, query, update, upsert=False):
        key = query.get("key")
        doc = self.docs.setdefault(key, {"key": key})
        doc.update(update.get("$set", {}))

        class _R:
            acknowledged = True
        return _R()

    async def delete_many(self, query):
        pass


def _run(coro):
    return asyncio.run(coro)


class _KeyInfo:
    """轻量 key_info 桩，复刻 credit_calculator 读取的属性。"""

    def __init__(self, **kw):
        self.business_node_id = kw.get("business_node_id", "")
        self.category = kw.get("category", "")
        self.provider_id = kw.get("provider_id", "")
        self.platform_code = kw.get("platform_code", "")
        self.model = kw.get("model", "")
        self.real_input_tokens = kw.get("real_input_tokens")
        self.real_output_tokens = kw.get("real_output_tokens")


def _calc():
    rules = PlanRepository()._clean_credit_pricing_rules(DEFAULT_CREDIT_PRICING_RULES)
    return CreditCalculator({"rules": rules, "policy": dict(DEFAULT_CREDIT_PRICING_POLICY)})


def _plan_prices():
    # lite 月付：¥71.8/9000 ≈ 0.008/积分（毛利最好）
    # pro 年付：¥1450/12/75000 ≈ 0.0016/积分（毛利最差，全局最低售价锚点）
    return [
        {"plan_code": "lite", "cycle": "monthly", "monthly_credits": 9000,
         "monthly_price_cny": 71.8, "credit_sale_price_cny": 71.8 / 9000},
        {"plan_code": "pro", "cycle": "yearly", "monthly_credits": 75000,
         "monthly_price_cny": 1450.0 / 12, "credit_sale_price_cny": (1450.0 / 12) / 75000},
    ]


# --------------------------------------------------------------------------- #
# 节点单价匹配：同节点不同 provider 同价                                         #
# --------------------------------------------------------------------------- #
def test_asr_single_price_provider_agnostic():
    calc = _calc()
    # 同 1 分钟音频，无论 dashscope / volcengine / openai / groq，扣费一律 100。
    for provider in ("asr_dashscope", "asr_volcengine", "asr_openai", "asr_groq", "任意未知provider"):
        ki = _KeyInfo(business_node_id="asr_transcribe", category="asr",
                      provider_id=provider, platform_code=provider)
        assert calc.audio_cost(60.0, ki) == 100


def test_asr_realtime_single_price_provider_agnostic():
    calc = _calc()
    for provider in ("asr_qwen_realtime", "asr_volcengine_realtime"):
        ki = _KeyInfo(business_node_id="asr_realtime_transcribe", category="asr_realtime",
                      provider_id=provider, platform_code=provider)
        assert calc.audio_cost(120.0, ki) == 200  # 2 分钟 × 100


def test_llm_nodes_single_price_provider_agnostic():
    calc = _calc()
    # llm_transcribe / llm_rewrite / openclaw / android_quick_action = 40/1k；intent=20/1k
    for node in ("llm_transcribe", "llm_rewrite", "openclaw_transcribe", "android_quick_action"):
        ki = _KeyInfo(business_node_id=node, category="llm_chat",
                      provider_id="whatever", platform_code="whatever")
        assert calc.token_cost(1000, 0, ki) == 40
    intent = _KeyInfo(business_node_id="intent_router", category="llm_chat", provider_id="x")
    assert calc.token_cost(1000, 0, intent) == 20


def test_web_search_keeps_provider_dimension():
    calc = _calc()
    assert calc.request_cost("web_search", "aliyun_search",
                             node_id="web_search", provider_id="search_qwen") == 250
    assert calc.request_cost("web_search", "tavily",
                             node_id="web_search", provider_id="search_tavily") == 300


# --------------------------------------------------------------------------- #
# credit_pricing_rules 清洗：节点单价、去 provider（ASR/LLM）                     #
# --------------------------------------------------------------------------- #
def test_clean_rules_strips_provider_for_asr_llm():
    cleaned = PlanRepository()._clean_credit_pricing_rules(DEFAULT_CREDIT_PRICING_RULES)
    by_node = {}
    for r in cleaned:
        by_node.setdefault(r["node_id"], []).append(r)
    # ASR/LLM 节点：单条、无 provider_id、字段收敛
    for node in ("asr_transcribe", "asr_realtime_transcribe", "llm_transcribe",
                 "llm_rewrite", "openclaw_transcribe", "android_quick_action", "intent_router"):
        rows = by_node[node]
        assert len(rows) == 1
        assert "provider_id" not in rows[0]
        assert set(rows[0].keys()) == {"node_id", "category", "unit", "credits", "enabled"}
    # web_search：两条，保留 provider_id
    ws = by_node["web_search"]
    assert {r["provider_id"] for r in ws} == {"search_qwen", "search_tavily"}


def test_clean_rules_dedups_and_fills_defaults():
    # 只传一条被改价的 asr_transcribe，其余默认节点应被补齐
    cleaned = PlanRepository()._clean_credit_pricing_rules([
        {"node_id": "asr_transcribe", "category": "asr", "unit": "minute", "credits": 88, "enabled": True},
    ])
    asr = [r for r in cleaned if r["node_id"] == "asr_transcribe"]
    assert len(asr) == 1 and asr[0]["credits"] == 88  # 用户值优先，默认不覆盖
    assert any(r["node_id"] == "intent_router" for r in cleaned)  # 默认补齐


def test_clean_rules_provider_ignored_for_asr():
    # 即便传入带 provider 的 asr 规则，也被折叠为单节点价（provider 维度剥离）
    cleaned = PlanRepository()._clean_credit_pricing_rules([
        {"node_id": "asr_transcribe", "category": "asr", "provider_id": "asr_openai",
         "platform_code": "openai", "unit": "minute", "credits": 100, "enabled": True},
    ])
    asr = [r for r in cleaned if r["node_id"] == "asr_transcribe"]
    assert len(asr) == 1
    assert "provider_id" not in asr[0]


# --------------------------------------------------------------------------- #
# credit_provider_costs 成本表                                                  #
# --------------------------------------------------------------------------- #
def test_clean_provider_costs_shape_and_dedup():
    cleaned = PlanRepository._clean_credit_provider_costs(DEFAULT_CREDIT_PROVIDER_COSTS)
    # 结构字段齐全
    row = cleaned[0]
    assert set(row.keys()) == {
        "node_id", "provider_id", "platform_code", "model", "unit",
        "upstream_cost_cny", "cost_source", "updated_at",
    }
    # 关键成本值
    costs = {(r["node_id"], r["provider_id"]): r["upstream_cost_cny"] for r in cleaned}
    assert costs[("asr_transcribe", "asr_dashscope")] == pytest.approx(0.0132)
    assert costs[("asr_transcribe", "asr_openai")] == pytest.approx(0.043)
    assert costs[("asr_realtime_transcribe", "asr_volcengine_realtime")] == pytest.approx(0.0088)
    assert costs[("web_search", "search_tavily")] == pytest.approx(0.058)
    assert costs[("llm_rewrite", "llm_aliyun")] == pytest.approx(0.002)


def test_clean_provider_costs_skips_invalid():
    cleaned = PlanRepository._clean_credit_provider_costs([
        {"node_id": "", "provider_id": "p", "unit": "minute", "upstream_cost_cny": 1},   # 无 node
        {"node_id": "n", "provider_id": "p", "unit": "minute"},                          # 无 cost
        {"node_id": "n", "provider_id": "p", "unit": "minute", "upstream_cost_cny": 0.01},
        {"node_id": "n", "provider_id": "p", "unit": "minute", "upstream_cost_cny": 0.99},  # 重复键去掉
    ])
    assert len(cleaned) == 1
    assert cleaned[0]["upstream_cost_cny"] == pytest.approx(0.01)


# --------------------------------------------------------------------------- #
# 只读毛利监控看板                                                              #
# --------------------------------------------------------------------------- #
def test_build_margin_report_shape_and_status():
    rules = PlanRepository()._clean_credit_pricing_rules(DEFAULT_CREDIT_PRICING_RULES)
    costs = PlanRepository._clean_credit_provider_costs(DEFAULT_CREDIT_PROVIDER_COSTS)
    report = me.build_margin_report(rules, costs, _plan_prices(), DEFAULT_CREDIT_PRICING_POLICY)

    assert set(report.keys()) == {"nodes", "global_min_credit_sale_price", "policy"}
    assert report["global_min_credit_sale_price"]["plan_code"] == "pro"
    assert report["policy"]["margin_target_ratio"] == 0.75
    assert report["policy"]["margin_alert_ratio"] == 0.30

    nodes = {n["node_id"]: n for n in report["nodes"]}
    # asr 节点：单价 100，多 provider，各带成本/毛利/着色
    asr = nodes["asr_transcribe"]
    assert asr["credits"] == 100
    provs = {p["provider_id"]: p for p in asr["providers"]}
    assert set(provs) == {"asr_dashscope", "asr_volcengine", "asr_openai", "asr_groq"}
    for p in asr["providers"]:
        assert p["status"] in {"green", "yellow", "red"}
        assert p["margin"] is not None
    # dashscope 成本极低 → 高毛利 green
    assert provs["asr_dashscope"]["status"] == "green"
    # web_search 走 provider 特例价：qwen 用 250、tavily 用 300
    ws = {p["provider_id"]: p for p in nodes["web_search"]["providers"]}
    assert ws["search_qwen"]["credits"] == 250
    assert ws["search_tavily"]["credits"] == 300


def test_margin_report_red_when_cost_exceeds_revenue():
    # 人为把某 provider 成本抬到远超收入，验证 red 着色（只监控、不拦截）
    rules = [{"node_id": "asr_transcribe", "category": "asr", "unit": "minute",
              "credits": 100, "enabled": True}]
    costs = [{"node_id": "asr_transcribe", "provider_id": "asr_expensive",
              "unit": "minute", "upstream_cost_cny": 5.0}]
    report = me.build_margin_report(rules, costs, _plan_prices(), DEFAULT_CREDIT_PRICING_POLICY)
    prov = report["nodes"][0]["providers"][0]
    assert prov["status"] == "red"
    assert prov["margin"] < 0.30


def test_margin_status_thresholds():
    assert me._margin_status(0.80, 0.75, 0.30) == "green"
    assert me._margin_status(0.50, 0.75, 0.30) == "yellow"
    assert me._margin_status(0.10, 0.75, 0.30) == "red"
    assert me._margin_status(None, 0.75, 0.30) == "unknown"


# --------------------------------------------------------------------------- #
# 阶段A：删除线上拦截/校准                                                       #
# --------------------------------------------------------------------------- #
def test_interception_and_calibration_removed():
    # 保存不再做地板拦截、无反算入口——相关函数已从 margin_engine 移除。
    assert not hasattr(me, "check_margin_floor")
    assert not hasattr(me, "calibrate_credits")
    assert not hasattr(me, "build_margin_matrix")


# --------------------------------------------------------------------------- #
# assemble_plan_prices（保留能力，从套餐配置 + 支付端目录组装）                   #
# --------------------------------------------------------------------------- #
def test_assemble_plan_prices_usd_conversion_and_term():
    plan_configs = {
        "pro": {
            "credits": 75000,
            "billing_options": {
                "yearly": {"enabled": True, "duration_period": "year", "duration_count": 1},
            },
        },
    }
    products = {"pro:yearly": {"price_cents": 20000, "currency": "USD"}}
    prices = me.assemble_plan_prices(plan_configs, products, cny_per_usd=7.25)
    assert len(prices) == 1
    p = prices[0]
    assert p["plan_code"] == "pro" and p["cycle"] == "yearly"
    assert p["term_months"] == 12
    assert p["price_cny"] == pytest.approx(200 * 7.25, abs=1e-6)
    assert p["credit_sale_price_cny"] == pytest.approx((200 * 7.25 / 12) / 75000, abs=1e-9)


def test_global_min_credit_sale_price():
    best = me.global_min_credit_sale_price(_plan_prices())
    assert best["plan_code"] == "pro" and best["cycle"] == "yearly"


# --------------------------------------------------------------------------- #
# 仓库读写往返（内存桩 DB）：成本表读取 + 保存不拦截                              #
# --------------------------------------------------------------------------- #
def test_provider_costs_repo_roundtrip(monkeypatch):
    fake = _FakeSystemConfigCollection()
    monkeypatch.setattr(plan_repo_mod, "get_db", lambda: {"system_config": fake})
    repo = PlanRepository()
    assert _run(repo.set_credit_provider_costs(DEFAULT_CREDIT_PROVIDER_COSTS)) is True
    got = _run(repo.get_credit_provider_costs())
    costs = {(r["node_id"], r["provider_id"]): r["upstream_cost_cny"] for r in got}
    assert costs[("asr_transcribe", "asr_openai")] == pytest.approx(0.043)
    assert costs[("web_search", "search_qwen")] == pytest.approx(0.004)


def test_save_billing_rules_no_interception(monkeypatch):
    # 即便某节点单价低到毛利倒挂，也能原样落库——保存层不再做任何地板拦截。
    fake = _FakeSystemConfigCollection()
    monkeypatch.setattr(plan_repo_mod, "get_db", lambda: {"system_config": fake})
    repo = PlanRepository()
    saved = _run(repo.set_credit_pricing_rules([
        {"node_id": "asr_transcribe", "category": "asr", "unit": "minute", "credits": 1, "enabled": True},
    ]))
    assert saved is True
    rules = _run(repo.get_credit_pricing_rules())
    asr = [r for r in rules if r["node_id"] == "asr_transcribe"]
    assert len(asr) == 1 and asr[0]["credits"] == 1  # 极低单价照样保存，无拦截


def test_policy_repo_roundtrip_simplified_keys(monkeypatch):
    fake = _FakeSystemConfigCollection()
    monkeypatch.setattr(plan_repo_mod, "get_db", lambda: {"system_config": fake})
    repo = PlanRepository()
    _run(repo.set_credit_pricing_policy(
        {"image_surcharge_credits": 20, "margin_target_ratio": 0.8, "margin_alert_ratio": 0.25}))
    policy = _run(repo.get_credit_pricing_policy())
    assert set(policy.keys()) == {"image_surcharge_credits", "margin_target_ratio", "margin_alert_ratio"}
    assert policy["image_surcharge_credits"] == 20
    assert policy["margin_target_ratio"] == pytest.approx(0.8)
