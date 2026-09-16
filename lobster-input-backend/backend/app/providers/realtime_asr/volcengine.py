"""Volcengine Seed-ASR realtime provider."""
from __future__ import annotations

import asyncio
import gzip
import json
import logging
import threading
import time
import uuid
from typing import TYPE_CHECKING, Any, AsyncIterator, Optional
from urllib.parse import urlsplit, urlunsplit

from websockets.asyncio.client import connect as ws_connect

from app.providers.realtime_asr.base import (
    BaseRealtimeASRProvider,
    RealtimeASRConfig,
    RealtimeASREvent,
    register_realtime_asr,
)
from app.repositories.hotword_repository import HotWordRepository

if TYPE_CHECKING:
    from app.services.infra.api_pool_client import PoolKeyInfo

logger = logging.getLogger("voice_input.realtime_asr.volcengine")

_DEFAULT_ASYNC_PATH = "/api/v3/sauc/bigmodel_async"
_DEFAULT_NOSTREAM_PATH = "/api/v3/sauc/bigmodel_nostream"
_DEFAULT_ENDPOINT = f"wss://openspeech.bytedance.com{_DEFAULT_ASYNC_PATH}"
_DEFAULT_RESOURCE_ID = "volc.seedasr.sauc.duration"
_PROTOCOL_VERSION = 0x1
_HEADER_SIZE_WORDS = 0x1
_MESSAGE_FULL_CLIENT_REQUEST = 0x1
_MESSAGE_AUDIO_ONLY_REQUEST = 0x2
_MESSAGE_FULL_SERVER_RESPONSE = 0x9
_MESSAGE_ERROR = 0xF
_FLAGS_NO_SEQUENCE = 0x0
_FLAGS_FINAL_NO_SEQUENCE = 0x2
_SERIALIZATION_NONE = 0x0
_SERIALIZATION_JSON = 0x1
_COMPRESSION_NONE = 0x0
_COMPRESSION_GZIP = 0x1
_DEFAULT_END_WINDOW_SIZE_MS = 800
_DEFAULT_FORCE_TO_SPEECH_TIME_MS = 1000
_DEFAULT_HOTWORD_LIMIT = 100
_MAX_STREAM_HOTWORD_LIMIT = 100
_MAX_NOSTREAM_HOTWORD_LIMIT = 5000
_DEFAULT_LEADING_SILENCE_MS = 120
_MAX_LEADING_SILENCE_MS = 300
_HOTWORD_CACHE_TTL_SEC = 60.0
_HOTWORD_CACHE: dict[str, tuple[float, tuple[str, ...]]] = {}
_HOTWORD_CACHE_LOCK = threading.Lock()
_CONNECT_ATTEMPTS = 2


class VolcengineRealtimeASRProvider(BaseRealtimeASRProvider):
    """Volcengine Seed-ASR binary WebSocket adapter."""

    def __init__(self) -> None:
        super().__init__()
        self._ws = None
        self._key_info: Optional[PoolKeyInfo] = None
        self._cfg: Optional[RealtimeASRConfig] = None
        self._provider_config: dict[str, Any] = {}
        self._resource_id = _DEFAULT_RESOURCE_ID
        self._pending_audio: bytes = b""
        self._audio_started = False
        self._session_hotwords: tuple[str, ...] = ()

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
        self._resource_id = self._resolve_resource_id(key_info, self._provider_config)
        self._session_hotwords = await self._load_user_hotwords(cfg.user_email)
        endpoint = self._build_endpoint(key_info, self._provider_config, cfg)
        for attempt in range(1, _CONNECT_ATTEMPTS + 1):
            try:
                self._ws = await ws_connect(
                    endpoint,
                    additional_headers=self._build_headers(key_info, self._provider_config, self._resource_id),
                    ping_interval=20,
                    ping_timeout=20,
                    open_timeout=10,
                    close_timeout=5,
                    max_size=16 * 1024 * 1024,
                )
                break
            except Exception:
                if attempt >= _CONNECT_ATTEMPTS:
                    raise
                await asyncio.sleep(0.2 * attempt)
        await self._send_full_client_request()
        self.ready_payload = {
            "model": self._resource_id,
            "provider": "volcengine_realtime",
        }

    async def send_audio(self, chunk: bytes) -> None:
        if not chunk:
            return
        target_bytes = self._target_chunk_bytes()
        if target_bytes <= 0:
            await self._send_audio_payload(chunk, final=False)
            return
        self._pending_audio += chunk
        while len(self._pending_audio) >= target_bytes:
            payload = self._pending_audio[:target_bytes]
            self._pending_audio = self._pending_audio[target_bytes:]
            await self._send_audio_payload(payload, final=False)

    async def commit(self) -> None:
        if self._pending_audio:
            await self._send_audio_payload(self._pending_audio, final=False)
            self._pending_audio = b""

    async def finish(self) -> None:
        target_bytes = self._target_chunk_bytes()
        if target_bytes > 0:
            while len(self._pending_audio) > target_bytes:
                payload = self._pending_audio[:target_bytes]
                self._pending_audio = self._pending_audio[target_bytes:]
                await self._send_audio_payload(payload, final=False)
        await self._send_audio_payload(self._pending_audio, final=True)
        self._pending_audio = b""

    async def events(self) -> AsyncIterator[RealtimeASREvent]:
        if self._ws is None:
            return
        async for raw in self._ws:
            if not isinstance(raw, bytes):
                continue
            parsed = self._parse_response(raw)
            if parsed["type"] == "error":
                yield RealtimeASREvent(type="error", message=parsed["message"])
                continue
            payload = parsed.get("payload")
            if not isinstance(payload, dict):
                continue
            text = self._extract_text(payload)
            language = self._extract_language(payload)
            if text:
                if parsed["final"]:
                    yield RealtimeASREvent(type="finished", text=text, transcript=text, language=language)
                    continue
                yield RealtimeASREvent(type="partial", text=text, language=language)
            elif parsed["final"]:
                yield RealtimeASREvent(type="finished")

    async def close(self) -> None:
        if self._ws is not None:
            await self._ws.close()
            self._ws = None

    async def _send_full_client_request(self) -> None:
        if self._cfg is None:
            return
        audio = self._audio_config()
        request = self._request_config()
        payload = {
            "user": {
                "uid": (self._cfg.user_email or "lobster")[:128],
                "platform": self._cfg.platform,
            },
            "audio": audio,
            "request": request,
        }
        logger.info(
            "Volcengine realtime ASR request: resource=%s format=%s rate=%s "
            "mode=%s result_type=%s nonstream=%s end_window_size=%s force_to_speech_time=%s "
            "language=%s corpus_context_type=%s corpus_context_items=%d corpus_tables=%s",
            self._resource_id,
            audio.get("format"),
            audio.get("rate"),
            "nostream" if self._use_nostream_language_mode() else "async",
            request.get("result_type"),
            request.get("enable_nonstream"),
            request.get("end_window_size"),
            request.get("force_to_speech_time"),
            audio.get("language", ""),
            self._corpus_context_type(request),
            self._corpus_context_items(request),
            ",".join(self._corpus_table_keys(request)),
        )
        await self._send_packet(
            _MESSAGE_FULL_CLIENT_REQUEST,
            _FLAGS_NO_SEQUENCE,
            payload,
            serialization=_SERIALIZATION_JSON,
            compression=_COMPRESSION_GZIP,
        )

    async def _send_audio_payload(self, chunk: bytes, *, final: bool) -> None:
        if not final and chunk and not self._audio_started:
            chunk = self._leading_silence_bytes() + chunk
            self._audio_started = True
        elif final and chunk and not self._audio_started:
            chunk = self._leading_silence_bytes() + chunk
            self._audio_started = True
        await self._send_packet(
            _MESSAGE_AUDIO_ONLY_REQUEST,
            _FLAGS_FINAL_NO_SEQUENCE if final else _FLAGS_NO_SEQUENCE,
            chunk,
            serialization=_SERIALIZATION_NONE,
            compression=_COMPRESSION_GZIP,
        )

    async def _send_packet(
        self,
        message_type: int,
        flags: int,
        payload: Any,
        *,
        serialization: int,
        compression: int,
    ) -> None:
        if self._ws is None:
            return
        payload_bytes = self._encode_payload(payload, serialization, compression)
        header = bytes([
            (_PROTOCOL_VERSION << 4) | _HEADER_SIZE_WORDS,
            (message_type << 4) | flags,
            (serialization << 4) | compression,
            0x00,
        ])
        packet = header + len(payload_bytes).to_bytes(4, "big", signed=False) + payload_bytes
        await self._ws.send(packet)

    def _audio_config(self) -> dict[str, Any]:
        cfg = self._cfg
        assert cfg is not None
        if cfg.audio_format == "opus":
            audio = {"format": "ogg", "codec": "opus", "rate": cfg.sample_rate}
        else:
            audio = {"format": "pcm", "codec": "raw", "rate": cfg.sample_rate, "bits": 16, "channel": 1}
        language = self._normalize_language(cfg.language)
        if language:
            audio["language"] = language
        overrides = self._merged_extra_config().get("audio")
        if isinstance(overrides, dict):
            audio.update(overrides)
        return audio

    def _request_config(self) -> dict[str, Any]:
        cfg = self._cfg
        assert cfg is not None
        request: dict[str, Any] = {
            "model_name": self._merged_extra_config().get("model_name", "bigmodel"),
            "enable_punc": True,
            "enable_itn": True,
            "show_utterances": True,
            "result_type": "full",
            "enable_lid": True,
        }
        if not self._use_nostream_language_mode():
            request["enable_nonstream"] = True
        if cfg.use_vad:
            request["end_window_size"] = self._provider_end_window_size_ms(cfg)
            request["force_to_speech_time"] = _DEFAULT_FORCE_TO_SPEECH_TIME_MS
        overrides = self._merged_extra_config().get("request")
        if isinstance(overrides, dict):
            request.update(overrides)
        corpus = self._corpus_config()
        context = self._build_context(
            cfg.corpus_text,
            self._session_hotwords,
            self._hotword_limit(),
        )
        if context:
            corpus["context"] = context
        if corpus:
            request["corpus"] = corpus
        if cfg.use_vad:
            request["end_window_size"] = self._coerce_provider_end_window_size_ms(request.get("end_window_size"))
            if not request.get("force_to_speech_time"):
                request["force_to_speech_time"] = _DEFAULT_FORCE_TO_SPEECH_TIME_MS
        return request

    def _corpus_config(self) -> dict[str, Any]:
        extra = self._merged_extra_config()
        corpus: dict[str, Any] = {}
        configured = extra.get("corpus")
        if isinstance(configured, dict):
            corpus.update(configured)
        for key in (
            "boosting_table_id",
            "boosting_table_name",
            "correct_table_id",
            "correct_table_name",
        ):
            value = str(extra.get(key) or "").strip()
            if value:
                corpus[key] = value
        request_overrides = extra.get("request")
        if isinstance(request_overrides, dict) and isinstance(request_overrides.get("corpus"), dict):
            corpus.update(request_overrides["corpus"])
        return corpus

    def _provider_end_window_size_ms(self, cfg: RealtimeASRConfig) -> int:
        raw = self._merged_extra_config().get("end_window_size")
        if raw is None:
            raw = cfg.silence_duration_ms
        return self._coerce_provider_end_window_size_ms(raw)

    @staticmethod
    def _coerce_provider_end_window_size_ms(raw: Any) -> int:
        try:
            value = int(raw)
        except (TypeError, ValueError):
            value = _DEFAULT_END_WINDOW_SIZE_MS
        return min(6000, max(_DEFAULT_END_WINDOW_SIZE_MS, value))

    def _merged_extra_config(self) -> dict[str, Any]:
        data: dict[str, Any] = {}
        if isinstance(self._provider_config, dict):
            data.update(self._provider_config)
        if self._key_info and isinstance(self._key_info.extra_config, dict):
            data.update(self._key_info.extra_config)
        return data

    def _target_chunk_bytes(self) -> int:
        cfg = self._cfg
        if cfg is None or cfg.audio_format != "pcm":
            return 0
        raw_chunk_ms = self._merged_extra_config().get("chunk_ms", 200)
        try:
            chunk_ms = float(raw_chunk_ms)
        except (TypeError, ValueError):
            chunk_ms = 200.0
        chunk_ms = min(1000.0, max(100.0, chunk_ms))
        return max(1, int(cfg.sample_rate * 2 * chunk_ms / 1000.0))

    def _leading_silence_bytes(self) -> bytes:
        cfg = self._cfg
        if cfg is None or cfg.audio_format != "pcm":
            return b""
        raw_silence_ms = self._merged_extra_config().get("leading_silence_ms", _DEFAULT_LEADING_SILENCE_MS)
        try:
            silence_ms = int(raw_silence_ms)
        except (TypeError, ValueError):
            silence_ms = _DEFAULT_LEADING_SILENCE_MS
        silence_ms = min(_MAX_LEADING_SILENCE_MS, max(0, silence_ms))
        if silence_ms <= 0:
            return b""
        return b"\x00" * int(cfg.sample_rate * 2 * silence_ms / 1000)

    @classmethod
    def _build_endpoint(
        cls,
        key_info: PoolKeyInfo,
        provider_config: dict[str, Any],
        cfg: Optional[RealtimeASRConfig] = None,
    ) -> str:
        raw = key_info.base_url or provider_config.get("base_url") or _DEFAULT_ENDPOINT
        parsed = urlsplit(str(raw).strip())
        scheme = parsed.scheme
        if scheme in {"http", "https"}:
            scheme = "wss"
        if scheme not in {"ws", "wss"}:
            scheme = "wss"
        path = parsed.path or _DEFAULT_ASYNC_PATH
        known_paths = {
            "/",
            "/api/v3/auc/bigmodel/recognize/flash",
            "/api/v3/sauc/bigmodel",
            _DEFAULT_ASYNC_PATH,
            _DEFAULT_NOSTREAM_PATH,
        }
        if path in known_paths:
            path = _DEFAULT_NOSTREAM_PATH if cls._should_use_nostream_language_mode(cfg, provider_config, key_info) else _DEFAULT_ASYNC_PATH
        return urlunsplit((scheme, parsed.netloc, path, parsed.query, ""))

    def _use_nostream_language_mode(self) -> bool:
        return self._should_use_nostream_language_mode(self._cfg, self._provider_config, self._key_info)

    @staticmethod
    def _corpus_context_type(request: dict[str, Any]) -> str:
        corpus = request.get("corpus")
        context = corpus.get("context") if isinstance(corpus, dict) else None
        if isinstance(context, dict):
            return str(context.get("context_type") or "")
        if isinstance(context, str):
            try:
                data = json.loads(context)
            except json.JSONDecodeError:
                return "string"
            if isinstance(data, dict) and isinstance(data.get("hotwords"), list):
                return "hotwords"
            return "json_string"
        return type(context).__name__ if context is not None else ""

    @staticmethod
    def _corpus_context_items(request: dict[str, Any]) -> int:
        corpus = request.get("corpus")
        context = corpus.get("context") if isinstance(corpus, dict) else None
        data = context.get("context_data") if isinstance(context, dict) else None
        if isinstance(context, str):
            try:
                parsed = json.loads(context)
            except json.JSONDecodeError:
                return 0
            hotwords = parsed.get("hotwords") if isinstance(parsed, dict) else None
            return len(hotwords) if isinstance(hotwords, list) else 0
        return len(data) if isinstance(data, list) else 0

    @staticmethod
    def _corpus_table_keys(request: dict[str, Any]) -> list[str]:
        corpus = request.get("corpus")
        if not isinstance(corpus, dict):
            return []
        return [
            key for key in (
                "boosting_table_id",
                "boosting_table_name",
                "correct_table_id",
                "correct_table_name",
            )
            if corpus.get(key)
        ]

    @classmethod
    def _should_use_nostream_language_mode(
        cls,
        cfg: Optional[RealtimeASRConfig],
        provider_config: Optional[dict[str, Any]],
        key_info: Optional[PoolKeyInfo] = None,
    ) -> bool:
        if cfg is None:
            return False
        return str(cfg.platform or "").strip().lower() == "sync"

    @staticmethod
    def _build_headers(
        key_info: PoolKeyInfo,
        provider_config: dict[str, Any],
        resource_id: str,
    ) -> dict[str, str]:
        extra = {}
        if isinstance(provider_config, dict):
            extra.update(provider_config)
        if isinstance(key_info.extra_config, dict):
            extra.update(key_info.extra_config)
        headers = {
            "X-Api-Resource-Id": resource_id,
            "X-Api-Request-Id": str(uuid.uuid4()),
            "X-Api-Connect-Id": str(uuid.uuid4()),
            "user-agent": "lobster-input-backend/realtime-asr",
        }
        headers["X-Api-Key"] = key_info.api_key
        return headers

    @staticmethod
    def _resolve_resource_id(key_info: PoolKeyInfo, provider_config: dict[str, Any]) -> str:
        return str(
            key_info.model
            or provider_config.get("resource_id")
            or provider_config.get("model")
            or _DEFAULT_RESOURCE_ID
        ).strip()

    @staticmethod
    def _encode_payload(payload: Any, serialization: int, compression: int) -> bytes:
        if serialization == _SERIALIZATION_JSON:
            raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        elif isinstance(payload, bytes):
            raw = payload
        else:
            raw = bytes(payload or b"")
        if compression == _COMPRESSION_GZIP:
            return gzip.compress(raw)
        return raw

    @staticmethod
    def _parse_response(data: bytes) -> dict[str, Any]:
        if len(data) < 8:
            return {"type": "error", "message": "Volcengine realtime ASR: invalid response packet"}
        header_size = (data[0] & 0x0F) * 4
        message_type = (data[1] >> 4) & 0x0F
        flags = data[1] & 0x0F
        serialization = (data[2] >> 4) & 0x0F
        compression = data[2] & 0x0F
        offset = header_size
        sequence = None
        if flags in {0x1, 0x3}:
            sequence = int.from_bytes(data[offset:offset + 4], "big", signed=True)
            offset += 4
        final = flags in {0x2, 0x3} or (sequence is not None and sequence < 0)
        if message_type == _MESSAGE_ERROR:
            code = int.from_bytes(data[offset:offset + 4], "big", signed=False)
            offset += 4
            size = int.from_bytes(data[offset:offset + 4], "big", signed=False)
            offset += 4
            message = data[offset:offset + size]
            if compression == _COMPRESSION_GZIP:
                message = gzip.decompress(message)
            return {"type": "error", "message": f"{code}: {message.decode('utf-8', errors='replace')}"}
        if len(data) < offset + 4:
            return {"type": "error", "message": "Volcengine realtime ASR: missing payload size"}
        size = int.from_bytes(data[offset:offset + 4], "big", signed=False)
        offset += 4
        payload = data[offset:offset + size]
        if compression == _COMPRESSION_GZIP:
            payload = gzip.decompress(payload)
        if serialization == _SERIALIZATION_JSON:
            decoded: Any = json.loads(payload.decode("utf-8"))
        else:
            decoded = payload
        return {"type": "response", "payload": decoded, "final": final, "sequence": sequence}

    @staticmethod
    def _extract_text(payload: dict[str, Any]) -> str:
        result = payload.get("result")
        if isinstance(result, dict):
            return str(result.get("text") or "").strip()
        if isinstance(result, list):
            texts = [str(item.get("text") or "").strip() for item in result if isinstance(item, dict)]
            return "".join(item for item in texts if item).strip()
        return str(payload.get("text") or "").strip()

    @staticmethod
    def _extract_language(payload: dict[str, Any]) -> str:
        result = payload.get("result")
        additions = result.get("additions") if isinstance(result, dict) else None
        if isinstance(additions, dict):
            for key in ("language", "lid_lang", "lang"):
                if additions.get(key):
                    return str(additions[key])
        utterances = result.get("utterances") if isinstance(result, dict) else None
        if isinstance(utterances, list):
            for item in utterances:
                if isinstance(item, dict) and item.get("language"):
                    return str(item["language"])
        return ""

    @staticmethod
    def _normalize_language(language: str) -> str:
        value = str(language or "").strip().lower().replace("_", "-")
        if not value:
            return ""
        if value.startswith("yue"):
            return "yue-CN"
        if value.startswith("zh"):
            return ""
        if value.startswith("en"):
            return "en-US"
        if value.startswith("ko"):
            return "ko-KR"
        if value.startswith("ru"):
            return "ru-RU"
        if value.startswith("ja"):
            return "ja-JP"
        return value

    @staticmethod
    def _build_context(
        corpus_text: str,
        hotwords: tuple[str, ...] = (),
        limit: int = _DEFAULT_HOTWORD_LIMIT,
    ) -> str:
        text = str(corpus_text or "").strip()
        if text.startswith("{") and text.endswith("}"):
            return text[:20000]
        words = [
            item.strip()
            for item in [*hotwords, *text.replace("，", ",").split(",")]
            if item and item.strip()
        ]
        if not words:
            return ""
        deduped: list[str] = []
        seen: set[str] = set()
        for word in words:
            key = word.casefold()
            if key in seen:
                continue
            seen.add(key)
            deduped.append(word)
            if len(deduped) >= max(1, limit):
                break
        return json.dumps(
            {"hotwords": [{"word": word[:64]} for word in deduped]},
            ensure_ascii=False,
            separators=(",", ":"),
        )

    async def _load_user_hotwords(self, user_email: str) -> tuple[str, ...]:
        email = str(user_email or "").strip().lower()
        if not email:
            return ()
        limit = self._hotword_limit()
        now = time.monotonic()
        with _HOTWORD_CACHE_LOCK:
            cached = _HOTWORD_CACHE.get(email)
            if cached and now < cached[0]:
                return cached[1][:limit]

        try:
            docs = await HotWordRepository().list_by_user(email)
        except Exception as exc:
            logger.warning("Volcengine realtime ASR hotword load skipped user=%s error=%s", email, exc)
            return ()

        sorted_docs = sorted(docs, key=lambda item: item.created_at or "", reverse=True)
        words: list[str] = []
        seen: set[str] = set()
        for item in sorted_docs:
            word = item.word.strip()
            if not word:
                continue
            key = word.casefold()
            if key in seen:
                continue
            seen.add(key)
            words.append(word)
            if len(words) >= limit:
                break
        result = tuple(words)
        with _HOTWORD_CACHE_LOCK:
            _HOTWORD_CACHE[email] = (now + _HOTWORD_CACHE_TTL_SEC, result)
        logger.info("Volcengine realtime ASR loaded user hotwords user=%s count=%d limit=%d", email, len(result), limit)
        return result

    def _hotword_limit(self) -> int:
        raw = self._merged_extra_config().get("hotword_limit")
        if raw is None:
            raw = self._merged_extra_config().get("hotwords_limit")
        max_limit = _MAX_NOSTREAM_HOTWORD_LIMIT if self._use_nostream_language_mode() else _MAX_STREAM_HOTWORD_LIMIT
        if raw is None:
            return max_limit
        try:
            value = int(raw)
        except (TypeError, ValueError):
            value = max_limit
        return min(max_limit, max(1, value))


register_realtime_asr("volcengine_realtime", VolcengineRealtimeASRProvider)
register_realtime_asr("doubao_realtime", VolcengineRealtimeASRProvider)
register_realtime_asr("seed_asr_realtime", VolcengineRealtimeASRProvider)
