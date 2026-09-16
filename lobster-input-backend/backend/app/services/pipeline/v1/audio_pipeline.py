"""
AudioProcessPipeline — 音频处理流水线（模板方法模式）。

将音频处理拆分为可独立重写的步骤:
  1. transcribe()       — 语音识别
  2. should_invoke_llm() — 判断是否需要调用 LLM（默认 False）
  3. invoke_llm()       — 调用 LLM 处理
  4. resolve_action_type() — 决定返回给客户端的操作类型
  5. build_response()   — 组装最终响应

子类可重写任意步骤来定制行为，例如:
  - 某些 operation 始终需要 LLM → 重写 should_invoke_llm 返回 True
  - Agent 模式需要多步工具调用 → 重写 invoke_llm 使用 Agent 执行器
"""
import asyncio
import json
import logging
import math
import re
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Optional, List

from app.core.config import settings
from app.core.lang_utils import normalize_lang
from app.core.language_detection import detect_language
from app.models.schemas import AudioTranscribeResponse, ActionType, ConfigUpdate
from app.services.audio.audio_service import AudioService
from app.services.llm.llm_service import LLMService
from app.services.llm.conversation_memory import ConversationMemory
from app.repositories.user_repository import UserRepository
from app.repositories.plan_repository import PlanRepository
from app.repositories.persona_repository import PersonaRepository
from app.core.exceptions import CreditsExhaustedException, ServiceTemporarilyUnavailableException
from app.services.billing.credit_calculator import CreditCalculator, apply_image_surcharge
from app.services.billing.credit_account_service import CreditAccountService
from app.services.infra.failure_guard import FailureGuard
from app.services.audio.asr_correction import get_correction_service
from app.services.pipeline.transcribe_routing import is_pure_interjection
from app.data.credits.models import BreakdownItem, CreditLedgerEntry
from app.data.credits.repository import CreditLedgerRepository

logger = logging.getLogger("voice_input.pipeline")

# 积分账本写入为纯记录（异常已 swallow），移出响应热路径改后台 fire-and-forget。
# 持有 task 强引用防止被 GC 中途回收；完成后自动从集合移除。
_ledger_tasks: set = set()


async def _write_credit_ledger(entry) -> None:
    try:
        await CreditLedgerRepository().insert(entry)
    except Exception as _ledger_err:  # 纯记录，失败不影响已完成的扣费/响应
        logger.warning("[Pipeline] credit_ledger insert failed: %s", _ledger_err)


def _spawn_credit_ledger_write(entry) -> None:
    """后台异步写入积分账本，不阻塞响应返回。"""
    try:
        task = asyncio.create_task(_write_credit_ledger(entry))
    except RuntimeError:
        # 无运行中的事件循环（极端兜底）：退化为同步 best-effort，绝不抛出。
        try:
            asyncio.run(_write_credit_ledger(entry))
        except Exception as _ledger_err:
            logger.warning("[Pipeline] credit_ledger sync fallback failed: %s", _ledger_err)
        return
    _ledger_tasks.add(task)
    task.add_done_callback(_ledger_tasks.discard)


@dataclass
class PipelineContext:
    """流水线上下文，在各步骤间传递数据。"""
    operation: str
    transcript: str = ""
    transcript_language: str = ""   # ASR 检测到的语言代码，供提示词路由使用
    result: str = ""
    llm_invoked: bool = False
    action_type: ActionType = ActionType.paste
    selected_text: Optional[str] = None
    clipboard_history: List[str] = field(default_factory=list)
    clipboard_items: List[dict[str, Any]] = field(default_factory=list)
    provider: Optional[str] = None
    model: Optional[str] = None
    user_email: Optional[str] = None
    warning: Optional[str] = None
    config_update: Optional[ConfigUpdate] = None
    clarify_question: Optional[str] = None  # LLM 意图不明时的询问文案
    openclaw_status: Optional[str] = None   # 客户端上报的 OpenClaw 状态: installed|service_down|not_installed
    openclaw_session_active: bool = False   # 客户端本次请求上报的 OpenClaw 模式状态（后端不持久化）
    client_platform: str = ""               # 客户端平台标识，来自请求头 X-Client-Platform
    client_ui_lang: str = ""               # 客户端 UI 语言，来自请求头 X-Accept-Language，用于流程选择
    flow_name: str = ""                     # 当前选中的处理流程名称（如 "standard"），供号池标签筛选使用
    credits_cost: int = 0                    # 本次请求各节点累计积分消耗
    credits_breakdown: list = field(default_factory=list)  # 各平台积分消耗明细（BreakdownItem 列表）
    precharged_credits: int = 0
    deductions: list = field(default_factory=list)
    credits_remaining: Optional[int] = None
    credit_calc: Optional[object] = None     # CreditCalculator 实例，供节点内部计算积分
    image_charged: bool = False              # 图片补计费幂等标记（同一请求只计一次）
    correction_hints: str = ""               # 用户词典纠偏生成的 [User Dictionary Correction Hints] 内容
    has_correction_hints: bool = False       # 是否有有效 hints（True 时强制触发 LLM）
    persona_active: bool = False             # 用户有激活人设时必须走 LLM，不能被极速模式绕过
    from_agent: bool = False                 # 是否来自 AgentPipeline（True 时节点内部跳过 should_use_llm 判断，始终调用 LLM）
    fast_mode: bool = False                  # transcribe 极速模式：ASR 后直接返回，跳过纠偏和 LLM
    stream_callback: Optional[Callable[[str], Awaitable[None]]] = None  # 仅流式节点使用，如联网搜索结果增量
    stream_event_callback: Optional[Callable[[str, dict[str, Any]], Awaitable[None]]] = None
    agent_intent: Optional[str] = None        # agent 操作最终真实执行的分支


class AudioProcessPipeline:
    """
    音频处理流水线基类（模板方法模式）。
    execute() 是模板方法，定义了完整的处理流程。
    子类通过重写各步骤方法来定制行为。
    """

    def __init__(self):
        self.audio_service = AudioService()
        self.llm_service = LLMService()
        self._memory = ConversationMemory()
        self._user_repo = UserRepository()
        self._plan_repo = PlanRepository()
        self._persona_repo = PersonaRepository()
        self._credit_account = CreditAccountService()

    async def execute(
        self,
        file,
        operation: str,
        selected_text: Optional[str] = None,
        clipboard_history: Optional[str] = None,
        clipboard_items: Optional[str] = None,
        provider: Optional[str] = None,
        model: Optional[str] = None,
        user_email: Optional[str] = None,
        openclaw_status: Optional[str] = None,
        openclaw_session_active: bool = False,
        client_platform: str = "",
        client_ui_lang: str = "",
        flow_name: str = "",
        fast_mode: bool = False,
        stream_callback: Optional[Callable[[str], Awaitable[None]]] = None,
        stream_event_callback: Optional[Callable[[str, dict[str, Any]], Awaitable[None]]] = None,
    ) -> AudioTranscribeResponse:
        """模板方法：定义音频处理的完整流程骨架。"""
        audio_path = None
        enhanced_path = None
        ctx_for_refund: Optional[PipelineContext] = None
        t0 = time.monotonic()
        persona_active = False
        effective_fast_mode = fast_mode and operation == "transcribe"

        def _ms(start): return int((time.monotonic() - start) * 1000)

        try:
            logger.info(
                "[Pipeline] START operation=%s user=%s platform=%s "
                "has_selected=%s selected_len=%d selected_preview=[%s]",
                operation, user_email or "<anonymous>", client_platform or "none",
                bool(selected_text),
                len(selected_text) if selected_text else 0,
                (selected_text[:60] if selected_text else "None"),
            )

            # 0a. 连续失败冻结检查
            if FailureGuard.is_frozen(user_email):
                remain = FailureGuard.remaining_freeze_sec(user_email)
                raise ServiceTemporarilyUnavailableException(
                    f"Too many consecutive failures, retry after {remain}s"
                )

            # 0b. 积分前置检查：remaining > 0 即放行；极速模式仍会消耗 ASR 积分
            t_credits = time.monotonic()
            await self._check_credits(user_email)

            # 0b.1 人设是显式的输出风格配置。只要用户激活了人设，本次请求就必须
            # 进入 LLM 分支，让 PromptManager 使用该人设对应提示词或内置提示词处理。
            persona_active = await self._is_persona_active(user_email, operation, client_platform)
            effective_fast_mode = fast_mode and operation == "transcribe" and not persona_active
            if fast_mode and operation == "transcribe" and persona_active:
                logger.info(
                    "[Pipeline] transcribe fast_mode disabled by active persona: user=%s platform=%s",
                    user_email or "<anonymous>", client_platform or "none",
                )

            # 0c. 加载积分消耗比例配置（供各节点同步计算消耗）
            ratio = await self._plan_repo.get_platform_credit_ratio()
            credit_calc = CreditCalculator(ratio)
            logger.info("[Pipeline][timing] credits_check=%dms", _ms(t_credits))

            # 1. 保存并校验音频文件
            t_save = time.monotonic()
            audio_path = await self.audio_service.save_upload(file)
            logger.info("[Pipeline][timing] save_upload=%dms", _ms(t_save))

            t_enhance = time.monotonic()
            enhanced_path = await self.audio_service.enhance(audio_path)
            logger.info("[Pipeline][timing] enhance=%dms", _ms(t_enhance))

            duration = self.audio_service._get_duration(enhanced_path) or 0.0

            # 2. 构建流水线上下文
            ctx = PipelineContext(
                operation=operation,
                selected_text=selected_text,
                clipboard_history=self._parse_clipboard(clipboard_history),
                clipboard_items=self._parse_clipboard_items(clipboard_items),
                provider=provider,
                model=model,
                user_email=user_email,
                openclaw_status=openclaw_status,
                openclaw_session_active=openclaw_session_active,
                client_platform=client_platform,
                client_ui_lang=client_ui_lang,
                flow_name=flow_name,
                credit_calc=credit_calc,
                fast_mode=effective_fast_mode,
                persona_active=persona_active,
                stream_callback=stream_callback,
                stream_event_callback=stream_event_callback,
            )
            ctx_for_refund = ctx

            # 3. 语音识别
            asr_precharge = await self._estimate_asr_credits(duration)
            asr_rows = await self._precharge_credits(ctx, asr_precharge)
            asr_cost_before = ctx.credits_cost
            t_asr = time.monotonic()
            ctx.transcript = await self.transcribe(
                enhanced_path, user_email=user_email, operation=operation,
                client_platform=client_platform,
                credit_calc=credit_calc, ctx=ctx,
            )
            asr_actual = max(0, ctx.credits_cost - asr_cost_before)
            if asr_precharge > asr_actual:
                await self._refund_credits(ctx, asr_rows, asr_precharge - asr_actual)
            ctx.result = ctx.transcript
            logger.info("[Pipeline][timing] transcribe(asr+correction)=%dms", _ms(t_asr))
            logger.info(
                "[Pipeline] operation=%s user=%s selected_text=[%s] "
                "clipboard_count=%d clipboard_item_count=%d transcript=[%s]",
                operation, user_email or "<anonymous>",
                (selected_text[:40] if selected_text else "None"),
                len(ctx.clipboard_history), len(ctx.clipboard_items),
                ctx.transcript[:80],
            )

            # 4. 条件判断：是否需要调用 LLM
            t_llm = time.monotonic()
            if self.should_invoke_llm(ctx):
                llm_precharge = self._estimate_llm_precharge(ctx)
                llm_rows = await self._precharge_credits(ctx, llm_precharge)
                llm_cost_before = ctx.credits_cost
                ctx.result = await self.invoke_llm(ctx, credit_calc=credit_calc)
                llm_actual = max(0, ctx.credits_cost - llm_cost_before)
                if llm_precharge > llm_actual:
                    await self._refund_credits(ctx, llm_rows, llm_precharge - llm_actual)
                ctx.llm_invoked = True
                logger.info("[Pipeline][timing] invoke_llm=%dms", _ms(t_llm))
                logger.info(
                    "[Pipeline] operation=%s user=%s LLM result=[%s]",
                    operation, user_email or "<anonymous>", ctx.result[:80],
                )
            else:
                logger.info(
                    "[Pipeline] operation=%s user=%s LLM skipped (fast_mode=%s transcript_len=%d)",
                    operation, user_email or "<anonymous>", ctx.fast_mode, len(ctx.transcript),
                )

            # 4.5 保存本轮对话到短期记忆
            if ctx.user_email:
                self._memory.add_turn(
                    ctx.user_email,
                    ctx.transcript,
                    ctx.result,
                    operation=ctx.operation,
                    selected_text=ctx.selected_text,
                )

            # 5. 决定操作类型
            ctx.action_type = self.resolve_action_type(ctx)

            # 5.5 全流程成功：扣除尚未被预扣覆盖的差额，最少扣 1
            t_deduct = time.monotonic()
            deduct_amount = max(1, ctx.credits_cost)
            credits_remaining, deductions = await self._charge_uncovered_credits(ctx)
            if credits_remaining is None:
                credits_remaining = ctx.credits_remaining
            deductions = ctx.deductions
            FailureGuard.record_success(user_email)
            logger.info("[Pipeline][timing] deduct_credits=%dms", _ms(t_deduct))
            logger.info(
                "[Pipeline] credits deducted=%d remaining=%s user=%s",
                deduct_amount, credits_remaining, user_email,
            )

            # 5.6 写入积分账本（含各平台 breakdown 和冗余消耗指标）
            # 纯记录、异常已 swallow，移出响应路径：后台 fire-and-forget 不阻塞返回。
            # idempotency_key 用 user+operation+唯一 id，配合唯一索引防止重复入账。
            if user_email and ctx.credits_breakdown:
                entry = CreditLedgerEntry(
                    user_email=user_email,
                    operation=operation,
                    client_platform=client_platform,
                    total_credits=deduct_amount,
                    breakdown=ctx.credits_breakdown,
                    deductions=deductions,
                    idempotency_key=f"{user_email}:{operation}:{uuid.uuid4().hex}",
                )
                _spawn_credit_ledger_write(entry)

            # 6. 组装响应
            logger.info("[Pipeline][timing] total=%dms", _ms(t0))
            return self.build_response(ctx, credits_remaining=credits_remaining)

        except (CreditsExhaustedException, ServiceTemporarilyUnavailableException):
            if ctx_for_refund and ctx_for_refund.deductions:
                await self._credit_account.refund(user_email, ctx_for_refund.deductions, ctx_for_refund.precharged_credits)
            raise
        except Exception:
            if ctx_for_refund and ctx_for_refund.deductions:
                await self._credit_account.refund(user_email, ctx_for_refund.deductions, ctx_for_refund.precharged_credits)
            FailureGuard.record_failure(user_email)
            raise
        finally:
            if audio_path:
                await self.audio_service.cleanup(audio_path)
            if enhanced_path and enhanced_path != audio_path:
                await self.audio_service.cleanup(enhanced_path)

    # ── 可重写的步骤方法 ──────────────────────────────────

    async def transcribe(self, audio_path, user_email: str = None, operation: str = "transcribe",
                         client_platform: str = "",
                         credit_calc: Optional["CreditCalculator"] = None,
                         ctx: Optional[PipelineContext] = None) -> str:
        """步骤: 语音识别 + 用户词典纠偏 + 积分消耗计算。返回识别文本，同时将 language 写入 ctx。"""
        t_asr = time.monotonic()
        text, language, asr_key_info = await self.audio_service.transcribe(
            audio_path, user_email=user_email, operation=operation, client_platform=client_platform,
            required_tag=ctx.flow_name if ctx is not None else "",
            client_ui_lang=ctx.client_ui_lang if ctx is not None else "",
        )
        logger.info("[Pipeline][timing] asr_only=%dms chars=%d", int((time.monotonic()-t_asr)*1000), len(text))
        if ctx is not None:
            # 提示词语言以转写文本为权威：ASR provider 返回的 language 仅兜底（实时 ASR 常为空），
            # 客户端 UI 语言不参与提示词路由（仅审计）。
            detected_language = detect_language(text, fallback=language)
            if detected_language != normalize_lang(language):
                logger.info(
                    "[Pipeline] prompt language resolved by text: text_detected=%s asr_reported=%s",
                    detected_language or "default", normalize_lang(language) or "none",
                )
            ctx.transcript_language = detected_language

        if credit_calc and ctx:
            duration = self.audio_service._get_duration(audio_path) or 0.0
            cost = credit_calc.audio_cost(duration, asr_key_info) if duration > 0 else 0
            if cost > 0:
                ctx.credits_cost += cost
                ctx.credits_breakdown.append(BreakdownItem(
                    platform=f"{asr_key_info.platform_code}_asr",
                    credits=cost,
                    audio_duration_sec=round(duration, 2),
                    audio_chars=len(text),
                ))
                logger.debug("[Pipeline] whisper cost=%d (duration=%.1fs)", cost, duration)

        if ctx is not None and ctx.fast_mode:
            logger.info("[Pipeline] fast_mode enabled, ASR correction skipped")
        elif (
            operation == "transcribe"
            and not (ctx and ctx.persona_active)
            and is_pure_interjection(text, language)
        ):
            logger.info("[Pipeline] pure interjection, ASR correction skipped (text=%r)", text)
        else:
            if settings.asr_correction_enabled and len(text) >= 2:
                await self._check_next_node_credits(user_email, ctx.credits_cost if ctx else 0)
            # 用户词典纠偏（异步，失败不影响主流程）
            t_correction = time.monotonic()
            text = await self._apply_asr_correction(text, language, ctx=ctx, user_email=user_email)
            logger.info("[Pipeline][timing] asr_correction=%dms", int((time.monotonic()-t_correction)*1000))

        return text

    async def _apply_asr_correction(
        self, text: str, language: str, ctx: Optional[PipelineContext] = None,
        user_email: Optional[str] = None,
    ) -> str:
        """
        ASR 用户词典纠偏：按语言和脚本 adapter 生成候选 hints。
        hints 写入 ctx，由 should_invoke_llm / invoke_llm 消费。
        功能开关由 settings.asr_correction_enabled 控制。
        文本过短（< 2 字符）跳过。
        """
        if not settings.asr_correction_enabled or len(text) < 2:
            return text
        try:
            svc = get_correction_service()
            result = await svc.run(text, language=language, user_email=user_email)
            if result.has_hints and ctx is not None:
                ctx.correction_hints = result.hints_text
                ctx.has_correction_hints = True
                logger.info(
                    "[Pipeline] correction hints ready: language=%s user=%s hints_len=%d",
                    language, user_email or "none", len(result.hints_text),
                )
        except Exception as e:
            logger.warning("ASR correction skipped: %s", e)
        return text

    def should_invoke_llm(self, ctx: PipelineContext) -> bool:
        """
        步骤: 判断是否需要调用 LLM 处理。

        触发 LLM 的条件：
          - transcribe 非极速模式：调用 LLM 做纠偏与语义后处理（仅极短纯语气词兜底直返）
          - rewrite 操作有 selected_text：必须调用 LLM 执行改写工具
          - 用户词典纠偏产生了有效的 correction hints
        """
        if ctx.operation == "transcribe" and ctx.fast_mode:
            logger.info("[Pipeline.should_invoke_llm] transcribe fast_mode → skip LLM")
            return False

        if ctx.persona_active:
            logger.info(
                "[Pipeline.should_invoke_llm] active persona → force LLM operation=%s user=%s",
                ctx.operation, ctx.user_email or "<anonymous>",
            )
            return True

        # rewrite + selected_text：语音是操作指令，必须调用 LLM 执行工具改写
        if ctx.operation == "rewrite" and ctx.selected_text:
            logger.debug(
                "[Pipeline.should_invoke_llm] rewrite+selected_text → force LLM "
                "(selected_len=%d transcript_len=%d)",
                len(ctx.selected_text), len(ctx.transcript),
            )
            return True

        if ctx.has_correction_hints:
            return True

        if not ctx.transcript:
            return False

        # 极短纯语气词（如“嗯”“呃啊”）无实义，直返不走 LLM
        if ctx.operation == "transcribe" and is_pure_interjection(
            ctx.transcript, ctx.transcript_language,
        ):
            return False

        return True

    async def invoke_llm(self, ctx: PipelineContext,
                         credit_calc: Optional["CreditCalculator"] = None) -> str:
        """步骤: 调用 LLM 处理识别文本 + 积分消耗估算。"""
        input_text = ctx.transcript + (ctx.selected_text or "")
        result, key_info = await self.llm_service.run(
            operation=ctx.operation,
            transcript=ctx.transcript,
            selected_text=ctx.selected_text,
            clipboard_history=ctx.clipboard_history,
            clipboard_items=ctx.clipboard_items,
            provider=ctx.provider,
            model=ctx.model,
            user_email=ctx.user_email,
            client_platform=ctx.client_platform,
            correction_hints=ctx.correction_hints or None,
            flow_name=ctx.flow_name,
            transcript_language=ctx.transcript_language,
            return_key_info=True,
        )
        if ctx.operation == "transcribe":
            result = self._sanitize_transcribe_llm_result(result)
        if credit_calc:
            est_input = credit_calc._estimate_tokens(input_text)
            est_output = credit_calc._estimate_tokens(result)
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
                logger.debug("[Pipeline] llm cost=%d", cost)
            apply_image_surcharge(ctx, key_info)
        return result

    @staticmethod
    def _sanitize_transcribe_llm_result(text: str) -> str:
        """
        Keep transcribe output in dictation form when the model accidentally applies
        one-item list formatting. This is intentionally narrow and does not touch
        real multi-line lists from long dictation.
        """
        if not text:
            return text

        result = text.strip()
        lines = [line for line in result.splitlines() if line.strip()]
        if len(lines) == 1:
            result = re.sub(r"^\s*[•·●○◦▪▫‣⁃]\s+", "", result)

        if re.search(r"[\u4e00-\u9fff]", result):
            result = re.sub(r"^[。！？!?，,、；;：:]\s*", "", result)
            result = re.sub(r"[，,]{2,}", "，", result)
            result = re.sub(r"[。]{2,}", "。", result)
            result = re.sub(r"[！!]{2,}", "！", result)
            result = re.sub(r"[？?]{2,}", "？", result)
            result = re.sub(r"，(?=[。！？；])", "", result)
        return result

    async def _is_persona_active(
        self, user_email: Optional[str], operation: str, client_platform: str = ""
    ) -> bool:
        """判断当前端是否存在激活人设；激活人设会强制进入 LLM 分支。激活态逐端隔离。"""
        if not user_email or operation not in ("transcribe", "rewrite"):
            return False
        try:
            prompts = await self._persona_repo.get_active_prompts(user_email, client_platform)
        except Exception as exc:
            logger.warning("[Pipeline] active persona check failed for %s: %s", user_email, exc)
            return False
        active = prompts is not None
        if active:
            logger.info(
                "[Pipeline] active persona detected: operation=%s user=%s",
                operation, user_email,
            )
        return active

    def resolve_action_type(self, ctx: PipelineContext) -> ActionType:
        """步骤: 决定返回给客户端的操作类型。子类可根据 LLM 输出动态决定。"""
        return ActionType.paste

    def build_response(self, ctx: PipelineContext, credits_remaining: Optional[int] = None) -> AudioTranscribeResponse:
        """步骤: 组装最终响应体。"""
        return AudioTranscribeResponse(
            operation=ctx.operation,
            action_type=ctx.action_type,
            transcript=ctx.transcript,
            result=ctx.result,
            model_provider=ctx.provider if ctx.llm_invoked else None,
            model_name=ctx.model if ctx.llm_invoked else None,
            warning=ctx.warning,
            config_update=ctx.config_update,
            clarify_question=ctx.clarify_question,
            credits_remaining=credits_remaining,
            agent_intent=ctx.agent_intent,
        )

    # ── 积分管理 ────────────────────────────────────────────

    async def _check_credits(self, user_email: Optional[str]) -> Optional[int]:
        """前置积分检查：套餐+bonus 总余额 > 0 即放行。"""
        return await self._credit_account.ensure_available(user_email)

    async def _check_estimated_asr_credits(
        self,
        user_email: Optional[str],
        duration_sec: float,
    ) -> Optional[int]:
        """调用 ASR 前按音频时长估算最低所需积分。"""
        if not user_email:
            return None
        estimated = await self._estimate_asr_credits(duration_sec)
        return await self._credit_account.ensure_at_least(user_email, estimated)

    async def _estimate_asr_credits(self, duration_sec: float) -> int:
        if duration_sec <= 0:
            return 1
        ratio = await self._plan_repo.get_platform_credit_ratio()
        rules = ratio.get("rules") if isinstance(ratio, dict) else []
        asr_rules = [
            int(rule.get("credits", 0) or 0)
            for rule in rules
            if rule.get("enabled", True)
            and (rule.get("category") or "").lower() == "asr"
            and (rule.get("unit") or "").lower() == "minute"
        ]
        per_min = max(asr_rules) if asr_rules else 0
        return max(1, int((duration_sec / 60.0) * per_min + 0.999)) if per_min > 0 else 1

    async def _check_next_node_credits(
        self,
        user_email: Optional[str],
        current_cost: int,
    ) -> Optional[int]:
        """调用后续 LLM/搜索节点前，至少保证能覆盖已知消耗和一个新节点的最低扣费。"""
        return await self._credit_account.ensure_at_least(user_email, max(1, int(current_cost or 0) + 1))

    async def _deduct_credits(self, user_email: Optional[str], amount: int = 1):
        """扣减积分并返回扣减后的剩余积分。"""
        return await self._credit_account.deduct(user_email, amount)

    async def _precharge_credits(self, ctx: PipelineContext, amount: int) -> list[dict]:
        amount = max(0, int(amount or 0))
        if not ctx.user_email or amount <= 0:
            return []
        remaining, rows = await self._credit_account.charge(ctx.user_email, amount)
        ctx.precharged_credits += amount
        ctx.deductions.extend(rows)
        ctx.credits_remaining = remaining
        return rows

    async def _refund_credits(self, ctx: PipelineContext, rows: list[dict], amount: Optional[int] = None) -> None:
        if not ctx.user_email or not rows:
            return
        refund_amount = sum(int(row.get("credits", 0) or 0) for row in rows) if amount is None else max(0, int(amount))
        if refund_amount <= 0:
            return
        await self._credit_account.refund(ctx.user_email, rows, refund_amount)
        ctx.precharged_credits = max(0, ctx.precharged_credits - refund_amount)
        ctx.deductions.append({"source": "refund", "credits": -refund_amount})
        balance = await self._credit_account.get_balance(ctx.user_email)
        ctx.credits_remaining = balance["total_remaining"]

    async def _charge_uncovered_credits(self, ctx: PipelineContext) -> tuple[Optional[int], list[dict]]:
        if not ctx.user_email:
            return None, []
        target = max(1, int(ctx.credits_cost or 0))
        uncovered = max(0, target - int(ctx.precharged_credits or 0))
        if uncovered <= 0:
            return ctx.credits_remaining, ctx.deductions
        remaining, rows = await self._credit_account.charge(ctx.user_email, uncovered)
        ctx.precharged_credits += uncovered
        ctx.deductions.extend(rows)
        ctx.credits_remaining = remaining
        return remaining, rows

    def _estimate_llm_precharge(self, ctx: PipelineContext) -> int:
        if not ctx.credit_calc:
            return 1
        text_parts = [
            ctx.transcript or "",
            ctx.selected_text or "",
            ctx.correction_hints or "",
            "\n".join(ctx.clipboard_history or []),
        ]
        for item in ctx.clipboard_items or []:
            if item.get("kind") == "text":
                text_parts.append(item.get("text") or "")
        input_tokens = ctx.credit_calc._estimate_tokens("\n".join(text_parts))
        output_tokens = max(1024, min(4096, input_tokens))
        multiplier = 3 if ctx.operation == "agent" else 1
        max_per_1k = 0
        for rule in (ctx.credit_calc._ratio.get("rules") or []):
            if not rule.get("enabled", True):
                continue
            if (rule.get("category") or "").lower() == "llm_chat" and (rule.get("unit") or "").lower() == "1k_tokens":
                max_per_1k = max(max_per_1k, int(rule.get("credits", 0) or 0))
        if max_per_1k <= 0:
            return 1
        return max(1, math.ceil((input_tokens + output_tokens) / 1000.0 * max_per_1k * multiplier))

    # ── 内部工具方法 ──────────────────────────────────────

    @staticmethod
    def _parse_clipboard(raw: Optional[str]) -> List[str]:
        """解析客户端传来的剪贴板历史 JSON 字符串。"""
        if not raw:
            return []
        if len(raw.encode("utf-8")) > 20_000:
            return []
        try:
            items = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            return []
        if not isinstance(items, list):
            return []
        result = []
        for item in items[:10]:
            if isinstance(item, str):
                result.append(item[:4000])
        return result

    @staticmethod
    def _parse_clipboard_items(raw: Optional[str]) -> List[dict[str, Any]]:
        """解析结构化剪贴板内容，图片必须由客户端明确标记。"""
        if not raw:
            return []
        if len(raw.encode("utf-8")) > 5_000_000:
            return []
        try:
            items = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            return []
        if not isinstance(items, list):
            return []
        result: List[dict[str, Any]] = []
        image_count = 0
        for item in items[:5]:
            if not isinstance(item, dict):
                continue
            kind = item.get("kind")
            if kind == "text" and isinstance(item.get("text"), str):
                result.append({"kind": "text", "text": item["text"][:4000]})
            elif kind == "image" and isinstance(item.get("data_url"), str):
                if image_count >= 2:
                    continue
                data_url = item["data_url"]
                if data_url.startswith("data:image/") and len(data_url.encode("utf-8")) <= 5_000_000:
                    image_count += 1
                    result.append({
                        "kind": "image",
                        "mime_type": item.get("mime_type") or "image/*",
                        "data_url": data_url,
                    })
        return result
