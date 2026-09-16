"""v2 text-first processing pipelines.

v2 receives final realtime-ASR text from clients and then runs the same
downstream business nodes as the v1 standard audio flow. It intentionally keeps
its own pipeline classes and flow_name so v1/v2 can diverge later without
touching each other.
"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Optional

from app.core.config import settings
from app.data.credits.models import CreditLedgerEntry
from app.data.credits.repository import CreditLedgerRepository
from app.core.exceptions import CreditsExhaustedException, ServiceTemporarilyUnavailableException
from app.models.schemas import AudioTranscribeResponse
from app.repositories.persona_repository import PersonaRepository
from app.repositories.plan_repository import PlanRepository
from app.services.pipeline.v2.agent_pipeline import AgentPipeline
from app.services.pipeline.v2.audio_pipeline import AudioProcessPipeline, PipelineContext
from app.services.billing.credit_account_service import CreditAccountService
from app.services.billing.credit_calculator import CreditCalculator
from app.services.infra.failure_guard import FailureGuard
from app.services.pipeline.v2.rewrite_pipeline import RewritePipeline
from app.services.pipeline.transcribe_routing import is_pure_interjection
from app.core.lang_utils import normalize_lang
from app.core.language_detection import detect_language

logger = logging.getLogger("voice_input.v2.text_pipeline")


@dataclass
class V2PlatformPipelineSet:
    transcribe: "V2TextPipelineMixin"
    rewrite: "V2TextPipelineMixin"
    agent: Optional["V2TextPipelineMixin"]
    _default: "V2TextPipelineMixin"

    def get(self, operation: str) -> "V2TextPipelineMixin":
        mapping = {
            "transcribe": self.transcribe,
            "rewrite": self.rewrite,
        }
        if self.agent is not None:
            mapping["agent"] = self.agent
        return mapping.get(operation, self._default)


class V2TextPipelineMixin:
    """Mixin that replaces v1 file/ASR steps with direct text input."""

    _plan_repo: PlanRepository
    _persona_repo: PersonaRepository
    _credit_account: CreditAccountService

    async def execute_text(
        self,
        text: str,
        operation: str,
        selected_text: Optional[str] = None,
        clipboard_history: Optional[list[str]] = None,
        clipboard_items: Optional[list[dict[str, Any]]] = None,
        provider: Optional[str] = None,
        model: Optional[str] = None,
        user_email: Optional[str] = None,
        openclaw_status: Optional[str] = None,
        openclaw_session_active: bool = False,
        client_platform: str = "",
        client_ui_lang: str = "",
        flow_name: str = "v2",
        fast_mode: bool = False,
        transcript_language: str = "",
        stream_callback: Optional[Callable[[str], Awaitable[None]]] = None,
        stream_event_callback: Optional[Callable[[str, dict[str, Any]], Awaitable[None]]] = None,
    ) -> AudioTranscribeResponse:
        t0 = time.monotonic()
        ctx_for_refund: Optional[PipelineContext] = None

        def _ms(start: float) -> int:
            return int((time.monotonic() - start) * 1000)

        try:
            if FailureGuard.is_frozen(user_email):
                remain = FailureGuard.remaining_freeze_sec(user_email)
                raise ServiceTemporarilyUnavailableException(
                    f"Too many consecutive failures, retry after {remain}s"
                )

            await self._check_credits(user_email)
            persona_active = await self._is_persona_active(user_email, operation, client_platform)
            effective_fast_mode = fast_mode and operation == "transcribe" and not persona_active
            if fast_mode and operation == "transcribe" and persona_active:
                logger.info(
                    "[V2TextPipeline] transcribe fast_mode disabled by active persona: user=%s platform=%s",
                    user_email or "<anonymous>", client_platform or "none",
                )

            ratio = await self._plan_repo.get_platform_credit_ratio()
            credit_calc = CreditCalculator(ratio)
            transcript = (text or "").strip()
            # 提示词语言以转写文本为权威；客户端传入的 transcript_language 仅兜底（实时 ASR 常为空），
            # client_ui_lang（UI 语言）只用于审计，不参与提示词路由。
            language = detect_language(transcript, fallback=transcript_language)
            if normalize_lang(transcript_language) and normalize_lang(transcript_language) != language:
                logger.info(
                    "[V2TextPipeline] prompt language resolved by text: "
                    "text_detected=%s client_reported=%s ui_lang=%s",
                    language or "default",
                    normalize_lang(transcript_language) or "none",
                    client_ui_lang or "none",
                )
            ctx = PipelineContext(
                operation=operation,
                transcript=transcript,
                transcript_language=language,
                result=transcript,
                selected_text=selected_text,
                clipboard_history=self._clean_clipboard_history(clipboard_history),
                clipboard_items=self._clean_clipboard_items(clipboard_items),
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

            logger.info(
                "[V2TextPipeline] START operation=%s user=%s platform=%s chars=%d "
                "has_selected=%s clipboard_count=%d clipboard_item_count=%d",
                operation,
                user_email or "<anonymous>",
                client_platform or "none",
                len(ctx.transcript),
                bool(selected_text),
                len(ctx.clipboard_history),
                len(ctx.clipboard_items),
            )

            t_correction = time.monotonic()
            await self._prepare_transcript(ctx)
            logger.info("[V2TextPipeline][timing] correction_prepare=%dms", _ms(t_correction))

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
                logger.info("[V2TextPipeline][timing] invoke_llm=%dms", _ms(t_llm))
            else:
                logger.info(
                    "[V2TextPipeline] LLM skipped operation=%s fast_mode=%s transcript_len=%d",
                    operation, ctx.fast_mode, len(ctx.transcript),
                )

            if ctx.user_email:
                self._memory.add_turn(
                    ctx.user_email,
                    ctx.transcript,
                    ctx.result,
                    operation=ctx.operation,
                    selected_text=ctx.selected_text,
                )

            ctx.action_type = self.resolve_action_type(ctx)

            credits_remaining = ctx.credits_remaining
            deductions = ctx.deductions
            if ctx.credits_cost > 0:
                t_deduct = time.monotonic()
                credits_remaining, deductions = await self._charge_uncovered_credits(ctx)
                logger.info("[V2TextPipeline][timing] deduct_credits=%dms", _ms(t_deduct))

            if user_email and ctx.credits_breakdown:
                try:
                    await CreditLedgerRepository().insert(CreditLedgerEntry(
                        user_email=user_email,
                        operation=operation,
                        client_platform=client_platform,
                        total_credits=max(1, int(ctx.credits_cost or 0)),
                        breakdown=ctx.credits_breakdown,
                        deductions=deductions,
                    ))
                except Exception as exc:
                    logger.warning("[V2TextPipeline] credit_ledger insert failed: %s", exc)

            FailureGuard.record_success(user_email)
            logger.info("[V2TextPipeline][timing] total=%dms", _ms(t0))
            return self.build_response(ctx, credits_remaining=credits_remaining)

        except (CreditsExhaustedException, ServiceTemporarilyUnavailableException):
            if ctx_for_refund and ctx_for_refund.deductions:
                await self._credit_account.refund(
                    user_email, ctx_for_refund.deductions, ctx_for_refund.precharged_credits,
                )
            raise
        except Exception:
            if ctx_for_refund and ctx_for_refund.deductions:
                await self._credit_account.refund(
                    user_email, ctx_for_refund.deductions, ctx_for_refund.precharged_credits,
                )
            FailureGuard.record_failure(user_email)
            raise

    async def _prepare_transcript(self, ctx: PipelineContext) -> None:
        if ctx.fast_mode:
            logger.info("[V2TextPipeline] fast_mode enabled, correction skipped")
            return

        if (
            ctx.operation == "transcribe"
            and not ctx.persona_active
            and is_pure_interjection(ctx.transcript, ctx.transcript_language)
        ):
            ctx.result = ctx.transcript
            logger.info(
                "[V2TextPipeline] pure interjection, correction & LLM skipped (text=%r)",
                ctx.transcript,
            )
            return

        if settings.asr_correction_enabled and len(ctx.transcript) >= 2:
            await self._check_next_node_credits(ctx.user_email, ctx.credits_cost)
        ctx.transcript = await self._apply_asr_correction(
            ctx.transcript,
            ctx.transcript_language,
            ctx=ctx,
            user_email=ctx.user_email,
        )
        ctx.result = ctx.transcript

    @staticmethod
    def _clean_clipboard_history(items: Optional[list[str]]) -> list[str]:
        if not items:
            return []
        return [str(item)[:4000] for item in items[:10] if isinstance(item, str)]

    @staticmethod
    def _clean_clipboard_items(items: Optional[list[dict[str, Any]]]) -> list[dict[str, Any]]:
        if not items:
            return []
        # Reuse v1's validated JSON parser to keep identical clipping and image limits.
        raw = json.dumps(items, ensure_ascii=False, separators=(",", ":"))
        return AudioProcessPipeline._parse_clipboard_items(raw)


class V2TranscribePipeline(V2TextPipelineMixin, AudioProcessPipeline):
    """v2 transcribe text pipeline."""


class V2RewritePipeline(V2TextPipelineMixin, RewritePipeline):
    """v2 rewrite text pipeline."""


class V2AgentPipeline(V2TextPipelineMixin, AgentPipeline):
    """v2 agent text pipeline."""


MAC_V2_PIPELINES = V2PlatformPipelineSet(
    transcribe=V2TranscribePipeline(),
    rewrite=V2RewritePipeline(),
    agent=V2AgentPipeline(),
    _default=V2TranscribePipeline(),
)

IOS_V2_PIPELINES = V2PlatformPipelineSet(
    transcribe=V2TranscribePipeline(),
    rewrite=V2RewritePipeline(),
    agent=None,
    _default=V2TranscribePipeline(),
)

WINDOWS_V2_PIPELINES = V2PlatformPipelineSet(
    transcribe=V2TranscribePipeline(),
    rewrite=V2RewritePipeline(),
    agent=V2AgentPipeline(),
    _default=V2TranscribePipeline(),
)

ANDROID_V2_PIPELINES = V2PlatformPipelineSet(
    transcribe=V2TranscribePipeline(),
    rewrite=V2RewritePipeline(),
    agent=None,
    _default=V2TranscribePipeline(),
)
