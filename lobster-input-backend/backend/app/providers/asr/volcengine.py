"""
火山引擎豆包语音 Seed-ASR 2.0 标准版提供商。

默认接口：
  wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream

默认使用 Seed-ASR 大模型 no stream WebSocket，直接上传本地 PCM 音频，不再要求
生成公网可下载 URL。

鉴权方式：

新版 X-Api-Key 单字段授权
  api_key      = <X-Api-Key>
  model        = volc.seedasr.auc（X-Api-Resource-Id）

返回字段:
  text     — 识别文本（含标点、数字归一化）
  language — 语言代码（zh/en/ja/...），从 result.additions 中提取
"""
import logging
import asyncio
import json
import wave
from pathlib import Path
from typing import Optional

from app.providers.asr.base import BaseASRProvider, ASRResult, register
from app.providers.realtime_asr.base import RealtimeASRConfig
from app.providers.realtime_asr.volcengine import VolcengineRealtimeASRProvider
from app.services.infra.api_pool_client import PoolKeyInfo

logger = logging.getLogger("voice_input.asr.volcengine")

_DEFAULT_NOSTREAM_RESOURCE_ID = "volc.seedasr.sauc.duration"


class VolcengineASRProvider(BaseASRProvider):
    """
    火山引擎豆包语音 Seed-ASR 2.0 标准版提供商。
    使用 no stream WebSocket 直传音频。
    """

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
        extra_config = extra_config or {}
        return await self._transcribe_nostream(
            audio_path=audio_path,
            api_key=api_key,
            base_url=base_url,
            model=model,
            prompt=prompt,
            language=language,
            extra_config=extra_config,
        )

    async def _transcribe_nostream(
        self,
        *,
        audio_path: Path,
        api_key: str,
        base_url: str,
        model: str,
        prompt: str = "",
        language: str = "",
        extra_config: Optional[dict] = None,
    ) -> ASRResult:
        extra_config = extra_config or {}
        pcm, sample_rate = self._read_pcm16_mono(audio_path)
        key_info = PoolKeyInfo(
            id="volcengine_sync_nostream",
            api_key=api_key,
            base_url=base_url,
            model=self._nostream_resource_id(model, extra_config),
            extra_config=extra_config,
        )
        provider_config = dict(extra_config)
        cfg = RealtimeASRConfig(
            platform="sync",
            user_email=str(extra_config.get("_user_email") or extra_config.get("user_email") or "lobster"),
            language=language,
            audio_format="pcm",
            sample_rate=sample_rate,
            use_vad=True,
            max_duration_sec=int(extra_config.get("max_duration_sec") or 600),
            corpus_text=prompt,
        )
        provider = VolcengineRealtimeASRProvider()
        timeout_sec = float(extra_config.get("nostream_timeout_sec") or 120)
        chunk_bytes = self._chunk_bytes(sample_rate, extra_config.get("chunk_ms", 200))
        text = ""
        detected_language = ""

        async def collect() -> ASRResult:
            nonlocal text, detected_language
            async for event in provider.events():
                if event.language:
                    detected_language = event.language
                if event.type in {"partial", "completed"} and event.text:
                    text = event.text.strip()
                if event.type == "finished":
                    final_text = str(event.text or event.transcript or text).strip()
                    return ASRResult(text=final_text, language=event.language or detected_language or "")
                if event.type == "error":
                    raise RuntimeError(f"Volcengine ASR nostream failed: {event.message}")
            return ASRResult(text=text, language=detected_language)

        try:
            await provider.connect(key_info=key_info, cfg=cfg, provider_config=provider_config)
            collect_task = asyncio.create_task(collect())
            for offset in range(0, len(pcm), chunk_bytes):
                await provider.send_audio(pcm[offset:offset + chunk_bytes])
            await provider.finish()
            result = await asyncio.wait_for(collect_task, timeout=timeout_sec)
        finally:
            await provider.close()

        logger.info(
            "Volcengine Seed-ASR no stream: resource=%s lang=%s chars=%d size=%.1fKB",
            key_info.model,
            result.language,
            len(result.text),
            len(pcm) / 1024,
        )
        return result

    @staticmethod
    def _read_pcm16_mono(audio_path: Path) -> tuple[bytes, int]:
        try:
            with wave.open(str(audio_path), "rb") as wf:
                channels = wf.getnchannels()
                sample_width = wf.getsampwidth()
                sample_rate = wf.getframerate()
                if channels != 1 or sample_width != 2:
                    raise RuntimeError(
                        f"Volcengine no stream requires mono 16-bit WAV after enhancement, "
                        f"got channels={channels} sample_width={sample_width}"
                    )
                return wf.readframes(wf.getnframes()), sample_rate
        except wave.Error as exc:
            raise RuntimeError("Volcengine no stream requires enhanced WAV input") from exc

    @staticmethod
    def _chunk_bytes(sample_rate: int, raw_chunk_ms) -> int:
        try:
            chunk_ms = float(raw_chunk_ms)
        except (TypeError, ValueError):
            chunk_ms = 200.0
        chunk_ms = min(1000.0, max(100.0, chunk_ms))
        return max(1, int(sample_rate * 2 * chunk_ms / 1000.0))

    @staticmethod
    def _nostream_resource_id(model: str, extra_config: dict) -> str:
        configured = str(extra_config.get("nostream_resource_id") or "").strip()
        if configured:
            return configured
        value = str(model or "").strip()
        if value and ".sauc" in value:
            return value
        return _DEFAULT_NOSTREAM_RESOURCE_ID

    @staticmethod
    def _extract_text(result) -> str:
        if isinstance(result, dict):
            return str(result.get("text") or "").strip()
        if isinstance(result, list):
            return "".join(
                str(item.get("text") or "").strip()
                for item in result
                if isinstance(item, dict) and item.get("text")
            ).strip()
        return ""

    @staticmethod
    def _extract_language(result) -> str:
        if isinstance(result, list):
            for item in result:
                lang = VolcengineASRProvider._extract_language(item)
                if lang:
                    return lang
            return ""
        if not isinstance(result, dict):
            return ""
        additions = result.get("additions", {})
        if isinstance(additions, dict):
            for key in ("language", "lid_lang", "lang"):
                if additions.get(key):
                    return str(additions[key])
        utterances = result.get("utterances", [])
        if isinstance(utterances, list):
            for item in utterances:
                if isinstance(item, dict) and item.get("language"):
                    return str(item["language"])
        return ""

    @staticmethod
    def _hotword_context(prompt: str) -> str:
        words = [item.strip() for item in str(prompt or "").replace("，", ",").split(",") if item.strip()]
        if not words:
            return ""
        hotwords = [{"word": word[:64]} for word in words[:100]]
        return json.dumps({"hotwords": hotwords}, ensure_ascii=False, separators=(",", ":"))


register("volcengine", VolcengineASRProvider)
register("doubao", VolcengineASRProvider)
