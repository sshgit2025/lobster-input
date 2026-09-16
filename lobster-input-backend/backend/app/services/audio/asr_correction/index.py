from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from app.services.audio.asr_correction.adapters import CorrectionAdapter
from app.services.audio.asr_correction.models import DictionaryTerm, IndexedTerm
from app.services.audio.asr_correction.text_utils import compact_latin


@dataclass
class AdapterIndex:
    adapter: CorrectionAdapter
    terms: tuple[IndexedTerm, ...]
    exact: dict[str, tuple[int, ...]]
    blocks: dict[str, tuple[int, ...]]

    @classmethod
    def build(cls, adapter: CorrectionAdapter, terms: list[DictionaryTerm]) -> "AdapterIndex":
        indexed: list[IndexedTerm] = []
        exact: dict[str, list[int]] = defaultdict(list)
        blocks: dict[str, list[int]] = defaultdict(list)
        for term in terms:
            keys = adapter.term_keys(term.word)
            if not keys:
                continue
            item = IndexedTerm(
                term=term,
                keys=frozenset(keys),
                blocks=frozenset(adapter.block_keys(keys)),
                short_latin=len(compact_latin(term.word)) <= 3,
            )
            index = len(indexed)
            indexed.append(item)
            for key in item.keys:
                exact[key].append(index)
            for block in item.blocks:
                blocks[block].append(index)
        return cls(
            adapter=adapter,
            terms=tuple(indexed),
            exact={key: tuple(values) for key, values in exact.items()},
            blocks={key: tuple(values) for key, values in blocks.items()},
        )

    def candidate_indexes(self, token_keys: set[str], *, limit: int = 180) -> tuple[int, ...]:
        seen: set[int] = set()
        result: list[int] = []
        for key in token_keys:
            for index in self.exact.get(key, ()):
                if index not in seen:
                    seen.add(index)
                    result.append(index)
                    if len(result) >= limit:
                        return tuple(result)
        for block in self.adapter.block_keys(token_keys):
            for index in self.blocks.get(block, ())[:80]:
                if index not in seen:
                    seen.add(index)
                    result.append(index)
                    if len(result) >= limit:
                        return tuple(result)
        return tuple(result)
