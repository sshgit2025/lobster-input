"""HarmonyOS v2 text processing and realtime ASR endpoints.

鸿蒙客户端完全复刻 Android 输入法行为，处理逻辑与 android.py 完全同构，
仅平台标识独立为 "harmony"（独立登录态、独立统计口径）。
流水线直接复用 ANDROID_V2_PIPELINES，不新建 HARMONY 流水线。
"""
from __future__ import annotations

import logging
import re
import uuid
from typing import Any

from fastapi import APIRouter, HTTPException, WebSocket, status

from app.core.config import settings
from app.decorators.client_context import ClientRequestContext, with_client_context
from app.models.schemas import AudioTranscribeResponse, TextProcessRequest
from app.repositories.realtime_asr_session_repository import RealtimeASRSessionRepository
from app.services.account.session_service import verify_websocket_user
from app.services.audio.realtime_asr import RealtimeASRConfig, RealtimeASRService
from app.services.audio.realtime_asr_session_waiter import wait_for_realtime_asr_final
from app.services.pipeline.v2.text_pipeline import ANDROID_V2_PIPELINES

logger = logging.getLogger("voice_input.api.v2.audio_harmony")

router = APIRouter(prefix="/audio/harmony", tags=["Audio v2 - Harmony"])

_HARMONY_PLATFORM = "harmony"
_HARMONY_ALLOWED_OPERATIONS = {"transcribe", "rewrite"}
_HARMONY_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,96}$")


@router.post(
    "/process",
    response_model=AudioTranscribeResponse,
    summary="HarmonyOS v2：处理实时 ASR 最终文本",
    description="HarmonyOS 专属 v2 接口，接收实时 ASR 最终文本并执行输入法业务管线（复用 Android 管线）。",
)
@with_client_context(client_platform=_HARMONY_PLATFORM, flow_name="v2")
async def harmony_process_realtime_text(
    payload: TextProcessRequest,
    client_context: ClientRequestContext,
) -> AudioTranscribeResponse:
    operation = (payload.operation or "").strip().lower()
    if operation not in _HARMONY_ALLOWED_OPERATIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="HarmonyOS 输入法仅支持 transcribe 和 rewrite",
        )

    resolved_text, resolved_language = await _resolve_harmony_realtime_transcript(
        payload=payload,
        user_email=client_context.user_email,
    )
    # 鸿蒙端行为与安卓完全一致，直接复用 Android v2 管线单例
    pipeline = ANDROID_V2_PIPELINES.get(operation)
    return await pipeline.execute_text(
        text=resolved_text,
        operation=operation,
        selected_text=payload.selected_text,
        clipboard_history=payload.clipboard_history,
        clipboard_items=payload.clipboard_items,
        provider=payload.provider,
        model=payload.model,
        user_email=client_context.user_email,
        openclaw_status=None,
        client_platform=client_context.client_platform,
        client_ui_lang=client_context.client_ui_lang,
        flow_name=client_context.flow_name,
        fast_mode=payload.fast_mode,
        transcript_language=resolved_language or "",
    )


@router.websocket("/asr/realtime")
async def harmony_realtime_asr(websocket: WebSocket) -> None:
    try:
        auth_payload = await _verify_harmony_websocket_user(websocket)
    except Exception as exc:
        logger.warning("[harmony v2 realtime_asr] auth failed: %s", exc)
        await websocket.close(code=1008)
        return

    await websocket.accept()
    query = websocket.query_params
    try:
        asr_session_id = _normalize_harmony_session_id(query.get("asr_session_id") or "")
    except HTTPException:
        await websocket.close(code=1008)
        return
    if not asr_session_id:
        asr_session_id = f"server_{uuid.uuid4().hex}"
    cfg = RealtimeASRConfig(
        platform=_HARMONY_PLATFORM,
        user_email=auth_payload.get("sub") or "",
        asr_session_id=asr_session_id,
        language=query.get("language") or query.get("lang") or "",
        audio_format=_normalize_harmony_audio_format(query.get("audio_format") or query.get("format") or "pcm"),
        sample_rate=_normalize_harmony_sample_rate(query.get("sample_rate")),
        use_vad=_parse_harmony_bool(query.get("vad"), default=True),
        threshold=_normalize_harmony_float(query.get("threshold"), default=0.0, min_value=-1.0, max_value=1.0),
        silence_duration_ms=_normalize_harmony_int(
            query.get("silence_duration_ms"), default=400, min_value=200, max_value=6000,
        ),
        max_duration_sec=_normalize_harmony_int(
            query.get("max_duration_sec"),
            default=settings.realtime_asr_max_duration_sec,
            min_value=1,
            max_value=settings.realtime_asr_max_duration_sec,
        ),
        corpus_text=(query.get("corpus_text") or "")[:20000],
    )
    await RealtimeASRService().bridge(websocket, cfg)


async def _resolve_harmony_realtime_transcript(
    *,
    payload: TextProcessRequest,
    user_email: str,
) -> tuple[str, str]:
    fallback_text = (
        payload.client_asr_text
        if payload.client_asr_text is not None
        else payload.text
    ) or ""
    fallback_language = payload.transcript_language or ""
    asr_session_id = _normalize_harmony_session_id(payload.asr_session_id or "")
    if not asr_session_id:
        return fallback_text, fallback_language

    repo = RealtimeASRSessionRepository()
    existing = await repo.find_by_session_id(asr_session_id)
    if existing and (
        existing.get("user_email") != user_email or existing.get("platform") != _HARMONY_PLATFORM
    ):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="ASR session owner mismatch")

    session = await wait_for_realtime_asr_final(
        asr_session_id=asr_session_id,
        user_email=user_email,
        platform=_HARMONY_PLATFORM,
        timeout_ms=settings.realtime_asr_v2_final_wait_ms,
    )
    if session and session.get("status") == "completed":
        final_text = str(session.get("final_text") or "").strip()
        if final_text:
            logger.info(
                "[harmony v2 audio] ASR session final resolved session=%s final_chars=%d "
                "fallback_chars=%d final_preview=%r",
                asr_session_id,
                len(final_text),
                len(fallback_text),
                final_text[:80],
            )
            return final_text, str(session.get("language") or fallback_language or "")
        logger.warning("[harmony v2 audio] ASR session completed with empty final: %s", asr_session_id)
    elif session and session.get("status") == "failed":
        logger.warning("[harmony v2 audio] ASR session failed, using client fallback: %s", asr_session_id)
    else:
        logger.info(
            "[harmony v2 audio] ASR session final wait timed out, using client fallback session=%s fallback_chars=%d",
            asr_session_id,
            len(fallback_text),
        )
    return fallback_text, fallback_language


async def _verify_harmony_websocket_user(websocket: WebSocket) -> dict[str, Any]:
    """WebSocket 鉴权：五端共用逻辑（含滑动窗口过期校验与异步续期）见 session_service。"""
    return await verify_websocket_user(websocket, _HARMONY_PLATFORM)


def _normalize_harmony_session_id(value: str) -> str:
    normalized = str(value or "").strip()
    if not normalized:
        return ""
    if not _HARMONY_SESSION_ID_RE.fullmatch(normalized):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid ASR session id")
    return normalized


def _normalize_harmony_audio_format(value: str) -> str:
    normalized = str(value or "pcm").strip().lower()
    return normalized if normalized in {"pcm", "opus"} else "pcm"


def _normalize_harmony_sample_rate(value: str | None) -> int:
    try:
        sample_rate = int(value or 16000)
    except ValueError:
        sample_rate = 16000
    return sample_rate if sample_rate in {8000, 16000} else 16000


def _parse_harmony_bool(value: str | None, *, default: bool) -> bool:
    if value is None:
        return default
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _normalize_harmony_int(value: str | None, *, default: int, min_value: int, max_value: int) -> int:
    try:
        parsed = int(value or default)
    except ValueError:
        parsed = default
    return max(min_value, min(max_value, parsed))


def _normalize_harmony_float(value: str | None, *, default: float, min_value: float, max_value: float) -> float:
    try:
        parsed = float(value if value is not None else default)
    except ValueError:
        parsed = default
    return max(min_value, min(max_value, parsed))
