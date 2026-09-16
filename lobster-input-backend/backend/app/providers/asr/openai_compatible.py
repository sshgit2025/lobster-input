"""
OpenAI 兼容 ASR 提供商。
支持所有兼容 OpenAI audio.transcriptions.create 接口的提供商:
  - OpenAI Whisper
  - Groq Whisper
  - 火山引擎方舟 Seed-ASR（OpenAI 兼容模式）
  - 任何实现了 OpenAI audio transcriptions 接口的服务

管理端配置:
  category       = asr
  implementation = openai_compatible
  pool_group_id  = 号池中的 OpenAI 兼容 ASR 分组
"""
import logging
from pathlib import Path
from typing import Optional

from app.providers.asr.base import BaseASRProvider, ASRResult, register
from app.services.infra.proxy_config import openai_async_http_client

logger = logging.getLogger("voice_input.asr.openai_compatible")


class OpenAICompatibleASRProvider(BaseASRProvider):
    """OpenAI audio.transcriptions 兼容接口实现。"""

    async def transcribe(
        self,
        audio_path: Path,
        api_key: str,
        base_url: str,
        model: str,
        prompt: str = "",
        language: str = "",
        extra_config: Optional[dict] = None,
        proxy_config: Optional[dict] = None,
    ) -> ASRResult:
        from openai import AsyncOpenAI

        kwargs: dict = dict(model=model, file=open(audio_path, "rb"), response_format="verbose_json")
        if language:
            kwargs["language"] = language
        if prompt:
            kwargs["prompt"] = prompt

        http_client = openai_async_http_client(proxy_config, timeout=600.0)
        client = AsyncOpenAI(
            api_key=api_key,
            base_url=base_url or None,
            http_client=http_client,
        )
        try:
            response = await client.audio.transcriptions.create(**kwargs)

            if hasattr(response, "text"):
                text = response.text.strip()
            else:
                text = str(response).strip()

            detected_language = ""
            if hasattr(response, "language"):
                detected_language = response.language or ""

            logger.info(
                "OpenAI-compat ASR: model=%s lang=%s chars=%d",
                model, detected_language, len(text),
            )
            return ASRResult(text=text, language=detected_language)
        finally:
            if "file" in kwargs and hasattr(kwargs["file"], "close"):
                kwargs["file"].close()
            if http_client is not None:
                await http_client.aclose()


register("openai", OpenAICompatibleASRProvider)
register("groq", OpenAICompatibleASRProvider)
register("openai_compatible", OpenAICompatibleASRProvider)
