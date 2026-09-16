"""
WhisperExtractor — Whisper 语音识别用量提取器。

Whisper API 不返回 token 用量，改为统计：
  - audio_duration_sec: 音频文件时长（秒）
  - audio_chars: 识别结果字符数

platform 取值：
  "openai_whisper" 或 "groq_whisper"，由调用方通过 provider 参数传入。
"""
import logging
from pathlib import Path
from typing import Any, Optional

from app.data.usage.extractors.base import BaseUsageExtractor
from app.data.usage.models import UsageEvent

logger = logging.getLogger("voice_input.usage.whisper")


class WhisperExtractor(BaseUsageExtractor):
    """从 Whisper 识别结果中提取音频时长和字符数。"""

    def extract(self, response: Any, **kwargs) -> Optional[UsageEvent]:
        """
        Args:
            response: Whisper 识别结果文本（str）
            kwargs:
              user_email      (str):  用户邮箱
              operation       (str):  所属 operation（transcribe/rewrite/agent）
              provider        (str):  "openai" 或 "groq"
              audio_path      (Path): 音频文件路径，用于读取时长
              latency_ms      (int):  请求耗时
              api_key         (str):  调用使用的 API Key 原文（将被脱敏存储）
              client_platform (str):  客户端平台标识（来自请求头 X-Client-Platform）
        """
        user_email = kwargs.get("user_email", "")
        operation = kwargs.get("operation", "transcribe")
        provider = kwargs.get("provider", "openai")
        audio_path: Optional[Path] = kwargs.get("audio_path")
        latency_ms = kwargs.get("latency_ms", 0)
        api_key = kwargs.get("api_key", "")
        client_platform = kwargs.get("client_platform", "")

        if not user_email:
            return None

        transcript = response if isinstance(response, str) else ""
        audio_chars = len(transcript)
        audio_duration_sec = self._get_duration(audio_path) if audio_path else 0.0

        platform = f"{provider}_whisper"

        return UsageEvent(
            user_email=user_email,
            platform=platform,
            operation=operation,
            date=self._utc_date(),
            audio_duration_sec=audio_duration_sec,
            audio_chars=audio_chars,
            request_count=1,
            latency_ms=latency_ms,
            api_key_hint=self._mask_api_key(api_key),
            client_platform=client_platform,
        )

    @staticmethod
    def _get_duration(audio_path: Path) -> float:
        """读取音频文件时长（秒），失败时返回 0.0。"""
        try:
            from mutagen import File as MutagenFile
            audio = MutagenFile(str(audio_path))
            if audio is not None and audio.info is not None:
                return round(audio.info.length, 2)
        except Exception as e:
            logger.debug("WhisperExtractor: failed to read audio duration: %s", e)
        return 0.0
