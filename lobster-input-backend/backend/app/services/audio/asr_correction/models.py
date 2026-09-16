from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class CorrectionCandidate:
    correct_text: str
    score: float
    adapter: str


@dataclass(frozen=True)
class TokenHint:
    original: str
    candidates: tuple[CorrectionCandidate, ...]


@dataclass(frozen=True)
class CorrectionFlowResult:
    hints_text: str = ""

    @property
    def has_hints(self) -> bool:
        return bool(self.hints_text.strip())


@dataclass(frozen=True)
class DictionaryTerm:
    id: str
    word: str


@dataclass(frozen=True)
class IndexedTerm:
    term: DictionaryTerm
    keys: frozenset[str]
    blocks: frozenset[str]
    short_latin: bool
