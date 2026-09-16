"""
margin_engine — 计费经济性（毛利率）只读监控引擎（阶段A）。

纯计算模块，不触碰数据库/网络：所有输入（计费节点单价 + 各 provider 参考成本 +
各套餐每积分售价 + 策略阈值）由调用方（admin API）组装后传入，便于纯 python 单测。

阶段A 定位：**只读监控，绝不拦截任何配置、绝不影响用户扣费**。
  - 计费单价（credit_pricing_rules）按业务节点单一价，与 provider 无关（web_search 例外）。
  - 上游成本（credit_provider_costs）拆为独立成本表，仅供此处计算毛利着色。
  - 阈值（margin_target_ratio / margin_alert_ratio）仅用于红绿灯着色，不做保存拦截。

术语：
  credit_sale_price_cny — 每 1 积分的售价（人民币）= 套餐月均价 / 套餐每月积分额度。
  margin（毛利率）       — 1 − cost /(credits × 全局最低每积分售价)。
"""
import math

DEFAULT_TARGET_RATIO = 0.75
DEFAULT_ALERT_RATIO = 0.30
DEFAULT_CNY_PER_USD = 7.25

# billing cycle -> 覆盖月数，用于把整期价格摊回月均价
CYCLE_MONTHS = {"monthly": 1, "quarterly": 3, "yearly": 12}


# --------------------------------------------------------------------------- #
# 组装：从套餐配置 + 支付端商品目录得到「每套餐每积分售价」列表                  #
# --------------------------------------------------------------------------- #
def _to_cny(amount: float, currency: str, cny_per_usd: float) -> float:
    cur = (currency or "").strip().upper()
    if cur in ("", "CNY", "RMB"):
        return float(amount)
    if cur == "USD":
        return float(amount) * float(cny_per_usd)
    # 其它币种未知，按原值处理（视为已折算），避免误算
    return float(amount)


def _term_months(duration_period: str, duration_count, cycle: str) -> int:
    if duration_period in ("month", "year") and duration_count:
        try:
            months = int(duration_count)
        except (TypeError, ValueError):
            months = 1
        return max(1, months * (12 if duration_period == "year" else 1))
    return CYCLE_MONTHS.get((cycle or "").lower(), 1)


def assemble_plan_prices(
    plan_configs: dict,
    subscription_products: dict,
    *,
    cny_per_usd: float = DEFAULT_CNY_PER_USD,
) -> list[dict]:
    """
    组装每套餐×账期的每积分售价。

    plan_configs           — PlanRepository.get_plan_configs() 结果（含 credits + billing_options）
    subscription_products  — 支付端目录 subscription_products，key 形如 "pro:yearly"，
                             value 含 price_cents / currency（优先支付端，回退 plan_configs 额度）
    """
    prices: list[dict] = []
    products = subscription_products or {}
    for code, plan in (plan_configs or {}).items():
        if not isinstance(plan, dict):
            continue
        monthly_credits = int(plan.get("credits") or 0)
        if monthly_credits <= 0:
            continue
        for cycle, option in (plan.get("billing_options") or {}).items():
            if not isinstance(option, dict) or option.get("enabled") is False:
                continue
            product = products.get(f"{code}:{cycle}".lower()) or {}
            price_cents = int(product.get("price_cents") or 0)
            if price_cents <= 0:
                continue
            price_cny = _to_cny(price_cents / 100.0, product.get("currency") or "USD", cny_per_usd)
            months = _term_months(option.get("duration_period"), option.get("duration_count"), cycle)
            monthly_price = price_cny / months
            sale_price = monthly_price / monthly_credits if monthly_credits else 0.0
            prices.append({
                "plan_code": code,
                "cycle": cycle,
                "price_cny": round(price_cny, 4),
                "term_months": months,
                "monthly_price_cny": round(monthly_price, 4),
                "monthly_credits": monthly_credits,
                "credit_sale_price_cny": sale_price,
            })
    return prices


# --------------------------------------------------------------------------- #
# 每积分售价表                                                                  #
# --------------------------------------------------------------------------- #
def credit_sale_price_of(plan_price: dict) -> float:
    """取一条套餐价的每积分售价；未预算则按 月均价/月积分 现算。"""
    value = plan_price.get("credit_sale_price_cny")
    if value is not None:
        try:
            return float(value)
        except (TypeError, ValueError):
            return 0.0
    monthly_credits = int(plan_price.get("monthly_credits") or 0)
    monthly_price = plan_price.get("monthly_price_cny")
    if monthly_price is None:
        price = float(plan_price.get("price_cny") or 0)
        months = int(plan_price.get("term_months") or 1) or 1
        monthly_price = price / months
    if monthly_credits <= 0:
        return 0.0
    return float(monthly_price) / monthly_credits


def build_sale_price_table(plan_prices: list[dict]) -> list[dict]:
    table = []
    for pp in plan_prices or []:
        table.append({
            "plan_code": pp.get("plan_code"),
            "cycle": pp.get("cycle"),
            "monthly_credits": int(pp.get("monthly_credits") or 0),
            "monthly_price_cny": round(float(pp.get("monthly_price_cny") or 0), 4),
            "credit_sale_price_cny": round(credit_sale_price_of(pp), 6),
        })
    table.sort(key=lambda r: r["credit_sale_price_cny"])
    return table


def global_min_credit_sale_price(plan_prices: list[dict]) -> dict | None:
    """全局最低每积分售价（毛利最差的锚点，通常是年付/量大套餐）。"""
    best = None
    for pp in plan_prices or []:
        price = credit_sale_price_of(pp)
        if price <= 0:
            continue
        if best is None or price < best["credit_sale_price_cny"]:
            best = {
                "plan_code": pp.get("plan_code"),
                "cycle": pp.get("cycle"),
                "credit_sale_price_cny": price,
            }
    return best


# --------------------------------------------------------------------------- #
# 毛利率基础计算                                                                #
# --------------------------------------------------------------------------- #
def margin_ratio(credits: float, cost_cny: float, sale_price_cny: float) -> float | None:
    """毛利率 = 1 − 成本 / 收入；收入（credits × 每积分售价）为 0 时无意义返回 None。"""
    revenue = float(credits) * float(sale_price_cny)
    if revenue <= 0:
        return None
    return (revenue - float(cost_cny)) / revenue


def _margin_status(m, target_ratio: float, alert_ratio: float) -> str:
    """红绿灯着色：green ≥ target / yellow ≥ alert / red < alert。仅监控，不拦截。"""
    if m is None:
        return "unknown"
    if m < alert_ratio:
        return "red"
    if m < target_ratio:
        return "yellow"
    return "green"


def _rule_credits(rule: dict) -> int:
    try:
        return int(rule.get("credits") or 0)
    except (TypeError, ValueError):
        return 0


def _cost_value(cost: dict):
    value = cost.get("upstream_cost_cny")
    if value is None:
        return None
    try:
        c = float(value)
    except (TypeError, ValueError):
        return None
    return c if c >= 0 else None


# --------------------------------------------------------------------------- #
# 只读毛利监控看板                                                              #
# --------------------------------------------------------------------------- #
def build_margin_report(
    rules: list[dict],
    provider_costs: list[dict],
    plan_prices: list[dict],
    policy: dict | None = None,
) -> dict:
    """
    只读毛利监控（阶段A 契约）：
      { nodes:[{node_id, unit, credits, providers:[
            {provider_id, platform_code, upstream_cost_cny, credits, margin, status}]}],
        global_min_credit_sale_price, policy }

    每节点单价来自计费规则（credit_pricing_rules）；每 provider 成本来自独立成本表
    （credit_provider_costs）。margin = 1 − cost /(credits × 全局最低每积分售价)。
    provider 特例（web_search 的 qwen/tavily）取其 provider 专属单价，否则取节点默认单价。
    **顾问性，不阻断任何操作。**
    """
    policy = policy or {}
    target = float(policy.get("margin_target_ratio", DEFAULT_TARGET_RATIO) or DEFAULT_TARGET_RATIO)
    alert = float(policy.get("margin_alert_ratio", DEFAULT_ALERT_RATIO) or DEFAULT_ALERT_RATIO)
    anchor = global_min_credit_sale_price(plan_prices)
    sale_price = anchor["credit_sale_price_cny"] if anchor else 0.0

    # 计费规则按 (node_id, unit) 归组：区分 provider 无关默认价 与 provider 特例价
    node_rules: dict = {}
    for rule in rules or []:
        if not isinstance(rule, dict) or not rule.get("enabled", True):
            continue
        node_id = (rule.get("node_id") or "").lower()
        unit = (rule.get("unit") or "").lower()
        if not node_id:
            continue
        credits = _rule_credits(rule)
        entry = node_rules.setdefault((node_id, unit), {"default": None, "by_provider": {}})
        pid = (rule.get("provider_id") or "").lower()
        if pid and pid != "*":
            entry["by_provider"][pid] = credits
        else:
            entry["default"] = credits

    # 成本表按 (node_id, unit) 归组
    costs_by_node: dict = {}
    for cost in provider_costs or []:
        if not isinstance(cost, dict):
            continue
        node_id = (cost.get("node_id") or "").lower()
        unit = (cost.get("unit") or "").lower()
        costs_by_node.setdefault((node_id, unit), []).append(cost)

    nodes = []
    for (node_id, unit), entry in node_rules.items():
        providers = []
        for cost in costs_by_node.get((node_id, unit), []):
            pid = (cost.get("provider_id") or "").lower()
            credits = entry["by_provider"].get(pid, entry["default"])
            upstream = _cost_value(cost)
            m = None
            if credits and upstream is not None:
                m = margin_ratio(credits, upstream, sale_price)
            providers.append({
                "provider_id": pid,
                "platform_code": cost.get("platform_code"),
                "upstream_cost_cny": upstream,
                "credits": credits,
                "margin": None if m is None else round(m, 4),
                "status": _margin_status(m, target, alert),
            })
        providers.sort(key=lambda p: p["provider_id"])
        nodes.append({
            "node_id": node_id,
            "unit": unit,
            "credits": entry["default"],
            "providers": providers,
        })
    nodes.sort(key=lambda n: (n["node_id"], n["unit"]))

    return {
        "nodes": nodes,
        "global_min_credit_sale_price": anchor,
        "policy": {
            "margin_target_ratio": target,
            "margin_alert_ratio": alert,
            "image_surcharge_credits": int(policy.get("image_surcharge_credits", 15) or 0),
        },
    }
