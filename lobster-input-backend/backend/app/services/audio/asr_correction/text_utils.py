from __future__ import annotations

import re
import unicodedata
from functools import lru_cache

import jieba
from pypinyin import Style, lazy_pinyin

HAN_RE = re.compile(r"[\u4e00-\u9fff]")
LATIN_RE = re.compile(r"[A-Za-z]")
CYRILLIC_RE = re.compile(r"[\u0400-\u04ff]")
HIRAGANA_KATAKANA_RE = re.compile(r"[\u3040-\u30ff]")
HANGUL_RE = re.compile(r"[\uac00-\ud7af]")

TOKEN_RE = re.compile(
    r"[A-Za-z][A-Za-z0-9_.+#/-]*"
    r"|[\u4e00-\u9fff]{1,16}"
    r"|[\u0400-\u04ff]+"
    r"|[\u3040-\u30ff]+"
    r"|[\uac00-\ud7af]+"
)

MAX_TEXT_CHARS = 500
MAX_TOKENS = 100


def strip_accents(value: str) -> str:
    return "".join(
        char
        for char in unicodedata.normalize("NFKD", value)
        if not unicodedata.combining(char)
    )


def normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", strip_accents(str(value or "").casefold()).strip())


def compact_latin(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", normalize_text(value))


def latin_skeleton(value: str) -> str:
    return re.sub(r"[aeiouy]+", "", compact_latin(value))


@lru_cache(maxsize=20000)
def pinyin_key(value: str) -> str:
    text = normalize_text(value)
    if not text:
        return ""
    parts: list[str] = []
    buffer = ""
    for char in text:
        if "\u4e00" <= char <= "\u9fff":
            if buffer:
                parts.append(buffer)
                buffer = ""
            parts.extend(lazy_pinyin(char, style=Style.NORMAL, errors="ignore"))
        elif char.isalnum():
            buffer += char
        else:
            if buffer:
                parts.append(buffer)
                buffer = ""
    if buffer:
        parts.append(buffer)
    return " ".join(part for part in parts if part)


@lru_cache(maxsize=20000)
def tokenize(text: str) -> tuple[str, ...]:
    raw = str(text or "")[:MAX_TEXT_CHARS]
    base = TOKEN_RE.findall(raw)
    tokens: list[str] = []
    for token in base:
        tokens.append(token)
        if HAN_RE.search(token) and len(token) > 3:
            tokens.extend(part for part in jieba.lcut(token) if part.strip())
            for size in range(2, min(5, len(token) + 1)):
                tokens.extend(token[index:index + size] for index in range(0, len(token) - size + 1))

    for index, token in enumerate(base):
        if not LATIN_RE.search(token):
            continue
        for size in (2, 3):
            window = base[index:index + size]
            if len(window) == size and all(LATIN_RE.search(item) for item in window):
                tokens.append(" ".join(window))

    result: list[str] = []
    seen: set[str] = set()
    for token in tokens:
        token = token.strip()
        key = normalize_text(token)
        if not key or key in seen or len(token) > 48:
            continue
        seen.add(key)
        result.append(token)
        if len(result) >= MAX_TOKENS:
            break
    return tuple(result)


def text_scripts(text: str) -> set[str]:
    scripts: set[str] = set()
    if HAN_RE.search(text):
        scripts.add("han")
    if LATIN_RE.search(text):
        scripts.add("latin")
    if CYRILLIC_RE.search(text):
        scripts.add("cyrillic")
    if HIRAGANA_KATAKANA_RE.search(text):
        scripts.add("kana")
    if HANGUL_RE.search(text):
        scripts.add("hangul")
    return scripts
