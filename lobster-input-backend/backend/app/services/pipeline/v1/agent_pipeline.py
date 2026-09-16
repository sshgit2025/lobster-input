"""
AgentPipeline — 第3种快捷键（agent operation）的专用流水线。

架构设计：多意图混合分发（Intent Routing Pipeline）

流程：
  1. Whisper 语音识别 → transcript
  2. 根据前端本次请求上报的 openclaw_session_active 判断 OpenClaw 模式
  3. 若 OpenClaw 模式已激活 → 直接走 OpenClawExecuteNode
  4. IntentRouter → 意图分类（LLM 输出 IntentType 枚举）
  5. 兜底处理（输出不合法 → 降级为 TRANSCRIBE）
  6. 按 IntentType 分发到对应节点处理
  7. 节点修改 ctx.result / ctx.action_type
  8. 返回响应

5 种意图节点（OpenClaw 会话未激活时）：
  TRANSCRIBE   → TranscribeNode  （复用第1种快捷键流程）
  REWRITE      → RewriteNode     （复用第2种快捷键流程）
  SEARCH       → SearchNode      （联网搜索 + Markdown 格式化）
  OPENCLAW_ON          → OpenClawOnNode         （返回开启 tip code，由客户端更新本地状态）
  OPENCLAW_OFF         → OpenClawOffNode        （返回关闭 tip code，由客户端更新本地状态）
  OPENCLAW_NEW_SESSION → OpenClawNewSessionNode （返回新会话 tip code，由客户端切换本地 session key）

OpenClaw 激活状态：
  IntentRouter 始终执行（不可跳过）：
    OPENCLAW_OFF              → OpenClawOffNode（关闭会话，无论是否激活）
    OPENCLAW_NEW_SESSION      → OpenClawNewSessionNode（切换新会话，并保持开启）
    OPENCLAW_ON  + 已激活    → OPENCLAW_ALREADY_ACTIVE tip（去重保护）
    OPENCLAW_ON  + 未激活    → OpenClawOnNode（正常开启）
    其他意图     + 已激活    → OpenClawExecuteNode（转发给 openclaw）
    其他意图     + 未激活    → 对应功能节点

OpenClaw 状态：
  后端不持久化 OpenClaw 会话状态，只信任当前请求的 openclaw_session_active。
"""
import logging
from typing import Optional, List, TYPE_CHECKING

from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline, PipelineContext
from app.data.credits.models import BreakdownItem
from app.models.schemas import ActionType
from app.core.config import settings

if TYPE_CHECKING:
    from app.services.billing.credit_calculator import CreditCalculator
from app.agent.intent_router import IntentRouter, IntentType
from app.agent.nodes.transcribe_node import TranscribeNode
from app.agent.nodes.rewrite_node import RewriteNode
from app.agent.nodes.search_node import SearchNode
from app.agent.nodes.openclaw_node import (
    OpenClawOnNode, OpenClawOffNode, OpenClawNewSessionNode, OpenClawExecuteNode,
)

try:
    import langwatch as _langwatch_mod
    _LANGWATCH_AVAILABLE = True
except ImportError:
    _langwatch_mod = None
    _LANGWATCH_AVAILABLE = False

logger = logging.getLogger("voice_input.agent_pipeline")


class AgentPipeline(AudioProcessPipeline):
    """
    agent operation 专用流水线 — 多意图混合分发。

    继承 AudioProcessPipeline，重写以下步骤：
      - should_invoke_llm: 始终返回 True（agent 始终需要 LLM 处理）
      - invoke_llm: 执行意图分类 → 节点分发 → 填充 ctx
      - resolve_action_type: 从 ctx.action_type 直接读取（由节点决定）
    """

    def __init__(self):
        super().__init__()
        self._intent_router = IntentRouter()
        self._node_map = {
            IntentType.TRANSCRIBE:   TranscribeNode(self.llm_service),
            IntentType.REWRITE:      RewriteNode(self.llm_service),
            IntentType.SEARCH:       SearchNode(self.llm_service),
            IntentType.OPENCLAW_ON:  OpenClawOnNode(self.llm_service),
            IntentType.OPENCLAW_OFF: OpenClawOffNode(self.llm_service),
            IntentType.OPENCLAW_NEW_SESSION: OpenClawNewSessionNode(self.llm_service),
        }
        self._execute_node = OpenClawExecuteNode(self.llm_service)

    def should_invoke_llm(self, ctx: PipelineContext) -> bool:
        """agent operation 始终需要意图分类，返回 True。"""
        return True

    async def invoke_llm(self, ctx: PipelineContext,
                         credit_calc: Optional["CreditCalculator"] = None) -> str:
        """
        核心分发逻辑。根据 LangWatch 配置决定是否包裹父 trace：
          - LangWatch 可用 → 创建 agent 父 trace，内部所有 LLM 调用作为 child span
          - LangWatch 不可用 → 直接执行
        """
        _use_langwatch = (
            _LANGWATCH_AVAILABLE
            and settings.langwatch_enabled
            and settings.langwatch_api_key
        )
        if _use_langwatch:
            return await self._invoke_llm_with_trace(ctx, credit_calc)
        return await self._invoke_llm_core(ctx, credit_calc, langchain_callbacks=None)

    async def _invoke_llm_with_trace(
        self, ctx: PipelineContext,
        credit_calc: Optional["CreditCalculator"] = None,
    ) -> str:
        """用 LangWatch 父 trace 包裹整个 agent 分发流程。"""
        @_langwatch_mod.trace(
            name="agent_pipeline",
            metadata={
                "operation": "agent",
                "user_id": ctx.user_email or "",
                "provider": ctx.provider or "",
                "model": ctx.model or "",
                "client_platform": ctx.client_platform,
            },
        )
        async def _inner():
            callback = _langwatch_mod.get_current_trace().get_langchain_callback()
            return await self._invoke_llm_core(ctx, credit_calc, langchain_callbacks=[callback])

        return await _inner()

    async def _invoke_llm_core(
        self, ctx: PipelineContext,
        credit_calc: Optional["CreditCalculator"] = None,
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        """
        实际分发逻辑（IntentRouter 始终执行，不可跳过）：
          1. 始终调用 IntentRouter 分类意图
          2. 路由规则：
             - OPENCLAW_OFF → OpenClawOffNode（无论激活状态，关闭会话）
             - OPENCLAW_NEW_SESSION → OpenClawNewSessionNode（无论激活状态，切换新会话）
             - OPENCLAW_ON  + 已激活 → 返回 OPENCLAW_ALREADY_ACTIVE tip（去重保护）
             - OPENCLAW_ON  + 未激活 → OpenClawOnNode（正常开启）
             - 其他意图     + 已激活 → OpenClawExecuteNode（转发给 openclaw）
             - 其他意图     + 未激活 → 对应功能节点（正常处理）
        """
        is_ios = ctx.client_platform == "ios"

        # 标记来源，让各节点内部始终调用 LLM（不再做 should_use_llm 短路判断）
        ctx.from_agent = True

        intent, intent_key_info = await self._intent_router.classify(
            transcript=ctx.transcript,
            user_email=ctx.user_email,
            provider=ctx.provider,
            model=ctx.model,
            client_platform=ctx.client_platform,
            langchain_callbacks=langchain_callbacks,
            return_key_info=True,
            flow_name=ctx.flow_name,
            transcript_language=ctx.transcript_language,
        )
        if ctx.credit_calc:
            est_input = ctx.credit_calc._estimate_tokens(ctx.transcript)
            est_output = ctx.credit_calc._estimate_tokens(intent.value)
            bill_in, bill_out, _ = ctx.credit_calc.resolve_billing_tokens(intent_key_info, est_input, est_output)
            cost = ctx.credit_calc.token_cost(bill_in, bill_out, intent_key_info)
            if cost > 0:
                ctx.credits_cost += cost
                ctx.credits_breakdown.append(BreakdownItem(
                    platform=f"{intent_key_info.platform_code}_llm",
                    credits=cost,
                    input_tokens=bill_in,
                    output_tokens=bill_out,
                ))
        logger.info(
            "AgentPipeline: intent=%s, user=%s, platform=%s, transcript=[%s]",
            intent.value, ctx.user_email, ctx.client_platform, ctx.transcript[:60]
        )

        # iOS 端不支持 OpenClaw，跳过所有 OpenClaw 路由逻辑
        if is_ios:
            if intent in (IntentType.OPENCLAW_ON, IntentType.OPENCLAW_OFF, IntentType.OPENCLAW_NEW_SESSION):
                logger.info(
                    "AgentPipeline: iOS ignoring openclaw intent=%s, fallback to TRANSCRIBE",
                    intent.value,
                )
                intent = IntentType.TRANSCRIBE

            node = self._node_map.get(intent)
            if node is None:
                node = self._node_map[IntentType.TRANSCRIBE]
                intent = IntentType.TRANSCRIBE
            ctx.agent_intent = intent.value
            await node.execute(ctx, langchain_callbacks=langchain_callbacks)
            return ctx.result

        # 桌面端：OpenClaw 模式由客户端运行时状态决定，后端不保存状态。
        is_active = bool(ctx.openclaw_session_active)

        if intent == IntentType.OPENCLAW_OFF:
            ctx.agent_intent = IntentType.OPENCLAW_OFF.value
            await self._node_map[IntentType.OPENCLAW_OFF].execute(ctx, langchain_callbacks=langchain_callbacks)
            return ctx.result

        if intent == IntentType.OPENCLAW_NEW_SESSION:
            ctx.agent_intent = IntentType.OPENCLAW_NEW_SESSION.value
            await self._node_map[IntentType.OPENCLAW_NEW_SESSION].execute(ctx, langchain_callbacks=langchain_callbacks)
            return ctx.result

        if intent == IntentType.OPENCLAW_ON and is_active:
            ctx.agent_intent = IntentType.OPENCLAW_ON.value
            ctx.result = "OPENCLAW_ALREADY_ACTIVE"
            ctx.action_type = ActionType.tip
            logger.info(
                "AgentPipeline: openclaw already active, reject duplicate ON for user=%s",
                ctx.user_email,
            )
            return ctx.result

        if is_active:
            logger.info(
                "AgentPipeline: openclaw session active, routing to execute node, user=%s",
                ctx.user_email,
            )
            ctx.agent_intent = "OPENCLAW_EXECUTE"
            await self._execute_node.execute(ctx, langchain_callbacks=langchain_callbacks)
            return ctx.result

        node = self._node_map.get(intent)
        if node is None:
            logger.error("AgentPipeline: no node found for intent=%s, fallback to TRANSCRIBE", intent)
            node = self._node_map[IntentType.TRANSCRIBE]
            intent = IntentType.TRANSCRIBE

        ctx.agent_intent = intent.value
        await node.execute(ctx, langchain_callbacks=langchain_callbacks)
        return ctx.result

    def resolve_action_type(self, ctx: PipelineContext) -> ActionType:
        """由各节点在执行时直接写入 ctx.action_type，此处直接返回。"""
        return ctx.action_type
