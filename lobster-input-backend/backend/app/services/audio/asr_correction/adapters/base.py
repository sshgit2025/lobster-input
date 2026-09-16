from __future__ import annotations

from abc import ABC, abstractmethod

from app.services.audio.asr_correction.models import IndexedTerm


class CorrectionAdapter(ABC):
    name: str

    @abstractmethod
    def is_active(self, *, language: str, scripts: set[str]) -> bool:
        raise NotImplementedError

    @abstractmethod
    def term_keys(self, term: str) -> set[str]:
        raise NotImplementedError

    @abstractmethod
    def token_keys(self, token: str) -> set[str]:
        raise NotImplementedError

    @abstractmethod
    def block_keys(self, keys: set[str]) -> set[str]:
        raise NotImplementedError

    @abstractmethod
    def score(
        self,
        *,
        token: str,
        token_keys: set[str],
        term: IndexedTerm,
        full_text: str,
    ) -> float:
        raise NotImplementedError
