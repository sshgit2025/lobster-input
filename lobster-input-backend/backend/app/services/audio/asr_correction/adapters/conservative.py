from __future__ import annotations

from functools import lru_cache

from rapidfuzz.distance import Levenshtein

from app.services.audio.asr_correction.adapters.base import CorrectionAdapter
from app.services.audio.asr_correction.models import IndexedTerm
from app.services.audio.asr_correction.text_utils import compact_latin, normalize_text


class ConservativeTextAdapter(CorrectionAdapter):
    name = "conservative_text"

    def is_active(self, *, language: str, scripts: set[str]) -> bool:
        return bool(scripts - {"latin", "han"})

    @lru_cache(maxsize=20000)
    def term_keys(self, term: str) -> set[str]:
        return {key for key in {normalize_text(term), compact_latin(term)} if key}

    @lru_cache(maxsize=20000)
    def token_keys(self, token: str) -> set[str]:
        return self.term_keys(token)

    def block_keys(self, keys: set[str]) -> set[str]:
        return {"text:" + key[:3] for key in keys if len(key) >= 3}

    def score(self, *, token: str, token_keys: set[str], term: IndexedTerm, full_text: str) -> float:
        token_norm = normalize_text(token)
        term_norm = normalize_text(term.term.word)
        if not token_norm or token_norm == term_norm:
            return 0.0
        if min(len(token_norm), len(term_norm)) < 4:
            return 0.0
        score = Levenshtein.normalized_similarity(token_norm, term_norm)
        return score if score >= 0.94 else 0.0
