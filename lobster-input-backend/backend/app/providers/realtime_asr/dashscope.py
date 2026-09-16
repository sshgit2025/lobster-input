"""DashScope Qwen realtime ASR provider."""
from __future__ import annotations

import base64
import json
import logging
import uuid
from typing import TYPE_CHECKING, Any, AsyncIterator, Optional
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from websockets.asyncio.client import connect as ws_connect

from app.core.config import settings
from app.providers.realtime_asr.base import (
    BaseRealtimeASRProvider,
    RealtimeASRConfig,
    RealtimeASREvent,
    register_realtime_asr,
)

if TYPE_CHECKING:
    from app.services.infra.api_pool_client import PoolKeyInfo

logger = logging.getLogger("voice_input.realtime_asr.dashscope")

_DEFAULT_ENDPOINT = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
_DEFAULT_MODEL = "qwen3-asr-flash-realtime"


class DashScopeRealtimeASRProvider(BaseRealtimeASRProvider):
    """Alibaba DashScope Qwen-ASR-Realtime WebSocket adapter."""

    def __init__(self) -> None:
        super().__init__()
        self._ws = None
        self._key_info: Optional[PoolKeyInfo] = None
        self._cfg: Optional[RealtimeASRConfig] = None
        self._provider_config: dict[str, Any] = {}
        self._item_order: list[str] = []
        self._preview_by_item: dict[str, str] = {}
        self._completed_by_item: dict[str, str] = {}
        self._active_item_id = ""
        self._last_language = ""
        self._last_emotion = ""

    async def connect(
        self,
        *,
        key_info: PoolKeyInfo,
        cfg: RealtimeASRConfig,
        provider_config: Optional[dict[str, Any]] = None,
    ) -> None:
        self._key_info = key_info
        self._cfg = cfg
        self._provider_config = provider_config or {}
        endpoint = self._build_endpoint(key_info, self._provider_config)
        self._ws = await ws_connect(
            endpoint,
            additional_headers=self._build_headers(key_info),
            ping_interval=20,
            ping_timeout=20,
            max_size=16 * 1024 * 1024,
        )
        await self._send_session_update()
        self.ready_payload = {
            "model": key_info.model or self._provider_config.get("model") or settings.realtime_asr_default_model,
            "provider": "dashscope_realtime",
        }

    async def send_audio(self, chunk: bytes) -> None:
        await self._send_json({
            "event_id": self._event_id(),
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(chunk).decode("ascii"),
        })

    async def commit(self) -> None:
        await self._send_json({
            "event_id": self._event_id(),
            "type": "input_audio_buffer.commit",
        })

    async def finish(self) -> None:
        await self._send_json({
            "event_id": self._event_id(),
            "type": "session.finish",
        })

    async def events(self) -> AsyncIterator[RealtimeASREvent]:
        if self._ws is None:
            return
        async for raw in self._ws:
            if isinstance(raw, bytes):
                continue
            try:
                event = json.loads(raw)
            except json.JSONDecodeError:
                continue
            event_type = str(event.get("type") or "")
            if event_type == "conversation.item.input_audio_transcription.text":
                item_id = self._resolve_item_id(event)
                confirmed = str(event.get("text") or "")
                stash = str(event.get("stash") or "")
                preview = confirmed + stash
                self._remember_item(item_id)
                self._active_item_id = item_id
                self._preview_by_item[item_id] = preview
                self._last_language = str(event.get("language") or self._last_language or "")
                self._last_emotion = str(event.get("emotion") or self._last_emotion or "")
                yield RealtimeASREvent(
                    type="partial",
                    text=self._full_text(),
                    confirmed_text=self._full_text(current_item_id=item_id, current_text=confirmed),
                    stash=stash,
                    language=self._last_language,
                    emotion=self._last_emotion,
                )
            elif event_type == "conversation.item.input_audio_transcription.completed":
                item_id = self._resolve_item_id(event)
                transcript = str(event.get("transcript") or "")
                self._remember_item(item_id)
                self._completed_by_item[item_id] = transcript
                self._preview_by_item.pop(item_id, None)
                if self._active_item_id == item_id:
                    self._active_item_id = ""
                self._last_language = str(event.get("language") or self._last_language or "")
                self._last_emotion = str(event.get("emotion") or self._last_emotion or "")
                yield RealtimeASREvent(
                    type="partial",
                    transcript=self._full_text(),
                    text=self._full_text(),
                    language=self._last_language,
                    emotion=self._last_emotion,
                )
            elif event_type in {
                "conversation.item.input_audio_transcription.failed",
                "error",
            }:
                yield RealtimeASREvent(type="error", message=self._extract_error_message(event))
            elif event_type == "session.finished":
                text = self._full_text()
                yield RealtimeASREvent(
                    type="finished",
                    text=text,
                    transcript=text,
                    language=self._last_language,
                    emotion=self._last_emotion,
                )
            elif event_type in {"session.created", "session.updated"}:
                yield RealtimeASREvent(type="provider_event", provider_event=event_type)

    async def close(self) -> None:
        if self._ws is not None:
            await self._ws.close()
            self._ws = None

    async def _send_session_update(self) -> None:
        if self._cfg is None:
            return
        transcription: dict[str, Any] = {}
        language = self._normalize_language(self._cfg.language)
        if language:
            transcription["language"] = language
        if self._cfg.corpus_text:
            transcription["corpus"] = {"text": self._cfg.corpus_text[:20000]}
        await self._send_json({
            "event_id": self._event_id(),
            "type": "session.update",
            "session": {
                "input_audio_format": self._cfg.audio_format,
                "sample_rate": self._cfg.sample_rate,
                "input_audio_transcription": transcription,
                "turn_detection": {
                    "type": "server_vad",
                    "threshold": self._cfg.threshold,
                    "silence_duration_ms": self._cfg.silence_duration_ms,
                } if self._cfg.use_vad else None,
            },
        }, ensure_ascii=False)

    async def _send_json(self, payload: dict[str, Any], *, ensure_ascii: bool = True) -> None:
        if self._ws is None:
            return
        await self._ws.send(json.dumps(payload, ensure_ascii=ensure_ascii, separators=(",", ":")))

    @staticmethod
    def _build_endpoint(key_info: PoolKeyInfo, provider_config: dict[str, Any]) -> str:
        raw = (
            key_info.base_url
            or provider_config.get("base_url")
            or settings.realtime_asr_default_base_url
            or _DEFAULT_ENDPOINT
        )
        model = key_info.model or provider_config.get("model") or settings.realtime_asr_default_model or _DEFAULT_MODEL
        parsed = urlsplit(str(raw).strip())
        scheme = parsed.scheme
        if scheme in {"http", "https"}:
            scheme = "wss"
        if scheme not in {"ws", "wss"}:
            scheme = "wss"
        path = parsed.path or "/api-ws/v1/realtime"
        if path in {"/", "/api/v1"}:
            path = "/api-ws/v1/realtime"
        query = dict(parse_qsl(parsed.query, keep_blank_values=True))
        query["model"] = model
        return urlunsplit((scheme, parsed.netloc, path, urlencode(query), ""))

    @staticmethod
    def _build_headers(key_info: PoolKeyInfo) -> dict[str, str]:
        headers = {
            "Authorization": f"Bearer {key_info.api_key}",
            "user-agent": "lobster-input-backend/realtime-asr",
        }
        workspace = (key_info.extra_config or {}).get("workspace") or (key_info.provider_config or {}).get("workspace")
        if workspace:
            headers["X-DashScope-WorkSpace"] = str(workspace)
        return headers

    @staticmethod
    def _normalize_language(language: str) -> str:
        value = str(language or "").strip().lower().replace("_", "-")
        if not value:
            return ""
        if value.startswith("zh"):
            return "zh"
        return value.split("-", 1)[0]

    @staticmethod
    def _extract_error_message(event: dict[str, Any]) -> str:
        err = event.get("error")
        if isinstance(err, dict):
            return str(err.get("message") or err.get("code") or err)
        return str(event.get("message") or event)

    def _resolve_item_id(self, event: dict[str, Any]) -> str:
        item_id = str(event.get("item_id") or "").strip()
        if item_id:
            return item_id
        return self._active_item_id or "__default__"

    def _remember_item(self, item_id: str) -> None:
        if item_id and item_id not in self._item_order:
            self._item_order.append(item_id)

    def _full_text(self, *, current_item_id: str = "", current_text: Optional[str] = None) -> str:
        segments: list[str] = []
        for item_id in self._item_order:
            if item_id == current_item_id and current_text is not None:
                text = current_text
            elif item_id in self._completed_by_item:
                text = self._completed_by_item[item_id]
            else:
                text = self._preview_by_item.get(item_id, "")
            if text:
                segments.append(text)
        return self._join_transcripts(segments)

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
                or DashScopeRealtimeASRProvider._is_cjk(result[-1])
                or DashScopeRealtimeASRProvider._is_cjk(segment[0])
            ):
                result += segment
            else:
                result += " " + segment
        return result

    @staticmethod
    def _is_cjk(char: str) -> bool:
        return bool(char) and "\u4e00" <= char <= "\u9fff"

    @staticmethod
    def _event_id() -> str:
        return f"event_{uuid.uuid4().hex}"


register_realtime_asr("dashscope_realtime", DashScopeRealtimeASRProvider)
register_realtime_asr("qwen_realtime", DashScopeRealtimeASRProvider)
register_realtime_asr("qwen3_asr_realtime", DashScopeRealtimeASRProvider)
