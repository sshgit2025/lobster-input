"""
CreditCalculator — 基于管理端配置的积分消耗计算器。

根据 PlanRepository.get_platform_credit_ratio() 返回的业务节点扣费规则，
将各 API 节点的实际用量（tokens / 音频分钟数 / 搜索次数）换算为积分消耗。

设计原则：
  - 每次请求需要一个实例（持有缓存好的 ratio dict 避免重复查库）
  - 节点级同步计算，不依赖异步 usage 队列
  - 计算结果向上取整（math.ceil），保证 1 token 也算 1 积分
"""
import math
import logging

from app.data.credits.models import BreakdownItem

logger = logging.getLogger("voice_input.credit_calculator")


def apply_image_surcharge(ctx, key_info=None) -> int:
    """
    图片输入补计费（P0）：按 ctx.clipboard_items 中图片数量追加固定积分/图。

    幂等：同一请求只计一次（ctx.image_charged 标记），可安全在多个 LLM 计费点调用。
    在任一实际调用视觉 LLM 的计费点触发，未含图片或已计过则为 0。
    """
    calc = getattr(ctx, "credit_calc", None)
    if calc is None or getattr(ctx, "image_charged", False):
        return 0
    ctx.image_charged = True
    cost = calc.image_cost(getattr(ctx, "clipboard_items", None))
    if cost <= 0:
        return 0
    ctx.credits_cost += cost
    platform = (getattr(key_info, "platform_code", "") or "image") + "_image"
    image_count = calc.count_images(getattr(ctx, "clipboard_items", None))
    ctx.credits_breakdown.append(BreakdownItem(platform=platform, credits=cost, search_count=image_count))
    logger.info("[Credit] image surcharge: images=%d credits=%d", image_count, cost)
    return cost


class CreditCalculator:
    """积分消耗同步计算器，由 pipeline 在请求开始时初始化。"""

    # 无策略配置时的图片附加积分兜底默认值（与 DEFAULT_CREDIT_PRICING_POLICY 对齐）
    DEFAULT_IMAGE_SURCHARGE_CREDITS = 15

    def __init__(self, ratio: dict):
        self._ratio = ratio
        self._policy = ratio.get("policy") if isinstance(ratio, dict) else None
        if not isinstance(self._policy, dict):
            self._policy = {}

    @property
    def image_surcharge_credits(self) -> int:
        try:
            return max(0, int(self._policy.get("image_surcharge_credits",
                                               self.DEFAULT_IMAGE_SURCHARGE_CREDITS)))
        except (TypeError, ValueError):
            return self.DEFAULT_IMAGE_SURCHARGE_CREDITS

    @staticmethod
    def count_images(clipboard_items) -> int:
        """统计结构化剪贴板里的图片数量（kind==image 且带 data_url）。"""
        if not clipboard_items:
            return 0
        count = 0
        for item in clipboard_items:
            if not isinstance(item, dict):
                continue
            if item.get("kind") == "image" and item.get("data_url"):
                count += 1
        return count

    def image_cost(self, clipboard_items) -> int:
        """图片输入补计费：按图片数量 × 每图固定积分（默认 15/图，可配置）。"""
        image_count = self.count_images(clipboard_items)
        return image_count * self.image_surcharge_credits

    @staticmethod
    def resolve_billing_tokens(key_info, est_input: int, est_output: int):
        """
        计费 token 口径解析：优先使用 provider 返回的真实 token（由 LLMService 注入
        到 key_info.real_input_tokens / real_output_tokens），拿不到才回退字符估算。

        返回 (input_tokens, output_tokens, source)，source ∈ {"provider", "estimate"}。
        """
        real_in = getattr(key_info, "real_input_tokens", None)
        real_out = getattr(key_info, "real_output_tokens", None)
        has_real = False
        try:
            real_in = int(real_in) if real_in is not None else 0
            real_out = int(real_out) if real_out is not None else 0
            has_real = (real_in + real_out) > 0
        except (TypeError, ValueError):
            has_real = False
        if has_real:
            return real_in, real_out, "provider"
        return int(est_input or 0), int(est_output or 0), "estimate"

    def audio_cost(self, duration_sec: float, key_info) -> int:
        if duration_sec <= 0:
            return 0
        credits = self._match_credits(
            getattr(key_info, "business_node_id", "asr_transcribe"),
            getattr(key_info, "category", "asr"),
            getattr(key_info, "provider_id", ""),
            getattr(key_info, "platform_code", ""),
            getattr(key_info, "model", ""),
            "minute",
        )
        # 与 token_cost 语义对齐:规则缺失或被管理端置 0/禁用(credits<=0)时不收费,
        # 否则最低 1 积分。此前无条件 max(1,...) 会导致"停收费"对 ASR 节点无法生效。
        return max(1, math.ceil((duration_sec / 60.0) * credits)) if credits > 0 else 0

    def token_cost(self, input_tokens: int, output_tokens: int, key_info) -> int:
        total_tokens = input_tokens + output_tokens
        if total_tokens <= 0:
            return 0
        credits = self._match_credits(
            getattr(key_info, "business_node_id", ""),
            getattr(key_info, "category", "llm_chat"),
            getattr(key_info, "provider_id", ""),
            getattr(key_info, "platform_code", ""),
            getattr(key_info, "model", ""),
            "1k_tokens",
        )
        return max(1, math.ceil(total_tokens / 1000.0 * credits)) if credits > 0 else 0

    def request_cost(
        self,
        category: str,
        platform_code: str,
        model: str = "",
        *,
        node_id: str = "",
        provider_id: str = "",
    ) -> int:
        return self._match_credits(node_id, category, provider_id, platform_code, model, "request")

    def _match_credits(
        self,
        node_id: str,
        category: str,
        provider_id: str,
        platform_code: str,
        model: str,
        unit: str,
    ) -> int:
        """按业务节点单一价匹配（阶段A）。

        ASR/LLM 一律按 node_id(+unit) 命中，与 provider 无关——同节点同价。
        web_search 为特例：规则带 provider_id 时按 (node_id, provider_id) 命中，
        以区分 qwen/tavily 的按次单价。platform_code/model 不再作为计费维度。
        """
        rules = self._ratio.get("rules") if isinstance(self._ratio, dict) else None
        if not isinstance(rules, list):
            return 0
        node_id = (node_id or "").lower()
        provider_id = (provider_id or "").lower()
        unit = (unit or "").lower()
        best_score = -1
        best_credits = 0
        for rule in rules:
            if not rule.get("enabled", True):
                continue
            rule_node = (rule.get("node_id") or "*").lower()
            rule_provider = (rule.get("provider_id") or "").lower()
            if (rule.get("unit") or "").lower() != unit:
                continue
            if rule_node not in ("*", node_id):
                continue
            # provider 维度仅作特例：规则声明了 provider_id 时必须一致（web_search）；
            # 未声明的规则与 provider 无关，命中所有 provider。
            if rule_provider and rule_provider != "*" and rule_provider != provider_id:
                continue
            score = 0
            if rule_node == node_id:
                score += 4
            if rule_provider and rule_provider == provider_id:
                score += 2
            if score > best_score:
                best_score = score
                best_credits = int(rule.get("credits", 0) or 0)
        return best_credits

    @staticmethod
    def _estimate_tokens(text: str) -> int:
        """粗略估算 token 数：中文 ~1.5 token/字，ASCII ~0.25 token/字符。"""
        if not text:
            return 0
        cjk = sum(1 for c in text if '\u4e00' <= c <= '\u9fff')
        ascii_chars = sum(1 for c in text if c.isascii())
        other = len(text) - cjk - ascii_chars
        return int(cjk * 1.5 + ascii_chars * 0.25 + other * 1.0)
