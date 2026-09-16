from __future__ import annotations

from functools import lru_cache

import jellyfish
from rapidfuzz.distance import Levenshtein

from app.services.audio.asr_correction.adapters.base import CorrectionAdapter
from app.services.audio.asr_correction.models import IndexedTerm
from app.services.audio.asr_correction.text_utils import LATIN_RE, compact_latin, latin_skeleton, normalize_text

DEV_CONTEXT_CUES = {
    "status", "commit", "push", "pull", "checkout", "clone", "branch", "merge", "rebase",
    "repo", "repository", "diff", "log", "remote", "origin", "main", "master", "tag",
    "stash", "reset", "fetch", "github", "gitlab", "actions", "deploy", "build", "api",
}
STOPWORDS = {
    "the", "a", "an", "me", "my", "you", "your", "to", "of", "in", "on", "for", "from",
    "and", "or", "is", "are", "was", "were", "be", "been", "please", "can", "could",
    "would", "should", "latest", "previous", "sentence", "today", "report", "document",
}
SHORT_TECH_TERMS = {"git", "npm", "ssh", "api", "sql", "llm", "asr", "rag"}
PHRASE_ALIASES = {
    "github": ("git hub", "get hub"),
    "openai": ("open ai",),
    "chatgpt": ("chat gpt",),
    "fastapi": ("fast api",),
    "mongodb": ("mongo db",),
    "postgresql": ("postgre sql", "postgres sql"),
    "websocket": ("web socket",),
}


class LatinPhoneticAdapter(CorrectionAdapter):
    name = "latin_phonetic"

    def is_active(self, *, language: str, scripts: set[str]) -> bool:
        return "latin" in scripts

    @lru_cache(maxsize=20000)
    def term_keys(self, term: str) -> set[str]:
        raw = compact_latin(term)
        keys = {normalize_text(term), raw}
        if raw:
            keys.add(latin_skeleton(term))
            keys.update(self._phonetic_keys(raw))
            keys.update(PHRASE_ALIASES.get(raw, ()))
        return {key for key in keys if key}

    @lru_cache(maxsize=20000)
    def token_keys(self, token: str) -> set[str]:
        parts = [compact_latin(part) for part in normalize_text(token).split()]
        if any(part in STOPWORDS for part in parts):
            return set()
        return self.term_keys(token)

    def block_keys(self, keys: set[str]) -> set[str]:
        blocks: set[str] = set()
        for key in keys:
            if " " in key:
                blocks.add("phrase:" + key.split(" ", 1)[0])
            else:
                blocks.add("latin:" + key[:2])
        return blocks

    def score(self, *, token: str, token_keys: set[str], term: IndexedTerm, full_text: str) -> float:
        token_norm = normalize_text(token)
        term_norm = normalize_text(term.term.word)
        token_raw = compact_latin(token)
        term_raw = compact_latin(term.term.word)
        if not token_raw or not term_raw or token_norm == term_norm:
            return 0.0
        if token_raw in STOPWORDS:
            return 0.0
        if not LATIN_RE.search(token) or not LATIN_RE.search(term.term.word):
            return 0.0

        best = 0.0
        for left in token_keys:
            for right in term.keys:
                if left == right:
                    best = max(best, 1.0)
                best = max(best, Levenshtein.normalized_similarity(left, right))

        phrase_alias_hit = token_norm in {normalize_text(alias) for alias in PHRASE_ALIASES.get(term_raw, ())}
        phrase_token = " " in token_norm
        context_cues = self._context_cues(full_text)

        if term_raw in SHORT_TECH_TERMS:
            if not context_cues or best < 0.92:
                return 0.0
        elif not phrase_alias_hit and not phrase_token:
            if not context_cues or len(token_raw) < 4 or best < 0.94:
                return 0.0
        elif best < 0.90:
            return 0.0
        return best

    @staticmethod
    @lru_cache(maxsize=20000)
    def _phonetic_keys(raw: str) -> tuple[str, ...]:
        keys = []
        for func in (jellyfish.metaphone, jellyfish.soundex, jellyfish.nysiis):
            value = func(raw)
            if value:
                keys.append(value.casefold())
        return tuple(keys)

    @staticmethod
    @lru_cache(maxsize=20000)
    def _context_cues(text: str) -> frozenset[str]:
        return frozenset(
            compact_latin(token)
            for token in normalize_text(text).split()
            if compact_latin(token) in DEV_CONTEXT_CUES
        )
