"""
AudioService — 音频处理服务。

完整流水线: 保存上传文件 → 时长校验 → 音频质量增强 → 语音识别(ASR) → 用户词典纠偏（可选）→ 返回文本。

ASR 提供商通过号池动态分发，号池 Key 的 platform 字段决定使用哪个 ASR 实现：
  - dashscope / qwen_asr → 阿里云 Qwen3-ASR-Flash（默认，支持中英日韩俄等多语言）
  - openai / groq        → OpenAI 兼容 Whisper API
  - volcengine / doubao  → 火山引擎豆包语音（仅中英文）

返回结果包含识别文本和检测到的语言代码（language），供下游纠偏使用。

用户词典会在 ASR prompt / provider vocab 阶段注入，后处理阶段再基于用户词典
做轻量发音候选召回。不再依赖公共向量词库。
"""
import os
import logging
import time
from pathlib import Path
from typing import Optional, Tuple
from fastapi import UploadFile
from app.core.config import settings
from app.core.exceptions import InvalidAudioException, AudioDurationExceededException
from app.providers.asr.base import get_provider
from app.data.usage.extractors.whisper_extractor import WhisperExtractor
from app.data.usage.queue import emit as usage_emit
from app.services.infra.api_pool_client import (
    report_usage, report_error, PoolKeyInfo,
)
from app.services.infra.runtime_provider_config import pick_key_for_node
from app.repositories.hotword_repository import HotWordRepository

logger = logging.getLogger("voice_input.audio")

DEFAULT_HOTWORDS = (
    "代码,检查,编译,调试,部署,重构,接口,函数,变量,模块,"
    "提交,合并,分支,回滚,测试,日志,配置,数据库,服务器,缓存,"
    "帮我,检查一下,看一下,写一个,修改,删除,添加,运行,启动,停止"
)

SUPPORTED_FORMATS = {".mp3", ".wav", ".m4a", ".ogg", ".flac", ".webm", ".mp4"}


class AudioService:
    """音频处理服务，封装文件存储、增强、识别、清理的完整生命周期。"""

    async def _build_whisper_prompt(self, user_email: Optional[str] = None) -> str:
        """拼装 ASR prompt：系统默认关键词 + 用户词典。"""
        words = [item.strip() for item in DEFAULT_HOTWORDS.split(",") if item.strip()]
        if user_email:
            try:
                hotwords = await HotWordRepository().list_by_user(user_email)
                words.extend(item.word.strip() for item in hotwords if item.word.strip())
            except Exception as exc:
                logger.warning("Load user hotwords for ASR prompt skipped: %s", exc)
        deduped = []
        seen = set()
        for word in words:
            key = word.casefold()
            if key in seen:
                continue
            seen.add(key)
            deduped.append(word)
        prompt = ",".join(deduped[:200])
        logger.debug("ASR prompt: %s", prompt[:100])
        return prompt

    async def save_upload(self, file: UploadFile) -> Path:
        """
        保存上传的音频文件到临时目录，校验格式、大小和时长。
        时长超限抛出 AudioDurationExceededException（携带 config_update）。
        """
        suffix = Path(file.filename or "audio.m4a").suffix.lower()
        if not suffix or suffix not in SUPPORTED_FORMATS:
            suffix = ".m4a"

        upload_dir = Path(settings.audio_upload_dir)
        upload_dir.mkdir(parents=True, exist_ok=True)

        import uuid
        dest = upload_dir / f"{uuid.uuid4().hex}{suffix}"
        max_bytes = settings.audio_max_size_mb * 1024 * 1024
        size = 0
        first_bytes = b""
        with dest.open("wb") as out:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > max_bytes:
                    try:
                        dest.unlink(missing_ok=True)
                    finally:
                        raise InvalidAudioException(
                            f"File too large. Max allowed: {settings.audio_max_size_mb}MB"
                        )
                if len(first_bytes) < 12:
                    first_bytes += chunk[: 12 - len(first_bytes)]
                out.write(chunk)

        # 打印文件头 magic bytes，辅助排查格式问题（不影响功能）
        magic = first_bytes[:12].hex() if len(first_bytes) >= 12 else first_bytes.hex()
        # M4A/MP4: ftyp box 在 offset 4, WAV: 52494646 (RIFF), MP3: fff3/fff2/494433
        ftyp_hint = first_bytes[4:8].decode("ascii", errors="replace") if len(first_bytes) >= 8 else "?"
        logger.info(
            "Audio saved: %s (%d bytes) magic=%s ftyp=%s",
            dest.name, size, magic, ftyp_hint,
        )

        duration = self._get_duration(dest)
        if duration is not None:
            max_sec = settings.audio_max_duration_sec
            client_max = max_sec - 5
            logger.info("Audio duration: %.1fs (max %ds)", duration, max_sec)
            if duration > max_sec:
                logger.warning("Audio duration exceeded: %.1fs > %ds", duration, max_sec)
                raise AudioDurationExceededException(
                    message=f"录音时长 {duration:.0f} 秒超出限制，最大允许 {client_max} 秒",
                    config_update={"max_duration_sec": client_max},
                )
        else:
            logger.warning("Audio duration unknown, skipping duration check: %s", dest.name)

        return dest

    async def enhance(self, audio_path: Path) -> Path:
        """
        音频质量增强：高通滤波（80Hz）+ 音量标准化（loudnorm）。
        异步调用 ffmpeg，失败时自动降级直通，不影响主流程。
        """
        import asyncio
        import shutil
        if not shutil.which("ffmpeg"):
            logger.warning("ffmpeg not found, skipping enhance — will send original file to ASR")
            return audio_path

        out_path = audio_path.with_suffix(".enhanced.wav")
        cmd = [
            "ffmpeg", "-y", "-i", str(audio_path),
            "-af", "highpass=f=80,loudnorm",
            "-ar", "16000", "-ac", "1", "-sample_fmt", "s16",
            str(out_path),
        ]
        try:
            t0 = time.monotonic()
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            try:
                await asyncio.wait_for(proc.wait(), timeout=max(20, settings.audio_max_duration_sec + 20))
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                logger.warning("ffmpeg enhance timeout, using original")
                return audio_path
            elapsed_ms = int((time.monotonic() - t0) * 1000)
            if proc.returncode == 0 and out_path.exists():
                logger.info(
                    "Audio enhanced: %s -> %s (%dms)",
                    audio_path.name, out_path.name, elapsed_ms,
                )
                return out_path
            else:
                logger.warning("ffmpeg enhance failed (rc=%s), using original", proc.returncode)
                return audio_path
        except Exception as e:
            logger.warning("ffmpeg enhance exception: %s, using original", e)
            return audio_path

    async def _resolve_asr_key(self, required_tag: str = "") -> PoolKeyInfo:
        """根据管理端 asr_transcribe 节点配置获取 ASR Key。"""
        key_info, _node, provider = await pick_key_for_node("asr_transcribe", expected_category="asr")
        logger.info(
            "ASR key from pool: provider=%s impl=%s group=%s platform=%s id=%s",
            provider.provider_id, provider.implementation, provider.pool_group_id,
            key_info.platform_code, key_info.id,
        )
        return key_info

    async def transcribe(
        self,
        audio_path: Path,
        user_email: Optional[str] = None,
        operation: str = "transcribe",
        client_platform: str = "",
        required_tag: str = "",
        client_ui_lang: str = "",
    ) -> Tuple[str, str, PoolKeyInfo]:
        """
        语音识别 → (文本, 语言代码)。
        返回元组 (transcript, detected_language)，语言代码供下游纠偏使用。
        required_tag 用于向号池按标签筛选 ASR 密钥（如流程名 "standard"）。
        """
        prompt = await self._build_whisper_prompt(user_email)
        key_info = await self._resolve_asr_key(required_tag=required_tag)

        return await self._transcribe_with_key(
            key_info, audio_path, prompt,
            user_email=user_email,
            operation=operation,
            client_platform=client_platform,
            client_ui_lang=client_ui_lang,
        )

    async def _transcribe_with_key(
        self,
        key_info: PoolKeyInfo,
        audio_path: Path,
        prompt: str = "",
        user_email: Optional[str] = None,
        operation: str = "transcribe",
        client_platform: str = "",
        client_ui_lang: str = "",
    ) -> Tuple[str, str, PoolKeyInfo]:
        """
        调用 ASR 提供商执行识别。
        提供商由号池 Key 的 platform 字段决定，通过注册表路由。
        返回 (text, language)。
        """
        provider_name = key_info.provider_implementation or key_info.platform_code
        asr = get_provider(provider_name)
        t0 = time.monotonic()

        try:
            provider_extra_config = dict(key_info.extra_config or {})
            if user_email:
                provider_extra_config["_user_email"] = user_email
            result = await asr.transcribe(
                audio_path=audio_path,
                api_key=key_info.api_key,
                base_url=key_info.base_url,
                model=key_info.model,
                prompt=prompt,
                language=client_ui_lang or settings.whisper_language,
                extra_config=provider_extra_config,
                proxy_config=key_info.proxy_config or {},
            )
            latency_ms = int((time.monotonic() - t0) * 1000)
            text = result.text.strip()
            language = result.language
            duration = self._get_duration(audio_path) or 0.0
            logger.info(
                "ASR[%s] transcribed: %d chars lang=%s %.1fs %dms",
                provider_name, len(text), language, duration, latency_ms,
            )

            await report_usage(
                key_info,
                seconds_used=duration,
                requests_used=1,
                operation=operation,
                user_email=user_email or "",
                latency_ms=latency_ms,
                client_platform=client_platform,
            )

            if user_email:
                event = WhisperExtractor().extract(
                    text,
                    user_email=user_email,
                    operation=operation,
                    provider=provider_name,
                    audio_path=audio_path,
                    latency_ms=latency_ms,
                    api_key=key_info.api_key,
                    client_platform=client_platform,
                )
                if event:
                    usage_emit(event)

            return text, language, key_info

        except Exception as e:
            logger.error("ASR[%s] transcription failed: %s", provider_name, e)
            await report_error(key_info, str(e))
            raise

    @staticmethod
    def _get_duration(audio_path: Path) -> float | None:
        """读取音频文件时长（秒），解析失败返回 None。"""
        try:
            from mutagen import File as MutagenFile
            audio = MutagenFile(str(audio_path))
            if audio is not None and audio.info is not None:
                return audio.info.length
        except Exception as e:
            logger.warning("Failed to read audio duration: %s", e)
        return None

    async def cleanup(self, audio_path: Path) -> None:
        """处理完成后清理临时文件。"""
        try:
            if audio_path and audio_path.exists():
                os.remove(audio_path)
        except Exception:
            pass
