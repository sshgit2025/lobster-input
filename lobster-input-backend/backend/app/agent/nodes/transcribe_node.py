"""
TranscribeNode — 语音转文字节点（对应第1种快捷键流程）。

行为与 transcribe operation 相同：
  - 调用基础 LLM（transcribe prompt）对识别文本进行纠偏/处理
  - action_type = paste（写入剪贴板 + 自动粘贴）

transcribe 始终调用 LLM 做纠偏与语义后处理（不再按字符长度短句直返）。
极速模式在 pipeline 层拦截，不进入本节点；agent 流程下极速模式被忽略。
"""
import logging
from typing import TYPE_CHECKING, Optional, List

from app.agent.nodes.base import BaseNode
from app.data.credits.models import BreakdownItem
from app.services.billing.credit_calculator import apply_image_surcharge
from app.models.schemas import ActionType

if TYPE_CHECKING:
    from app.services.pipeline.v1.audio_pipeline import PipelineContext

logger = logging.getLogger("voice_input.node.transcribe")

class TranscribeNode(BaseNode):
    """复用 transcribe operation 的处理流程。"""

    def __init__(self, llm_service):
        self._llm_service = llm_service

    async def execute(self, ctx: "PipelineContext",
                      langchain_callbacks: Optional[List] = None) -> None:
        # transcribe 始终调用 LLM 做纠偏与语义后处理
        # 极速模式在 pipeline 层已拦截，不会进入本节点；agent 流程下极速模式被忽略
        ctx.result, key_info = await self._llm_service.run(
            operation="transcribe",
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
            est_input = ctx.credit_calc._estimate_tokens(ctx.transcript)
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
        logger.info("TranscribeNode: LLM processed, result len=%d", len(ctx.result))

        ctx.action_type = ActionType.paste
