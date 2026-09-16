"""内容文案多语言基础设施(persona / plan 等面向用户的展示文案共享)。

与 `lang_utils.normalize_lang` 的分工:
- `lang_utils.normalize_lang` 是 pipeline/prompt 路由用的**粗粒度**语言(zh-CN→zh),
  会把繁体/粤语都并到 zh —— 适合选模型/提示词,不适合展示文案。
- 本模块是**展示文案**本地化:区分 zh-Hant(繁体)/yue(粤语),带 fallback 链,
  客户端经 X-Accept-Language 声明语言,后端存多语言 map、按语言解析返回单值。

约定:多语言字段以 `localized_*` 命名(如 localized_names/localized_descriptions),
值为 `{lang: text}` map;读取一律走 `localized_text`,写入一律先过 `clean_i18n`。
"""
from typing import Optional

# 支持的展示语言集(与客户端 LanguageManager / 移动端 MobileStrings 的语言一致)
SUPPORTED_LANGS: tuple[str, ...] = ("zh", "zh-Hant", "yue", "en", "ru", "ko")
DEFAULT_LANG = "zh"


def clean_text(val: Optional[str]) -> Optional[str]:
    """去除首尾空白;空串归一为 None。"""
    if val is None:
        return None
    s = val.strip()
    return s or None


def clean_i18n(values: Optional[dict]) -> dict:
    """规整多语言 map:只保留受支持语言的非空文案。写入前一律调用。"""
    values = values or {}
    return {lang: cleaned for lang in SUPPORTED_LANGS if (cleaned := clean_text(values.get(lang)))}


def normalize_language(language: Optional[str]) -> str:
    """把客户端语言标识(Accept-Language 形态)归一到受支持的语言码。

    精细区分:zh-Hant/zh-TW→zh-Hant;zh-HK/zh-MO→yue;其余 zh*→zh。
    """
    if not language:
        return DEFAULT_LANG
    lower = language.split(",", 1)[0].strip()
    for supported in SUPPORTED_LANGS:
        if lower == supported or lower.lower() == supported.lower():
            return supported
    low = lower.lower()
    if low.startswith("zh-hant") or low.startswith("zh-tw"):
        return "zh-Hant"
    if low.startswith("zh-hk") or low.startswith("zh-mo"):
        return "yue"
    if low.startswith("zh"):
        return "zh"
    if low.startswith("en"):
        return "en"
    if low.startswith("ru"):
        return "ru"
    if low.startswith("ko"):
        return "ko"
    return DEFAULT_LANG


def localized_text(localized_map: Optional[dict], language: str, *, fallback: Optional[str] = None) -> Optional[str]:
    """按语言取文案。fallback 链:请求语言 →(繁/粤额外回退 zh)→ en → zh;都无则返回 fallback。"""
    values = localized_map or {}
    if not isinstance(values, dict):
        return fallback
    normalized = normalize_language(language)
    chain = [normalized]
    if normalized in ("zh-Hant", "yue"):
        chain.append("zh")
    chain.extend(["en", "zh"])
    for lang in chain:
        value = clean_text(values.get(lang))
        if value:
            return value
    return fallback
