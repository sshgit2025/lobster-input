"""
RewritePipeline — rewrite 操作的专用流水线。

继承 AudioProcessPipeline，重写以下步骤：
  - should_invoke_llm: 根据是否有 selected_text 及文本长度决定是否调用 LLM
  - invoke_llm: 复用基类积分计算逻辑（llm_cost + credits_breakdown）
  - resolve_action_type: rewrite 始终返回 paste，result 始终是后端最终处理结果

无 selected_text 时的行为：
  - 仍使用 rewrite operation 和 prompt，因为 rewrite.txt 内置了无选中文本时的
    完整处理逻辑（纠偏直出 + 生成执行），不再需要回退到 transcribe operation。
  - 不向 LLM 传递 selected_text，避免模型误判为改写场景。
  - 传递 user_email 以支持对话历史记忆和积分统计，与 transcribe 流程对齐。
"""
import logging
from typing import Optional, TYPE_CHECKING

from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline, PipelineContext
from app.data.credits.models import BreakdownItem
from app.services.billing.credit_calculator import apply_image_surcharge
from app.models.schemas import ActionType

if TYPE_CHECKING:
    from app.services.billing.credit_calculator import CreditCalculator

logger = logging.getLogger("voice_input.rewrite_pipeline")


class RewritePipeline(AudioProcessPipeline):
    """rewrite 操作专用流水线。"""

    def should_invoke_llm(self, ctx: PipelineContext) -> bool:
        """
        有 selected_text 时始终调用 LLM。
        无 selected_text 时，与 transcribe 保持一致：
          - 存在剪贴板上下文 → 强制调用 LLM 消费剪贴板内容
          - 用户词典纠偏产生了有效 hints（has_correction_hints）→ 强制调用 LLM 消费 hints
          - 文本足够长（中文 > 5 字 或 英文字母 > 50 个）→ 调用 LLM
        """
        if ctx.selected_text:
            return True
        if ctx.persona_active:
            logger.info(
                "[RewritePipeline.should_invoke_llm] active rewrite persona → force LLM user=%s",
                ctx.user_email or "<anonymous>",
            )
            return True
        if ctx.clipboard_history or ctx.clipboard_items:
            return True
        if ctx.has_correction_hints:
            return True
        text = ctx.transcript
        chinese_count = sum(1 for c in text if '\u4e00' <= c <= '\u9fff')
        letter_count = sum(1 for c in text if c.isascii() and c.isalpha())
        return chinese_count > 5 or letter_count > 50

    async def invoke_llm(self, ctx: PipelineContext,
                         credit_calc: Optional["CreditCalculator"] = None) -> str:
        """
        调用 LLM 处理改写请求。

        积分计算与 transcribe 流水线完全对齐：
          - 使用精确 token 估算（_estimate_tokens）+ llm_cost
          - 写入 credits_breakdown 供账本记录
        始终传递 user_email 以支持对话历史记忆。
        """
        input_text = ctx.transcript + (ctx.selected_text or "")

        raw, key_info = await self.llm_service.run(
            operation=ctx.operation,
            transcript=ctx.transcript,
            selected_text=ctx.selected_text or None,
            clipboard_history=ctx.clipboard_history,
            clipboard_items=ctx.clipboard_items,
            provider=ctx.provider,
            model=ctx.model,
            user_email=ctx.user_email,
            client_platform=ctx.client_platform,
            correction_hints=ctx.correction_hints or None,
            return_key_info=True,
            flow_name=ctx.flow_name,
            transcript_language=ctx.transcript_language,
        )

        if credit_calc:
            est_input = credit_calc._estimate_tokens(input_text)
            est_output = credit_calc._estimate_tokens(raw)
            bill_in, bill_out, _ = credit_calc.resolve_billing_tokens(key_info, est_input, est_output)
            cost = credit_calc.token_cost(bill_in, bill_out, key_info)
            if cost > 0:
                ctx.credits_cost += cost
                ctx.credits_breakdown.append(BreakdownItem(
                    platform=f"{key_info.platform_code}_llm",
                    credits=cost,
                    input_tokens=bill_in,
                    output_tokens=bill_out,
                ))
            apply_image_surcharge(ctx, key_info)

        return raw

    def resolve_action_type(self, ctx: PipelineContext) -> ActionType:
        """rewrite 的 result 已是后端最终处理结果，客户端按 paste 消费。"""
        return ActionType.paste
