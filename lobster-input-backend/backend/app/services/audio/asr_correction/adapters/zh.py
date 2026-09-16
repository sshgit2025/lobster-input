from __future__ import annotations

from functools import lru_cache

from rapidfuzz.distance import Levenshtein

from app.services.audio.asr_correction.adapters.base import CorrectionAdapter
from app.services.audio.asr_correction.models import IndexedTerm
from app.services.audio.asr_correction.text_utils import HAN_RE, LATIN_RE, compact_latin, normalize_text, pinyin_key

TECH_TRANSLITERATION_ALIASES: dict[str, tuple[str, ...]] = {
    "agent": ("ai zheng te", "ai zhen te", "ei zhen te", "a gent"),
    "cursor": ("ke se", "ka se", "ka ser"),
    "claude": ("ke lao de", "ke luo de"),
    "qwen": ("qian wen", "q wen", "kou wen"),
    "openai": ("ou pen ai", "ou pan ai", "open ai"),
    "chatgpt": ("cha ji pi ti", "qia ji pi ti", "chat gpt"),
    "github": ("ji te ha bu", "gei ta ha bu", "git hub", "get hub"),
    "docker": ("duo ke er", "dao ke"),
    "kubernetes": ("ku bo nei ti si", "k ba s", "k8s"),
    "redis": ("rui di si", "lei di si"),
    "mongodb": ("mang guo db", "mongo db"),
    "postgresql": ("po si te ge rui sql", "postgre sql"),
    "fastapi": ("fa si te api", "fast api"),
    "websocket": ("wai bu socket", "web socket"),
    "asr": ("a s r", "ei ai si a er"),
    "llm": ("l l m", "da mo xing"),
    "prompt": ("pu lan pu te", "po lan pu te"),
    "token": ("tou ken", "tuo ken"),
    "rag": ("r a g", "rui ge"),
}


class ChinesePhoneticAdapter(CorrectionAdapter):
    name = "zh_phonetic"

    def is_active(self, *, language: str, scripts: set[str]) -> bool:
        return "han" in scripts or language.lower().startswith("zh")

    @lru_cache(maxsize=20000)
    def term_keys(self, term: str) -> set[str]:
        normalized = normalize_text(term)
        keys = {normalized, pinyin_key(term)}
        compact = compact_latin(term)
        if compact:
            keys.add(compact)
            keys.update(TECH_TRANSLITERATION_ALIASES.get(compact, ()))
        return {key for key in keys if key}

    @lru_cache(maxsize=20000)
    def token_keys(self, token: str) -> set[str]:
        keys = self.term_keys(token)
        compact = compact_latin(token)
        if compact:
            keys.add(compact)
        return keys

    def block_keys(self, keys: set[str]) -> set[str]:
        blocks: set[str] = set()
        for key in keys:
            if " " in key:
                blocks.add("py:" + key.split(" ", 1)[0])
            else:
                blocks.add("raw:" + key[:2])
        return blocks

    def score(self, *, token: str, token_keys: set[str], term: IndexedTerm, full_text: str) -> float:
        if normalize_text(token) == normalize_text(term.term.word):
            return 0.0
        if not (HAN_RE.search(token) or HAN_RE.search(term.term.word) or LATIN_RE.search(term.term.word)):
            return 0.0
        best = 0.0
        for left in token_keys:
            for right in term.keys:
                if left == right:
                    best = max(best, 1.0)
                best = max(best, Levenshtein.normalized_similarity(left, right))
        if best < 0.86:
            return 0.0
        return best
