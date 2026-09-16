"""
RewriteNode — 改写选中文本节点（对应第2种快捷键流程）。

行为与 rewrite operation 相同：
  - 始终调用 LLM（rewrite prompt）
  - 有 selected_text 时执行改写（模式 A）
  - 无 selected_text 时执行纠偏/生成（模式 B）
  - action_type = paste，result 始终是后端最终处理结果

Agent 模式（ctx.from_agent=True）：无 selected_text 时也始终调用 LLM，不做短文本跳过判断。
意图识别已确认为 REWRITE，节点无需再做二次文本长度判断。
"""
import logging
from typing import Optional, List, TYPE_CHECKING

from app.agent.nodes.base import BaseNode
from app.data.credits.models import BreakdownItem
from app.services.billing.credit_calculator import apply_image_surcharge
from app.models.schemas import ActionType

if TYPE_CHECKING:
    from app.services.pipeline.v1.audio_pipeline import PipelineContext

logger = logging.getLogger("voice_input.node.rewrite")


class RewriteNode(BaseNode):
    """复用 rewrite operation 的处理流程。"""

    def __init__(self, llm_service):
        self._llm_service = llm_service

    async def execute(self, ctx: "PipelineContext",
                      langchain_callbacks: Optional[List] = None) -> None:
        input_text = ctx.transcript + (ctx.selected_text or "")

        if not ctx.selected_text:
            # Agent 流程：意图已由 IntentRouter 确认为 REWRITE，始终调用 LLM
            # 独立流程：短文本直接透传，节省积分
            if ctx.from_agent:
                should_use_llm = True
            else:
                text = ctx.transcript
                chinese_count = sum(1 for c in text if '\u4e00' <= c <= '\u9fff')
                letter_count = sum(1 for c in text if c.isascii() and c.isalpha())
                should_use_llm = (
                    ctx.has_correction_hints
                    or chinese_count > 5
                    or letter_count > 50
                )

            if should_use_llm:
                ctx.result, key_info = await self._llm_service.run(
                    operation="rewrite",
                    transcript=ctx.transcript,
                    selected_text=None,
                    clipboard_history=ctx.clipboard_history,
                    clipboard_items=ctx.clipboard_items,
                    provider=ctx.provider,
                    model=ctx.model,
                    user_email=ctx.user_email,
                    client_platform=ctx.client_platform,
                    correction_hints=ctx.correction_hints or None,
                    langchain_callbacks=langchain_callbacks,
                    return_key_info=True,
                    flow_name=ctx.flow_name,
                    transcript_language=ctx.transcript_language,
                )
                ctx.llm_invoked = True
                if ctx.credit_calc:
                    est_input = ctx.credit_calc._estimate_tokens(input_text)
                    est_output = ctx.credit_calc._estimate_tokens(ctx.result)
                    bill_in, bill_out, _ = ctx.credit_calc.resolve_billing_tokens(key_info, est_input, est_output)
                    cost = ctx.credit_calc.token_cost(bill_in, bill_out, key_info)
                    if cost > 0:
                        ctx.credits_cost += cost
                        ctx.credits_breakdown.append(BreakdownItem(
                            platform=f"{key_info.platform_code}_llm",
                            credits=cost,
                            input_tokens=bill_in,
                            output_tokens=bill_out,
                        ))
                    apply_image_surcharge(ctx, key_info)
            else:
                ctx.result = ctx.transcript

            ctx.action_type = ActionType.paste
            return

        raw, key_info = await self._llm_service.run(
            operation="rewrite",
            transcript=ctx.transcript,
            selected_text=ctx.selected_text,
            clipboard_history=ctx.clipboard_history,
            clipboard_items=ctx.clipboard_items,
            provider=ctx.provider,
            model=ctx.model,
            user_email=ctx.user_email,
            client_platform=ctx.client_platform,
            correction_hints=ctx.correction_hints or None,
            langchain_callbacks=langchain_callbacks,
            return_key_info=True,
            flow_name=ctx.flow_name,
            transcript_language=ctx.transcript_language,
        )
        ctx.llm_invoked = True
        if ctx.credit_calc:
            est_input = ctx.credit_calc._estimate_tokens(input_text)
            est_output = ctx.credit_calc._estimate_tokens(raw)
            bill_in, bill_out, _ = ctx.credit_calc.resolve_billing_tokens(key_info, est_input, est_output)
            cost = ctx.credit_calc.token_cost(bill_in, bill_out, key_info)
            if cost > 0:
                ctx.credits_cost += cost
                ctx.credits_breakdown.append(BreakdownItem(
                    platform=f"{key_info.platform_code}_llm",
                    credits=cost,
                    input_tokens=bill_in,
                    output_tokens=bill_out,
                ))
            apply_image_surcharge(ctx, key_info)

        ctx.result = raw
        ctx.action_type = ActionType.paste
