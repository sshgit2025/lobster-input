"""
OpenClawNode — OpenClaw 会话开启/关闭/执行节点。

OpenClawOnNode：
  - 接收到前端上报的 openclaw_status，做有效性验证
  - not_installed / service_down → 返回 tip code 码（前端管理国际化文案）
  - installed（服务正常）→ 返回 OPENCLAW_SESSION_STARTED
  - action_type = tip，result 为 code 字符串，客户端通过 L10n.tipForCode 映射文案

OpenClawOffNode：
  - 返回 tip（code = "OPENCLAW_SESSION_ENDED"）

OpenClawNewSessionNode：
  - 返回 tip（code = "OPENCLAW_NEW_SESSION_STARTED"）
  - 客户端收到后切换本地 OpenClaw session key，并保持 OpenClaw 模式开启

OpenClawExecuteNode：
  - 当会话已激活时处理所有 agent 请求
  - 使用专用提示词 openclaw_transcribe 对 transcript 做双模式解析：
      COMMAND:<cmd>  → OpenClaw 精确命令（/stop 或 openclaw CLI），action_type = openclaw_slash_command / openclaw_cli_command / openclaw_interactive
      TEXT:<text>    → 自然语言任务，action_type = openclaw_execute
  - 客户端收到 /stop 后调用 Gateway RPC sessions.abort 中断当前会话
  - 客户端收到 openclaw CLI 后直接向终端写入命令
  - 客户端收到 openclaw_execute 后通过 Gateway RPC sessions.send 发送给 OpenClaw 会话

会话状态管理：
  - 后端不持久化 OpenClaw 会话状态
  - 客户端在每次请求中上报 openclaw_session_active，后端仅按当次请求路由

tip code 码约定（客户端 L10n 管理对应文案）：
  - OPENCLAW_NOT_INSTALLED    — 未安装
  - OPENCLAW_SERVICE_DOWN     — 已安装但服务未运行
  - OPENCLAW_SESSION_STARTED  — 会话已激活
  - OPENCLAW_SESSION_ENDED    — 会话已关闭
  - OPENCLAW_ALREADY_ACTIVE   — 会话已激活，拒绝重复开启
  - OPENCLAW_NEW_SESSION_STARTED — 已切换到新的客户端会话 key
"""
import logging
import re
from typing import Optional, List, TYPE_CHECKING

from app.agent.nodes.base import BaseNode
from app.data.credits.models import BreakdownItem
from app.services.billing.credit_calculator import apply_image_surcharge
from app.models.schemas import ActionType

if TYPE_CHECKING:
    from app.services.pipeline.v1.audio_pipeline import PipelineContext

logger = logging.getLogger("voice_input.node.openclaw")


# ── 节点实现 ──────────────────────────────────────────────────────────────────

class OpenClawOnNode(BaseNode):
    """
    开启 OpenClaw 会话节点。
    根据前端上报的 openclaw_status 决定是激活会话还是返回错误 code。
    """

    def __init__(self, llm_service):
        self._llm_service = llm_service

    async def execute(self, ctx: "PipelineContext",
                      langchain_callbacks: Optional[List] = None) -> None:
        oc_status = ctx.openclaw_status or "installed"

        if oc_status == "not_installed":
            ctx.result = "OPENCLAW_NOT_INSTALLED"
            ctx.action_type = ActionType.tip
            logger.info("OpenClawOnNode: openclaw not installed for user=%s", ctx.user_email)
            return

        if oc_status == "service_down":
            ctx.result = "OPENCLAW_SERVICE_DOWN"
            ctx.action_type = ActionType.tip
            logger.info("OpenClawOnNode: openclaw service down for user=%s", ctx.user_email)
            return

        ctx.result = "OPENCLAW_SESSION_STARTED"
        ctx.action_type = ActionType.tip
        ctx.llm_invoked = False
        logger.info("OpenClawOnNode: session started for user=%s", ctx.user_email)


class OpenClawOffNode(BaseNode):
    """关闭 OpenClaw 会话节点。"""

    def __init__(self, llm_service):
        self._llm_service = llm_service

    async def execute(self, ctx: "PipelineContext",
                      langchain_callbacks: Optional[List] = None) -> None:
        ctx.result = "OPENCLAW_SESSION_ENDED"
        ctx.action_type = ActionType.tip
        ctx.llm_invoked = False
        logger.info("OpenClawOffNode: session ended for user=%s", ctx.user_email)


class OpenClawNewSessionNode(BaseNode):
    """开启新的 OpenClaw 会话节点。"""

    def __init__(self, llm_service):
        self._llm_service = llm_service

    async def execute(self, ctx: "PipelineContext",
                      langchain_callbacks: Optional[List] = None) -> None:
        oc_status = ctx.openclaw_status or "installed"

        if oc_status == "not_installed":
            ctx.result = "OPENCLAW_NOT_INSTALLED"
            ctx.action_type = ActionType.tip
            logger.info("OpenClawNewSessionNode: openclaw not installed for user=%s", ctx.user_email)
            return

        if oc_status == "service_down":
            ctx.result = "OPENCLAW_SERVICE_DOWN"
            ctx.action_type = ActionType.tip
            logger.info("OpenClawNewSessionNode: openclaw service down for user=%s", ctx.user_email)
            return

        ctx.result = "OPENCLAW_NEW_SESSION_STARTED"
        ctx.action_type = ActionType.tip
        ctx.llm_invoked = False
        logger.info("OpenClawNewSessionNode: new session requested for user=%s", ctx.user_email)


class OpenClawExecuteNode(BaseNode):
    """
    OpenClaw 执行节点（会话激活状态下）。

    使用专用提示词 openclaw_transcribe 对 transcript 做双模式解析：
      - COMMAND:<cmd>  → 识别为 OpenClaw 精确快捷命令，按正则进一步分类：
          /stop 中断命令（/开头）   → action_type = openclaw_slash_command（客户端调用 sessions.abort）
          交互式 CLI 命令            → action_type = openclaw_interactive（新开终端，用户交互）
          普通 CLI 命令（openclaw …）→ action_type = openclaw_cli_command（复用 openclaw 终端）
          匹配失败（未知格式）       → action_type = openclaw_slash_command（保守回退）
      - TEXT:<text>    → 识别为自然语言任务，action_type = openclaw_execute
      - 其他格式       → fallback 到 TEXT，防止格式失控

    客户端收到后：
      - openclaw_execute: 通过 Gateway RPC sessions.send 发送自然语言任务
      - openclaw_slash_command: 通过 Gateway RPC sessions.abort 中断会话，或 sessions.send 发送 slash 文本
      - openclaw_cli_command: 在复用的 openclaw 专属终端执行
      - openclaw_interactive: 在新建独立终端执行（需要用户交互）
    """

    # LLM 输出前缀常量
    _COMMAND_PREFIX = "COMMAND:"
    _TEXT_PREFIX = "TEXT:"

    # 需要用户交互的 CLI 命令模式（正则，基于 2026.5.27 CLI）
    _INTERACTIVE_PATTERNS = re.compile(
        r"(models\s+auth\s+(add|setup-token|paste-token)"
        r"|onboard|configure|setup"
        r"|models\s+set(\b|$)"
        r"|models\s+set-image\b"
        r"|models\s+scan"
        r"|config\s+(set|unset|edit)\b"
        r"|channels\s+(login|add)\b)",
        re.IGNORECASE,
    )

    # openclaw 开头的 CLI 命令（新开终端执行，但可能是非交互的）
    _CLI_PREFIX_PATTERN = re.compile(r"^openclaw\b", re.IGNORECASE)

    def __init__(self, llm_service):
        self._llm_service = llm_service

    async def execute(self, ctx: "PipelineContext",
                      langchain_callbacks: Optional[List] = None) -> None:
        oc_status = ctx.openclaw_status or "installed"

        if oc_status in ("not_installed", "service_down"):
            tip_code = "OPENCLAW_NOT_INSTALLED" if oc_status == "not_installed" else "OPENCLAW_SERVICE_DOWN"
            ctx.result = tip_code
            ctx.action_type = ActionType.tip
            logger.info(
                "OpenClawExecuteNode: openclaw unavailable (status=%s) for user=%s",
                oc_status, ctx.user_email,
            )
            return

        raw_output = await self._refine_with_openclaw_prompt(ctx, langchain_callbacks=langchain_callbacks)
        cmd, action = self._parse_output(raw_output)

        ctx.result = cmd
        ctx.action_type = action
        ctx.llm_invoked = True
        logger.info(
            "OpenClawExecuteNode: user=%s action=%s output=[%s]",
            ctx.user_email, action.value, cmd[:80],
        )

    async def _refine_with_openclaw_prompt(self, ctx: "PipelineContext",
                                             langchain_callbacks: Optional[List] = None) -> str:
        """使用 openclaw_transcribe 专用提示词处理语音识别文本。"""
        try:
            result, key_info = await self._llm_service.run(
                operation="openclaw_transcribe",
                transcript=ctx.transcript,
                selected_text=ctx.selected_text,
                clipboard_history=ctx.clipboard_history,
                provider=ctx.provider,
                model=ctx.model,
                user_email=ctx.user_email,
                client_platform=ctx.client_platform,
                langchain_callbacks=langchain_callbacks,
                return_key_info=True,
                flow_name=ctx.flow_name,
                transcript_language=ctx.transcript_language,
            )
            if ctx.credit_calc:
                est_input = ctx.credit_calc._estimate_tokens(ctx.transcript)
                est_output = ctx.credit_calc._estimate_tokens(result)
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
            return result
        except Exception as e:
            logger.warning("OpenClawExecuteNode: refine failed (%s), using raw transcript as TEXT", e)
            return f"{self._TEXT_PREFIX}{ctx.transcript}"

    def _parse_output(self, raw: str) -> tuple[str, "ActionType"]:
        """
        解析 LLM 双模式输出，COMMAND 进一步分类为三种命令类型。

        COMMAND:<cmd>
          → slash 命令（/开头）        → openclaw_slash_command
          → 交互式 CLI                 → openclaw_interactive
          → 普通 CLI（openclaw 开头）  → openclaw_cli_command
          → 其他（无法匹配）           → openclaw_slash_command（保守）
        TEXT:<text>                    → openclaw_execute
        未知格式                        → openclaw_execute（fallback）
        """
        stripped = raw.strip()

        if stripped.upper().startswith(self._COMMAND_PREFIX.upper()):
            cmd = stripped[len(self._COMMAND_PREFIX):].strip()
            if cmd:
                action = self._classify_command(cmd)
                logger.debug("OpenClawExecuteNode: COMMAND=[%s] → %s", cmd, action.value)
                return cmd, action
            logger.warning("OpenClawExecuteNode: COMMAND prefix found but empty command, fallback TEXT")

        if stripped.upper().startswith(self._TEXT_PREFIX.upper()):
            text = stripped[len(self._TEXT_PREFIX):].strip()
            if text:
                logger.debug("OpenClawExecuteNode: TEXT=[%s]", text[:60])
                return text, ActionType.openclaw_execute

        logger.warning(
            "OpenClawExecuteNode: unrecognized output format [%s], treating as TEXT",
            stripped[:80],
        )
        return stripped, ActionType.openclaw_execute

    def _classify_command(self, cmd: str) -> "ActionType":
        """
        对 COMMAND 输出做精细分类：
          1. slash 命令（/ 开头）             → openclaw_slash_command
          2. 含交互式操作关键字（正则匹配）   → openclaw_interactive
          3. openclaw 开头的 CLI 命令         → openclaw_cli_command
          4. 其他（匹配失败保守处理）         → openclaw_slash_command
        """
        stripped = cmd.strip()
        if stripped.startswith("/"):
            return ActionType.openclaw_slash_command

        if self._INTERACTIVE_PATTERNS.search(stripped):
            return ActionType.openclaw_interactive

        if self._CLI_PREFIX_PATTERN.match(stripped):
            return ActionType.openclaw_cli_command

        # 保守回退：未知格式但以 COMMAND: 输出，视为 slash 命令（发到 agent 会话）
        logger.warning(
            "OpenClawExecuteNode: command [%s] did not match any pattern, fallback to slash",
            stripped[:60],
        )
        return ActionType.openclaw_slash_command
