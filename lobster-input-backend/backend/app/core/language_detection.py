"""基于实际文本的语言类型检测。

提示词路由所用的语言**必须来自 ASR 识别文本本身**：
  - 客户端 UI 语言（X-Accept-Language / client_ui_lang）只代表界面语种，仅用于审计，
    绝不能用来决定提示词语言；用户完全可能界面是英文却说中文；
  - 同步 ASR 会在结果里返回检测语言，但实时流式 ASR（火山实时默认不开 LID）通常
    不返回语言字段，只靠 provider 字段会退化成 default(英文) 模板；
  - 因此统一以文本检测为权威，ASR provider 返回的语言仅在文本无法判定时兜底。

两级判定：
  1. 脚本强信号：韩文/西里尔/CJK 字符一旦出现即为可靠判据，优先判定 ko/ru/zh。
     这对短句和中英混合（“帮我打开三W点百度点com”）、俄英混合（“проверь endpoint”）
     都比通用检测稳，避免被夹带的英文技术词带偏。
  2. 纯拉丁等无强信号文本：交给第三方库 lingua（限定到受支持模板语言集）细分。
无法判定（纯数字/符号）时回退 ASR provider 语言，仍判不出返回 ""（走 default 模板）。
"""
from __future__ import annotations

import logging
import re

from lingua import Language, LanguageDetectorBuilder

from app.core.lang_utils import normalize_lang

logger = logging.getLogger("voice_input.language_detection")

# 脚本强信号：这些脚本出现即为强判据（英文文本绝不含韩文/西里尔/CJK）。
_HANGUL_RE = re.compile(r"[가-힣ᄀ-ᇿ㄰-㆏]")
_CYRILLIC_RE = re.compile(r"[Ѐ-ӿ]")
_CJK_RE = re.compile(r"[一-鿿㐀-䶿豈-﫿]")

# lingua 语言枚举 → 模板语言码。只纳入有对应提示词目录的语言。
_LINGUA_TO_CODE = {
    Language.CHINESE: "zh",
    Language.ENGLISH: "en",
    Language.KOREAN: "ko",
    Language.RUSSIAN: "ru",
}
_SUPPORTED = frozenset(_LINGUA_TO_CODE.values())

_detector = None


def _get_detector():
    """懒加载单例：限定语言集可显著降低模型体积与检测耗时。"""
    global _detector
    if _detector is None:
        _detector = LanguageDetectorBuilder.from_languages(*_LINGUA_TO_CODE).build()
    return _detector


def _supported_or_empty(lang: str) -> str:
    normalized = normalize_lang(lang)
    return normalized if normalized in _SUPPORTED else ""


def detect_language(text: str, fallback: str = "") -> str:
    """按文本判定提示词语言。

    返回受支持语言码（zh/en/ko/ru）；文本无法判定时回退到 normalize(fallback)
    （仍限受支持集），否则返回 ""（调用方走 default 模板）。
    """
    fb = _supported_or_empty(fallback)
    if not text or not text.strip():
        return fb

    # 1. 脚本强信号优先（短句/混合句最稳）
    if _HANGUL_RE.search(text):
        return "ko"
    if _CYRILLIC_RE.search(text):
        return "ru"
    if _CJK_RE.search(text):
        return "zh"

    # 2. 纯拉丁等无强信号文本 → lingua 第三方检测（当前受支持拉丁系语言为 en）
    try:
        detected = _get_detector().detect_language_of(text)
    except Exception as exc:  # 检测异常不应阻断主流程
        logger.warning("[lang-detect] failed, fallback=%s: %s", fb or "default", exc)
        return fb
    if detected is not None and detected in _LINGUA_TO_CODE:
        return _LINGUA_TO_CODE[detected]
    return fb
