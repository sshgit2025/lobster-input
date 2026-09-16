"""Realtime ASR provider contract.

Realtime ASR is a streaming capability, so it intentionally has a different
contract from file-based ``BaseASRProvider.transcribe``.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, AsyncIterator, Optional

if TYPE_CHECKING:
    from app.services.infra.api_pool_client import PoolKeyInfo


@dataclass
class RealtimeASRConfig:
    platform: str
    user_email: str
    asr_session_id: str = ""
    language: str = ""
    audio_format: str = "pcm"
    sample_rate: int = 16000
    use_vad: bool = True
    threshold: float = 0.0
    silence_duration_ms: int = 400
    max_duration_sec: int = 60
    corpus_text: str = ""


@dataclass
class RealtimeASREvent:
    type: str
    text: str = ""
    transcript: str = ""
    confirmed_text: str = ""
    stash: str = ""
    language: str = ""
    emotion: str = ""
    message: str = ""
    provider_event: str = ""


class BaseRealtimeASRProvider(ABC):
    """Provider interface for streaming ASR WebSocket protocols."""

    ready_payload: dict[str, Any]

    def __init__(self) -> None:
        self.ready_payload = {}

    @abstractmethod
    async def connect(
        self,
        *,
        key_info: PoolKeyInfo,
        cfg: RealtimeASRConfig,
        provider_config: Optional[dict[str, Any]] = None,
    ) -> None:
        """Open the provider connection and send any initial session request."""

    @abstractmethod
    async def send_audio(self, chunk: bytes) -> None:
        """Send a client audio chunk to the provider."""

    @abstractmethod
    async def commit(self) -> None:
        """Commit the current audio buffer when the provider supports it."""

    @abstractmethod
    async def finish(self) -> None:
        """Signal end of stream to the provider."""

    @abstractmethod
    async def events(self) -> AsyncIterator[RealtimeASREvent]:
        """Yield normalized provider events."""

    @abstractmethod
    async def close(self) -> None:
        """Close any provider resources."""


_REALTIME_ASR_REGISTRY: dict[str, type[BaseRealtimeASRProvider]] = {}


def register_realtime_asr(name: str, cls: type[BaseRealtimeASRProvider]) -> None:
    _REALTIME_ASR_REGISTRY[name.lower()] = cls


def get_realtime_asr_provider(name: str) -> BaseRealtimeASRProvider:
    cls = _REALTIME_ASR_REGISTRY.get(name.lower())
    if cls is None:
        raise ValueError(
            f"Unknown realtime ASR provider: '{name}'. "
            f"Available: {list(_REALTIME_ASR_REGISTRY.keys())}"
        )
    return cls()
