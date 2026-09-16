"""Realtime ASR bridge for v2 clients.

This service owns client WebSocket orchestration, session persistence, billing,
and API-pool reporting. Provider-specific WebSocket protocols live under
``app.providers.realtime_asr_*``.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import replace
from typing import Optional

from fastapi import WebSocket
from starlette.websockets import WebSocketDisconnect
from websockets.exceptions import ConnectionClosed

from app.data.credits.models import BreakdownItem, CreditLedgerEntry
from app.data.credits.repository import CreditLedgerRepository
from app.providers.realtime_asr.base import (
    RealtimeASRConfig,
    RealtimeASREvent,
    get_realtime_asr_provider,
)
from app.repositories.realtime_asr_session_repository import RealtimeASRSessionRepository
from app.services.infra.api_pool_client import PoolKeyInfo, report_error, report_usage
from app.services.billing.credit_account_service import CreditAccountService
from app.services.billing.credit_calculator import CreditCalculator
from app.repositories.plan_repository import PlanRepository
from app.services.audio.realtime_asr_session_waiter import notify_realtime_asr_completed
from app.services.infra.runtime_provider_config import pick_key_for_node

logger = logging.getLogger("voice_input.realtime_asr")

SUPPORTED_SAMPLE_RATES = {8000, 16000}
SUPPORTED_AUDIO_FORMATS = {"pcm", "opus"}
DEFAULT_NODE_ID = "asr_realtime_transcribe"
PROVIDER_SEND_TIMEOUT_SEC = 10.0
AUDIO_QUEUE_MAX_CHUNKS = 512


class RealtimeASRService:
    def __init__(self) -> None:
        self._plan_repo = PlanRepository()
        self._credit_account = CreditAccountService()

    async def bridge(self, client_ws: WebSocket, cfg: RealtimeASRConfig) -> None:
        key_info: Optional[PoolKeyInfo] = None
        provider_adapter = None
        session_repo = RealtimeASRSessionRepository()
        bytes_received = 0
        start = time.monotonic()
        final_text = ""
        latest_partial_text = ""
        final_language = ""
        completed_segments: list[str] = []
        partial_events = 0
        completed_events = 0
        first_partial_ms: Optional[int] = None
        last_partial_ms: Optional[int] = None
        credits_charged = 0
        credits_remaining: Optional[int] = None
        charged = False
        done = asyncio.Event()
        audio_queue: asyncio.Queue[tuple[str, bytes]] = asyncio.Queue(maxsize=AUDIO_QUEUE_MAX_CHUNKS)
        session_task: Optional[asyncio.Task] = None
        terminal_error = ""
        session_terminal = False
        session_terminal_lock = asyncio.Lock()

        async def mark_session_completed(
            *,
            transcript: str,
            language: str,
            duration: float,
        ) -> None:
            nonlocal session_terminal
            if not cfg.asr_session_id:
                return
            async with session_terminal_lock:
                if session_terminal:
                    return
                await session_repo.complete(
                    asr_session_id=cfg.asr_session_id,
                    user_email=cfg.user_email,
                    platform=cfg.platform,
                    final_text=transcript,
                    language=language,
                    duration_sec=duration,
                    bytes_received=bytes_received,
                )
                session_terminal = True
            await notify_realtime_asr_completed(cfg.asr_session_id)

        async def mark_session_failed(message: str) -> None:
            nonlocal session_terminal
            if not cfg.asr_session_id:
                return
            async with session_terminal_lock:
                if session_terminal:
                    return
                await session_repo.fail(
                    asr_session_id=cfg.asr_session_id,
                    user_email=cfg.user_email,
                    platform=cfg.platform,
                    error_message=message,
                )
                session_terminal = True
            await notify_realtime_asr_completed(cfg.asr_session_id)

        try:
            # 额度检查保持在前(廉价 Mongo 读),不改"无额度直接拒绝"语义。
            await self._credit_account.ensure_available(cfg.user_email)
            # P1 降开口延迟:会话落库(Mongo 写)与下面"取 key + 连上游"(~200-300ms)并行,
            # 把这次写入移出 ready 关键路径;发 ready 前再 await 它,保证记录已落库。
            if cfg.asr_session_id:
                session_task = asyncio.create_task(session_repo.create_streaming(
                    asr_session_id=cfg.asr_session_id,
                    user_email=cfg.user_email,
                    platform=cfg.platform,
                    language=cfg.language,
                    audio_format=cfg.audio_format,
                    sample_rate=cfg.sample_rate,
                    max_duration_sec=cfg.max_duration_sec,
                ))
            key_info, node, provider = await pick_key_for_node(DEFAULT_NODE_ID, expected_category="asr_realtime")
            implementation = provider.implementation or key_info.platform_code
            provider_adapter = get_realtime_asr_provider(implementation)
            logger.info(
                "[RealtimeASR] connect provider=%s impl=%s group=%s platform=%s",
                key_info.provider_id,
                implementation,
                key_info.group_id,
                cfg.platform,
            )
            provider_cfg = replace(cfg, language=self._provider_audio_language(cfg, implementation, provider.config))
            await provider_adapter.connect(
                key_info=key_info,
                cfg=provider_cfg,
                provider_config=provider.config,
            )
            if session_task is not None:
                # 发 ready 前确保会话记录已落库,避免后续 complete/fail 找不到记录。
                await session_task
                session_task = None
            await client_ws.send_json({
                "type": "ready",
                "asr_session_id": cfg.asr_session_id,
                "sample_rate": cfg.sample_rate,
                "audio_format": cfg.audio_format,
                "max_duration_sec": cfg.max_duration_sec,
                **provider_adapter.ready_payload,
            })

            async def from_client() -> None:
                nonlocal bytes_received, terminal_error
                try:
                    while not done.is_set():
                        if time.monotonic() - start > cfg.max_duration_sec:
                            await audio_queue.put(("finish", b""))
                            break
                        msg = await client_ws.receive()
                        msg_type = msg.get("type")
                        if msg_type == "websocket.disconnect":
                            done.set()
                            break
                        if "bytes" in msg and msg["bytes"] is not None:
                            chunk = msg["bytes"]
                            if not chunk:
                                continue
                            bytes_received += len(chunk)
                            await audio_queue.put(("audio", chunk))
                            continue
                        if "text" in msg and msg["text"] is not None:
                            try:
                                payload = json.loads(msg["text"])
                            except json.JSONDecodeError:
                                continue
                            command = str(payload.get("type") or "").strip().lower()
                            if command in {"finish", "stop"}:
                                await audio_queue.put(("finish", b""))
                                break
                            if command == "commit" and not cfg.use_vad:
                                await audio_queue.put(("commit", b""))
                except WebSocketDisconnect:
                    done.set()
                except ConnectionClosed as exc:
                    message = f"ASR upstream websocket closed while sending audio: {exc}"
                    terminal_error = message
                    logger.warning("[RealtimeASR] client->provider loop connection closed: %s", exc)
                    if key_info:
                        await report_error(key_info, message[:500])
                    await mark_session_failed(message)
                    try:
                        await client_ws.send_json({"type": "error", "message": message})
                    except Exception:
                        pass
                    done.set()
                except Exception as exc:
                    message = f"ASR streaming send failed: {exc}"
                    terminal_error = message
                    logger.warning("[RealtimeASR] client->provider loop failed: %s", exc)
                    if key_info:
                        await report_error(key_info, message[:500])
                    await mark_session_failed(message)
                    try:
                        await client_ws.send_json({"type": "error", "message": message})
                    except Exception:
                        pass
                    done.set()

            async def to_provider() -> None:
                nonlocal terminal_error
                try:
                    while not done.is_set():
                        command, chunk = await audio_queue.get()
                        try:
                            if command == "audio":
                                await asyncio.wait_for(
                                    provider_adapter.send_audio(chunk),
                                    timeout=PROVIDER_SEND_TIMEOUT_SEC,
                                )
                            elif command == "commit":
                                await asyncio.wait_for(
                                    provider_adapter.commit(),
                                    timeout=PROVIDER_SEND_TIMEOUT_SEC,
                                )
                            elif command == "finish":
                                await asyncio.wait_for(
                                    provider_adapter.finish(),
                                    timeout=PROVIDER_SEND_TIMEOUT_SEC,
                                )
                                break
                        finally:
                            audio_queue.task_done()
                except asyncio.CancelledError:
                    raise
                except ConnectionClosed as exc:
                    message = f"ASR upstream websocket closed while sending audio: {exc}"
                    terminal_error = message
                    logger.warning("[RealtimeASR] provider send loop connection closed: %s", exc)
                    if key_info:
                        await report_error(key_info, message[:500])
                    await mark_session_failed(message)
                    try:
                        await client_ws.send_json({"type": "error", "message": message})
                    except Exception:
                        pass
                    done.set()
                except Exception as exc:
                    message = f"ASR upstream send failed: {exc}"
                    terminal_error = message
                    logger.warning("[RealtimeASR] provider send loop failed: %s", exc)
                    if key_info:
                        await report_error(key_info, message[:500])
                    await mark_session_failed(message)
                    try:
                        await client_ws.send_json({"type": "error", "message": message})
                    except Exception:
                        pass
                    done.set()

            async def from_provider() -> None:
                nonlocal final_text, latest_partial_text, final_language, credits_charged, credits_remaining, charged
                nonlocal terminal_error
                nonlocal partial_events, completed_events, first_partial_ms, last_partial_ms
                try:
                    async for event in provider_adapter.events():
                        if event.type == "partial":
                            partial_events += 1
                            now_ms = int((time.monotonic() - start) * 1000)
                            if first_partial_ms is None:
                                first_partial_ms = now_ms
                            last_partial_ms = now_ms
                            text = self._partial_text(completed_segments, event)
                            latest_partial_text = text
                            final_language = event.language or final_language or ""
                            await client_ws.send_json({
                                "type": "partial",
                                "text": text,
                                "confirmed_text": event.confirmed_text,
                                "stash": event.stash,
                                "language": final_language,
                                "emotion": event.emotion,
                            })
                        elif event.type == "completed":
                            completed_events += 1
                            transcript = str(event.transcript or event.text or "")
                            if transcript:
                                completed_segments.append(transcript)
                                final_text = event.text.strip() if event.text else self._join_transcripts(completed_segments)
                                latest_partial_text = final_text
                            final_language = event.language or final_language or ""
                            await client_ws.send_json({
                                "type": "completed",
                                "text": final_text,
                                "transcript": final_text,
                                "language": final_language,
                                "emotion": event.emotion,
                            })
                        elif event.type == "error":
                            message = event.message
                            await client_ws.send_json({"type": "error", "message": message})
                            if key_info:
                                await report_error(key_info, message)
                            terminal_error = message
                            await mark_session_failed(message)
                            done.set()
                            break
                        elif event.type == "finished":
                            duration = self._duration_sec(bytes_received, cfg)
                            provider_final_text = str(event.text or event.transcript or "").strip()
                            transcript = provider_final_text or self._resolve_finished_transcript(final_text, latest_partial_text)
                            if provider_final_text:
                                final_text = provider_final_text
                                latest_partial_text = provider_final_text
                            final_language = event.language or final_language or ""
                            await mark_session_completed(
                                transcript=transcript,
                                language=final_language,
                                duration=duration,
                            )
                            credits_charged, credits_remaining = await self._charge_realtime_asr(
                                key_info, cfg, duration, transcript,
                            )
                            charged = True
                            logger.info(
                                "[RealtimeASR] finished platform=%s duration=%.2fs bytes=%d "
                                "partials=%d completed=%d first_partial_ms=%s last_partial_ms=%s "
                                "segments=%d final_chars=%d partial_chars=%d returned_chars=%d "
                                "returned_preview=%r",
                                cfg.platform,
                                duration,
                                bytes_received,
                                partial_events,
                                completed_events,
                                first_partial_ms,
                                last_partial_ms,
                                len(completed_segments),
                                len(final_text),
                                len(latest_partial_text),
                                len(transcript),
                                transcript[:80],
                            )
                            await client_ws.send_json({
                                "type": "finished",
                                "asr_session_id": cfg.asr_session_id,
                                "text": transcript,
                                "transcript": transcript,
                                "language": final_language,
                                "duration_sec": round(duration, 2),
                                "credits_charged": credits_charged,
                                "credits_remaining": credits_remaining,
                            })
                            done.set()
                            break
                        elif event.type == "provider_event":
                            await client_ws.send_json({
                                "type": "provider_event",
                                "event": event.provider_event,
                            })
                except WebSocketDisconnect:
                    done.set()
                except ConnectionClosed as exc:
                    message = f"ASR upstream websocket closed: {exc}"
                    terminal_error = message
                    logger.warning("[RealtimeASR] provider connection closed: %s", exc)
                    if key_info:
                        await report_error(key_info, message[:500])
                    await mark_session_failed(message)
                    try:
                        await client_ws.send_json({"type": "error", "message": message})
                    except Exception:
                        pass
                    done.set()
                except Exception as exc:
                    message = f"ASR upstream error: {exc}"
                    terminal_error = message
                    logger.warning("[RealtimeASR] provider loop failed: %s", exc)
                    if key_info:
                        await report_error(key_info, message[:500])
                    await mark_session_failed(message)
                    try:
                        await client_ws.send_json({"type": "error", "message": message})
                    except Exception:
                        pass
                    done.set()

            client_task = asyncio.create_task(from_client())
            provider_sender_task = asyncio.create_task(to_provider())
            provider_task = asyncio.create_task(from_provider())
            await done.wait()
            for task in (client_task, provider_sender_task, provider_task):
                if not task.done():
                    task.cancel()
            await asyncio.gather(client_task, provider_sender_task, provider_task, return_exceptions=True)

            duration = self._duration_sec(bytes_received, cfg)
            # 断连/异常兜底结算:provider 未发 finished(如客户端主动断开连接)时,用户已获得流式转写
            # 却未在 finished 分支扣费,这里按已接收音频时长补扣,避免逃费。terminal_error(上游错误)
            # 不结算——服务失败不向用户收费;_charge_realtime_asr 内部余额不足会扣到可用余额(部分扣款)。
            if not charged and not terminal_error and cfg.user_email and duration > 0 and key_info:
                try:
                    settle_text = (final_text or latest_partial_text or "").strip()
                    credits_charged, credits_remaining = await self._charge_realtime_asr(
                        key_info, cfg, duration, settle_text,
                    )
                    charged = True
                except Exception as exc:
                    logger.warning(
                        "[RealtimeASR] settle-on-close failed email=%s error=%s",
                        cfg.user_email, exc,
                    )
            if key_info:
                await report_usage(
                    key_info,
                    seconds_used=duration,
                    requests_used=1,
                    operation=DEFAULT_NODE_ID,
                    user_email=cfg.user_email,
                    latency_ms=int((time.monotonic() - start) * 1000),
                    success=not terminal_error,
                    error_message=terminal_error[:500],
                    client_platform=cfg.platform,
                )
        except Exception as exc:
            logger.exception("[RealtimeASR] bridge failed: %s", exc)
            try:
                await mark_session_failed(str(exc))
            except Exception:
                pass
            if key_info:
                await report_error(key_info, str(exc)[:500])
                await report_usage(
                    key_info,
                    seconds_used=self._duration_sec(bytes_received, cfg),
                    requests_used=1,
                    operation=DEFAULT_NODE_ID,
                    user_email=cfg.user_email,
                    latency_ms=int((time.monotonic() - start) * 1000),
                    success=False,
                    error_message=str(exc)[:500],
                    client_platform=cfg.platform,
                )
            try:
                await client_ws.send_json({"type": "error", "message": str(exc)})
            except Exception:
                pass
        finally:
            if session_task is not None and not session_task.done():
                # 连上游失败等异常路径:回收并行的落库任务,避免悬挂的待处理任务告警。
                try:
                    await session_task
                except Exception:
                    pass
            if provider_adapter is not None:
                try:
                    await provider_adapter.close()
                except Exception:
                    pass

    async def _charge_realtime_asr(
        self,
        key_info: PoolKeyInfo,
        cfg: RealtimeASRConfig,
        duration_sec: float,
        transcript: str,
    ) -> tuple[int, Optional[int]]:
        if not cfg.user_email or duration_sec <= 0:
            return 0, None
        ratio = await self._plan_repo.get_platform_credit_ratio()
        calc = CreditCalculator(ratio)
        cost = calc.audio_cost(duration_sec, key_info)
        if cost <= 0:
            return 0, None
        # 余额不足时扣到可用余额(部分扣款),避免整单不足即抛异常零扣费导致逃费。
        balance = await self._credit_account.get_balance(cfg.user_email)
        cost = min(cost, int(balance.get("total_remaining", 0) or 0))
        if cost <= 0:
            return 0, int(balance.get("total_remaining", 0) or 0)
        remaining, deductions = await self._credit_account.charge(cfg.user_email, cost)
        try:
            await CreditLedgerRepository().insert(CreditLedgerEntry(
                user_email=cfg.user_email,
                operation=DEFAULT_NODE_ID,
                client_platform=cfg.platform,
                total_credits=cost,
                breakdown=[BreakdownItem(
                    platform=f"{key_info.platform_code}_asr_realtime",
                    credits=cost,
                    audio_duration_sec=round(duration_sec, 2),
                    audio_chars=len(transcript or ""),
                )],
                deductions=deductions,
            ))
        except Exception as exc:
            logger.warning("[RealtimeASR] credit ledger insert failed: %s", exc)
        return cost, remaining

    @staticmethod
    def _duration_sec(bytes_received: int, cfg: RealtimeASRConfig) -> float:
        if cfg.audio_format == "pcm" and cfg.sample_rate > 0:
            return bytes_received / float(cfg.sample_rate * 2)
        elapsed_estimate = min(cfg.max_duration_sec, max(0.0, bytes_received / 32000.0))
        return elapsed_estimate

    @staticmethod
    def _resolve_finished_transcript(final_text: str, latest_partial_text: str) -> str:
        final = (final_text or "").strip()
        partial = (latest_partial_text or "").strip()
        if not partial:
            return final
        if not final:
            return partial
        if len(partial) > len(final) and (partial.startswith(final) or final in partial):
            return partial
        return final

    @staticmethod
    def _provider_audio_language(
        cfg: RealtimeASRConfig,
        implementation: str,
        provider_config: Optional[dict],
    ) -> str:
        impl = str(implementation or "").strip().lower()
        if impl not in {"volcengine_realtime", "doubao_realtime", "seed_asr_realtime"}:
            return ""
        config = provider_config if isinstance(provider_config, dict) else {}
        mode = str(config.get("asr_language_mode") or "client_ui_non_zh").strip().lower()
        if mode in {"auto", "none", "off", "disabled"}:
            return ""
        language = str(cfg.language or "").strip()
        if not language:
            return ""
        normalized = language.lower().replace("_", "-")
        if normalized.startswith("zh"):
            return ""
        return language

    @staticmethod
    def _partial_text(completed_segments: list[str], event: RealtimeASREvent) -> str:
        text = (event.text or "").strip()
        if not completed_segments:
            return text
        if text and (text.startswith(completed_segments[0]) or text.startswith(RealtimeASRService._join_transcripts(completed_segments))):
            return text
        return RealtimeASRService._join_transcripts([*completed_segments, text])

    @staticmethod
    def _join_transcripts(segments: list[str]) -> str:
        result = ""
        for raw in segments:
            segment = str(raw or "").strip()
            if not segment:
                continue
            if not result:
                result = segment
                continue
            if (
                result[-1].isspace()
                or segment[0] in "，。！？；：,.!?;:"
                or RealtimeASRService._is_cjk(result[-1])
                or RealtimeASRService._is_cjk(segment[0])
            ):
                result += segment
            else:
                result += " " + segment
        return result

    @staticmethod
    def _is_cjk(char: str) -> bool:
        return bool(char) and "\u4e00" <= char <= "\u9fff"
