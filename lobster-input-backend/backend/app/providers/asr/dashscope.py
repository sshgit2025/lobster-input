"""
阿里云 DashScope Qwen3-ASR 提供商。

使用阿里云百炼平台的 Qwen3-ASR-Flash 模型，通过 DashScope 原生 SDK
MultiModalConversation 接口以 file:// 绝对路径方式传入音频。

选型依据（官方文档核实 + 服务器实测）：
  - DashScope SDK file:// 方式支持 WAV/MP3，实测 WAV 返回 200 正常
  - OpenAI 兼容接口 base64 方式不支持 M4A，WAV 可用但引入无谓依赖
  - 客户端改为上传 PCM16 WAV（16kHz, mono），120s ≈ 3.8MB < 10MB 限制
  - SDK 原生接口为官方推荐维护方式，不依赖 OpenAI SDK 兼容层

管理端配置:
  category       = asr
  implementation = dashscope
  pool_group_id  = 号池中的 DashScope ASR 分组

返回字段:
  text     — 识别文本
  language — 语言代码（优先使用 Qwen-ASR annotations[].language）
"""
import logging
import time
from pathlib import Path
from typing import Any, Optional

from app.providers.asr.base import BaseASRProvider, ASRResult, register
from app.services.infra.proxy_config import requests_proxies

logger = logging.getLogger("voice_input.asr.dashscope")

_DEFAULT_BASE_URL = "https://dashscope.aliyuncs.com/api/v1"
_DEFAULT_MODEL = "qwen3-asr-flash"


def _value(obj: Any, key: str, default: Any = None) -> Any:
    if isinstance(obj, dict):
        return obj.get(key, default)
    return getattr(obj, key, default)


def _extract_audio_language(message: Any) -> str:
    annotations = _value(message, "annotations", []) or []
    for item in annotations:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "audio_info" and item.get("language"):
            return str(item["language"]).strip()
    return ""


class DashScopeASRProvider(BaseASRProvider):
    """
    阿里云 DashScope Qwen3-ASR 提供商。
    通过 DashScope SDK MultiModalConversation 以 file:// 路径传入音频。
    客户端上传 PCM16 WAV，SDK 原生支持，无需任何格式转换。
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
        import asyncio
        import dashscope
        import requests

        effective_base_url = base_url or _DEFAULT_BASE_URL
        effective_model = model or _DEFAULT_MODEL

        file_size_bytes = audio_path.stat().st_size
        file_size_kb = file_size_bytes / 1024
        magic_hex = audio_path.read_bytes()[:8].hex()
        logger.info(
            "ASR request: model=%s file=%s size=%.1fKB magic=%s",
            effective_model, audio_path.name, file_size_kb, magic_hex,
        )

        audio_file_uri = f"file://{audio_path.resolve()}"
        messages = [{"role": "user", "content": [{"audio": audio_file_uri}]}]

        asr_options: dict = {}
        if language:
            asr_options["language_hints"] = [language]
        if prompt:
            vocab = [w.strip() for w in prompt.replace("，", ",").split(",") if w.strip()]
            if vocab:
                asr_options["vocab_list"] = vocab[:200]

        t0 = time.monotonic()
        session = None
        try:
            proxies = requests_proxies(proxy_config)
            if proxies:
                session = requests.Session()
                session.proxies.update(proxies)
            dashscope.base_http_api_url = effective_base_url
            response = await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: dashscope.MultiModalConversation.call(
                    api_key=api_key,
                    model=effective_model,
                    messages=messages,
                    result_format="message",
                    asr_options=asr_options if asr_options else None,
                    session=session,
                ),
            )
            elapsed_ms = int((time.monotonic() - t0) * 1000)
            logger.info(
                "ASR response: status=%s elapsed=%dms",
                getattr(response, "status_code", "?"), elapsed_ms,
            )
        except Exception as exc:
            elapsed_ms = int((time.monotonic() - t0) * 1000)
            logger.error(
                "ASR SDK exception: model=%s size=%.1fKB elapsed=%dms error=%s",
                effective_model, file_size_kb, elapsed_ms, exc, exc_info=True,
            )
            raise
        finally:
            if session is not None:
                session.close()

        if response.status_code != 200:
            err_msg = getattr(response, "message", str(response))
            logger.error(
                "ASR API error: status=%s code=%s message=%s",
                response.status_code, getattr(response, "code", "?"), err_msg,
            )
            raise RuntimeError(
                f"DashScope ASR failed: status={response.status_code} "
                f"code={getattr(response, 'code', '?')} msg={err_msg}"
            )

        text = ""
        detected_language = language or ""
        if response.output and response.output.choices:
            msg = response.output.choices[0].message
            detected_language = _extract_audio_language(msg) or detected_language
            if isinstance(msg.content, list):
                for item in msg.content:
                    if isinstance(item, dict):
                        # DashScope 实际返回格式为 {"text": "..."} 不含 type 字段
                        # 同时兼容含 type 字段的格式 {"type": "text", "text": "..."}
                        t = item.get("text", "").strip()
                        if t:
                            text = t
                            break
            else:
                text = (msg.content or "").strip()

        logger.info(
            "DashScope Qwen3-ASR OK: model=%s lang=%s chars=%d size=%.1fKB elapsed=%dms",
            effective_model, detected_language or "unknown", len(text), file_size_kb, elapsed_ms,
        )
        return ASRResult(text=text, language=detected_language)


register("dashscope", DashScopeASRProvider)
register("qwen_asr", DashScopeASRProvider)
register("aliyun_asr", DashScopeASRProvider)
