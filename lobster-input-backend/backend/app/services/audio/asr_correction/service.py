from __future__ import annotations

import logging
import time

import jieba

from app.models.schemas import HotWord
from app.repositories.hotword_repository import HotWordRepository
from app.services.audio.asr_correction.adapters import ChinesePhoneticAdapter, ConservativeTextAdapter, LatinPhoneticAdapter
from app.services.audio.asr_correction.formatter import HintsFormatter
from app.services.audio.asr_correction.index import AdapterIndex
from app.services.audio.asr_correction.models import CorrectionCandidate, CorrectionFlowResult, DictionaryTerm, TokenHint
from app.services.audio.asr_correction.text_utils import pinyin_key, text_scripts, tokenize

logger = logging.getLogger("voice_input.asr_correction")

MAX_HINTS = 8
MAX_CANDIDATES_PER_TOKEN = 3
HOTWORD_CACHE_TTL_SEC = 15.0


class ASRCorrectionService:
    def __init__(self) -> None:
        self._repo = HotWordRepository()
        self._formatter = HintsFormatter()
        self._adapters = (
            ChinesePhoneticAdapter(),
            LatinPhoneticAdapter(),
            ConservativeTextAdapter(),
        )
        self._index_cache: dict[str, tuple[tuple[tuple[str, str], ...], tuple[AdapterIndex, ...]]] = {}
        self._hotword_cache: dict[str, tuple[float, list[HotWord]]] = {}

    async def run(self, text: str, language: str = "", user_email: str | None = None) -> CorrectionFlowResult:
        if not user_email or not text or len(text.strip()) < 2:
            return CorrectionFlowResult()

        started = time.monotonic()
        hotwords = await self._list_hotwords(user_email)
        if not hotwords:
            return CorrectionFlowResult()

        scripts = text_scripts(text)
        indexes = self._indexes_for_user(user_email, hotwords, language=language, scripts=scripts)
        hints = self._match(text, indexes)
        elapsed_ms = int((time.monotonic() - started) * 1000)
        logger.info(
            "[ASRCorrection] user_dict language=%s scripts=%s terms=%d hints=%d elapsed=%dms",
            language or "unknown",
            ",".join(sorted(scripts)) or "-",
            len(hotwords),
            len(hints),
            elapsed_ms,
        )
        return CorrectionFlowResult(self._formatter.format(hints))

    def invalidate_user(self, user_email: str) -> None:
        self._hotword_cache.pop(user_email, None)
        self._index_cache.pop(user_email, None)

    async def _list_hotwords(self, user_email: str) -> list[HotWord]:
        now = time.monotonic()
        cached = self._hotword_cache.get(user_email)
        if cached and cached[0] > now:
            return cached[1]
        hotwords = await self._repo.list_by_user(user_email)
        self._hotword_cache[user_email] = (now + HOTWORD_CACHE_TTL_SEC, hotwords)
        return hotwords

    def _indexes_for_user(
        self,
        user_email: str,
        hotwords: list[HotWord],
        *,
        language: str,
        scripts: set[str],
    ) -> tuple[AdapterIndex, ...]:
        signature = tuple(sorted((item.id, item.word.strip()) for item in hotwords if item.word.strip()))
        cached = self._index_cache.get(user_email)
        if cached and cached[0] == signature:
            all_indexes = cached[1]
        else:
            terms = [DictionaryTerm(id=item.id, word=item.word.strip()) for item in hotwords if item.word.strip()]
            all_indexes = tuple(AdapterIndex.build(adapter, terms) for adapter in self._adapters)
            if len(self._index_cache) >= 512:
                self._index_cache.pop(next(iter(self._index_cache)))
            self._index_cache[user_email] = (signature, all_indexes)
        return tuple(index for index in all_indexes if index.adapter.is_active(language=language, scripts=scripts))

    def _match(self, text: str, indexes: tuple[AdapterIndex, ...]) -> list[TokenHint]:
        hints: list[TokenHint] = []
        seen_pairs: set[tuple[str, str]] = set()
        covered_tokens: set[str] = set()
        tokens = sorted(tokenize(text), key=lambda value: (-len(value.split()), -len(value)))
        for token in tokens:
            normalized_token = token.casefold()
            if normalized_token in covered_tokens:
                continue
            scored: list[CorrectionCandidate] = []
            for index in indexes:
                token_keys = index.adapter.token_keys(token)
                if not token_keys:
                    continue
                for term_index in index.candidate_indexes(token_keys):
                    term = index.terms[term_index]
                    pair = (token.casefold(), term.term.word.casefold())
                    if pair in seen_pairs:
                        continue
                    score = index.adapter.score(
                        token=token,
                        token_keys=token_keys,
                        term=term,
                        full_text=text,
                    )
                    if score <= 0:
                        continue
                    scored.append(CorrectionCandidate(
                        correct_text=term.term.word,
                        score=round(score, 4),
                        adapter=index.adapter.name,
                    ))
                    seen_pairs.add(pair)
            scored.sort(key=lambda item: (-item.score, item.correct_text.casefold()))
            if scored:
                hints.append(TokenHint(original=token, candidates=tuple(scored[:MAX_CANDIDATES_PER_TOKEN])))
                if " " in token:
                    covered_tokens.update(part.casefold() for part in token.split() if part.strip())
                if len(hints) >= MAX_HINTS:
                    break
        return hints


def warmup_asr_correction_components() -> None:
    started = time.monotonic()
    jieba.lcut("预热用户词典发音纠偏 Agent 癌症特")
    pinyin_key("癌症特")
    LatinPhoneticAdapter().term_keys("Git")
    logger.info(
        "ASR correction warmup completed: elapsed=%dms",
        int((time.monotonic() - started) * 1000),
    )


_correction_service: ASRCorrectionService | None = None


def get_correction_service() -> ASRCorrectionService:
    global _correction_service
    if _correction_service is None:
        _correction_service = ASRCorrectionService()
    return _correction_service


def invalidate_user_dictionary_cache(user_email: str) -> None:
    if _correction_service is not None:
        _correction_service.invalidate_user(user_email)
