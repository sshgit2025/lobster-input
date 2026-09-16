"""
PromptManager — 按 operation 类型、流程、语言、客户端平台读取提示词，并融合激活人设的配置。

目录结构：
  templates/{flow_name}/{lang}/{platform}/{operation}.txt

  flow_name — 流程名称（如 "standard"）
  lang      — ASR 识别的语言代码（如 "zh" / "en"）；找不到时降级到 "default"
  platform  — 客户端平台（mac / ios / windows / android）

加载优先级（完整路径 → 分步降级）：
  1. {flow}/{lang}/{platform}    — 流程 + 语言 + 平台专属
  2. {flow}/{lang}/mac           — 流程 + 语言，mac 兜底（非 mac 平台无专属时）
  3. {flow}/default/{platform}   — 流程 + 默认语言 + 平台专属
  4. {flow}/default/mac          — 流程 + 默认语言，mac 兜底

注入规则（按 operation 分类，精确控制，避免相互干扰）：
  transcribe       → 激活人设存在 transcribe_prompt 时替换静态系统规则
  rewrite          → 激活人设存在 rewrite_prompt 时替换静态系统规则
  agent_intent     → 激活人设 intent_hint 注入模板内置插槽（规则 2，高优先级位置）
  其他 operation   → 只用内置模板，不注入用户配置
  无激活人设       → 所有 operation 均使用内置模板（agent_intent 插槽填充占位文本）
"""
import logging
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional

from app.core.exceptions import UnsupportedOperationException
from app.core.lang_utils import normalize_lang
from app.repositories.persona_repository import PersonaRepository

logger = logging.getLogger("voice_input.prompt")


class PromptSource(str, Enum):
    """系统提示词中「语义规则」部分的来源。

    运行时段落（格式指导等）的注入策略依赖该来源，见
    app/services/llm/formatting_guidance.py。
    """
    BUILTIN = "builtin"   # 内置静态模板
    PERSONA = "persona"   # 激活人设的自定义提示词（整体替换静态规则）


@dataclass(frozen=True)
class ResolvedSystemPrompt:
    """get_system_prompt 的解析结果：正文 + 来源。

    只在需要按来源区分后续拼接行为的调用方（LLMService）使用；
    只关心正文的调用方继续用 get_system_prompt 即可。
    """
    text: str
    source: PromptSource

    @property
    def is_persona(self) -> bool:
        return self.source is PromptSource.PERSONA

TEMPLATES_DIR = Path(__file__).parent / "templates"

_INTENT_HINT_NONE = "（用户未设置自定义偏好，跳过本规则）"

_INTENT_HINT_FORMAT = """\
用户自定义规则如下，请严格遵守：

{hint}"""

_LOG_PREVIEW_LEN = 120

_PLATFORM_DIR_MAP = {
    "macos":   "mac",
    "ios":     "ios",
    "windows": "windows",
    "android": "android",
    "harmony": "android",  # 鸿蒙端与安卓行为一致，共用安卓提示词模板目录，不新建模板目录
}

_PLATFORM_FALLBACK_DIR = "mac"

_DEFAULT_LANG = "default"


def _preview(text: str) -> str:
    text = text.strip()
    if len(text) <= _LOG_PREVIEW_LEN:
        return repr(text)
    return repr(text[:_LOG_PREVIEW_LEN]) + f"... ({len(text)} chars total)"


class PromptManager:

    _persona_repo = PersonaRepository()

    @staticmethod
    def _resolve_platform_dir(client_platform: str) -> Optional[str]:
        """将 X-Client-Platform header 值映射为模板子目录名。"""
        return _PLATFORM_DIR_MAP.get(client_platform)

    @staticmethod
    def get_template(
        operation: str,
        client_platform: str = "",
        flow_name: str = "",
        transcript_language: str = "",
    ) -> str:
        """
        读取指定 operation 对应的提示词模板文件内容。

        查找顺序（按优先级降级）：
          1. {flow}/{lang}/{platform}     — 流程 + ASR语言 + 平台专属
          2. {flow}/{lang}/mac            — 流程 + ASR语言 + mac 兜底（非 mac 时）
          3. {flow}/default/{platform}    — 流程 + 默认语言 + 平台专属
          4. {flow}/default/mac           — 流程 + 默认语言 + mac 兜底

        flow_name 必填，对应 templates/ 下的流程子目录（当前为 "standard"）。
        transcript_language 是 ASR 识别的语言代码，决定读取哪个语言目录。
        """
        if not flow_name:
            raise UnsupportedOperationException(operation)

        platform_dir = _PLATFORM_DIR_MAP.get(client_platform)
        lang_key = normalize_lang(transcript_language) if transcript_language else ""
        flow_dir = TEMPLATES_DIR / flow_name

        if not flow_dir.is_dir():
            raise UnsupportedOperationException(operation)

        search_langs = []
        if lang_key and lang_key != _DEFAULT_LANG:
            search_langs.append(lang_key)
        search_langs.append(_DEFAULT_LANG)

        for lang in search_langs:
            lang_dir = flow_dir / lang

            if platform_dir:
                platform_file = lang_dir / platform_dir / f"{operation}.txt"
                if platform_file.exists():
                    content = platform_file.read_text(encoding="utf-8").strip()
                    logger.info(
                        "[Prompt] template loaded: path=%s chars=%d",
                        platform_file, len(content),
                    )
                    return content

            if platform_dir and platform_dir != _PLATFORM_FALLBACK_DIR:
                mac_file = lang_dir / _PLATFORM_FALLBACK_DIR / f"{operation}.txt"
                if mac_file.exists():
                    content = mac_file.read_text(encoding="utf-8").strip()
                    logger.info(
                        "[Prompt] template loaded (mac fallback, lang=%s): path=%s chars=%d",
                        lang, mac_file, len(content),
                    )
                    return content

        raise UnsupportedOperationException(operation)

    @classmethod
    async def get_system_prompt(
        cls,
        operation: str,
        user_email: Optional[str] = None,
        client_platform: str = "",
        flow_name: str = "",
        transcript_language: str = "",
    ) -> str:
        """构建完整系统提示词，只返回正文。需要区分来源时用 get_system_prompt_resolved。"""
        resolved = await cls.get_system_prompt_resolved(
            operation, user_email, client_platform=client_platform,
            flow_name=flow_name, transcript_language=transcript_language,
        )
        return resolved.text

    @classmethod
    async def get_system_prompt_resolved(
        cls,
        operation: str,
        user_email: Optional[str] = None,
        client_platform: str = "",
        flow_name: str = "",
        transcript_language: str = "",
    ) -> ResolvedSystemPrompt:
        """
        构建完整系统提示词并标注来源：
          - transcribe/rewrite: 激活人设对应提示词非空时替换静态系统规则 → PERSONA
          - 其他 operation（含 agent_intent）及所有回退分支: 内置模板 → BUILTIN
        """
        template = cls.get_template(
            operation, client_platform,
            flow_name=flow_name, transcript_language=transcript_language,
        )

        if not user_email or operation not in ("transcribe", "rewrite"):
            logger.info(
                "[Persona] operation=%s platform=%s lang=%s user=%s → builtin template (%d chars)",
                operation, client_platform or "none",
                transcript_language or "none", user_email or "<anonymous>", len(template),
            )
            return ResolvedSystemPrompt(text=template, source=PromptSource.BUILTIN)

        try:
            prompts = await cls._persona_repo.get_active_prompts(user_email, client_platform)
            if prompts is None:
                logger.info(
                    "[Persona] operation=%s platform=%s user=%s → no active persona → builtin (%d chars)",
                    operation, client_platform or "none", user_email, len(template),
                )
                return ResolvedSystemPrompt(text=template, source=PromptSource.BUILTIN)

            if operation == "transcribe" and prompts.transcribe_enabled and prompts.transcribe_prompt:
                logger.info(
                    "[Persona] operation=transcribe user=%s → CUSTOM active (%d chars) preview=%s",
                    user_email, len(prompts.transcribe_prompt), _preview(prompts.transcribe_prompt),
                )
                return ResolvedSystemPrompt(text=prompts.transcribe_prompt, source=PromptSource.PERSONA)

            if operation == "rewrite" and prompts.rewrite_enabled and prompts.rewrite_prompt:
                logger.info(
                    "[Persona] operation=rewrite user=%s → CUSTOM active (%d chars) preview=%s",
                    user_email, len(prompts.rewrite_prompt), _preview(prompts.rewrite_prompt),
                )
                return ResolvedSystemPrompt(text=prompts.rewrite_prompt, source=PromptSource.PERSONA)

            logger.info(
                "[Persona] operation=%s platform=%s user=%s → active persona but operation prompt empty → builtin (%d chars)",
                operation, client_platform or "none", user_email, len(template),
            )
        except Exception as e:
            logger.warning("[Persona] Failed to load active persona for %s: %s → builtin", user_email, e)

        return ResolvedSystemPrompt(text=template, source=PromptSource.BUILTIN)

    @classmethod
    async def get_intent_system_prompt(
        cls,
        user_email: Optional[str] = None,
        client_platform: str = "",
        flow_name: str = "",
        transcript_language: str = "",
    ) -> str:
        """
        构建意图识别系统提示词：将用户 intent_hint 注入模板内的 {user_intent_hint} 插槽。
        用户自定义偏好规则位于规则 2（高优先级位置），确保其效力高于通用规则 3-5。
        无激活人设或未设置 intent_hint 时填充默认占位文本（跳过本规则）。
        """
        template = cls.get_template(
            "agent_intent", client_platform,
            flow_name=flow_name, transcript_language=transcript_language,
        )

        user_hint_text = _INTENT_HINT_NONE

        if user_email:
            try:
                prompts = await cls._persona_repo.get_active_prompts(user_email, client_platform)
                if prompts and prompts.intent_enabled and prompts.intent_hint:
                    user_hint_text = _INTENT_HINT_FORMAT.format(hint=prompts.intent_hint.strip())
                    logger.info(
                        "[Persona] intent_router user=%s → injecting intent_hint (%d chars) into slot",
                        user_email, len(prompts.intent_hint),
                    )
                elif prompts and prompts.intent_hint and not prompts.intent_enabled:
                    logger.info(
                        "[Persona] intent_router user=%s → intent_hint EXISTS but DISABLED → using placeholder",
                        user_email,
                    )
                else:
                    logger.debug(
                        "[Persona] intent_router user=%s → no intent_hint → using placeholder",
                        user_email,
                    )
            except Exception as e:
                logger.warning("[Persona] Failed to load intent_hint for %s: %s → using placeholder", user_email, e)

        result = template.replace("{user_intent_hint}", user_hint_text)
        logger.debug(
            "[Persona] intent prompt built: user=%s total=%d chars",
            user_email or "<anonymous>", len(result),
        )
        return result
