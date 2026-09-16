"""
口语标识符确定性预处理。

ASR 会把口述邮箱/路径里的分隔词和中文姓名原样转写（"邵华点孙艾特gmail点com"），
LLM 做"逐字拼音+分隔符忠实+顺序保持"的组合转换不可靠。这里在送入 LLM 之前用
确定性规则完成高置信模式的转换，LLM 只需原样保留结果。

只处理误报率几乎为零的强模式（必须含"艾特+域名+点+TLD"或"user斜杠…杠"锚点）；
姓名段限定 1-2 个汉字，避免把前文普通汉字吞进名字。多音字取 pypinyin 默认读音。
"""
from __future__ import annotations

import re

from pypinyin import lazy_pinyin

_SEP_MAP = {"点": ".", "下划线": "_"}

# 汉字名(1-2字) + 点/下划线 + 汉字名(1-2字) + 艾特 + 域名 + 点 + TLD
_EMAIL_RE = re.compile(
    r"([一-鿿]{1,2})(点|下划线)([一-鿿]{1,2})"
    r"艾特([A-Za-z0-9][A-Za-z0-9-]*)点(com|cn|net|org|io|me|co)(?![A-Za-z0-9])"
)

# user斜杠 + 汉字名 + 下划线 + 汉字名 + 杠 （路径口语，如 user斜杠邵华下划线孙杠test）
_PATH_RE = re.compile(
    r"user斜杠([一-鿿]{1,2})下划线([一-鿿]{1,2})杠"
)


def _pinyin(value: str) -> str:
    return "".join(lazy_pinyin(value))


def _email_repl(match: re.Match) -> str:
    given, sep, family, domain, tld = match.groups()
    return f"{_pinyin(given)}{_SEP_MAP[sep]}{_pinyin(family)}@{domain}.{tld}"


def _path_repl(match: re.Match) -> str:
    given, family = match.groups()
    return f"user/{_pinyin(given)}_{_pinyin(family)}-"


def normalize_spoken_identifiers(text: str, language: str = "") -> str:
    """中文口述邮箱/路径的确定性规范化；非中文文本天然不匹配，原样返回。"""
    lang = (language or "").lower().split("-")[0].split("_")[0]
    if lang and lang != "zh":
        return text
    if "艾特" not in text and "user斜杠" not in text:
        return text
    text = _EMAIL_RE.sub(_email_repl, text)
    text = _PATH_RE.sub(_path_repl, text)
    return text


_EMAIL_TOKEN_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def extract_email_tokens(text: str) -> list[str]:
    """提取输入中的成品邮箱 token，供 LLM 输出后做符号忠实性恢复。"""
    return _EMAIL_TOKEN_RE.findall(text)


def restore_email_tokens(result: str, tokens: list[str]) -> str:
    """LLM 偶尔会把邮箱 local part 的 _ 和 . 互换；按输入原样恢复。"""
    for token in tokens:
        if token in result:
            continue
        local, _, domain = token.partition("@")
        variants = set()
        if "_" in local:
            variants.add(f"{local.replace('_', '.')}@{domain}")
        if "." in local:
            variants.add(f"{local.replace('.', '_')}@{domain}")
        for variant in variants:
            if variant in result:
                result = result.replace(variant, token)
                break
    return result
