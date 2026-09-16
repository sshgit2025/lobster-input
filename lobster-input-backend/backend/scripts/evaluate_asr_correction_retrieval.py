"""Offline retrieval evaluation for ASR correction candidates.

This script evaluates the candidate-generation layer only. It does not call
LLMs or ASR providers. The goal is to answer whether a correction mechanism can
surface the intended term quickly enough before a later reranker/LLM decides
whether to apply it.

Datasets:
  - google/red_ace_asr_error_detection_and_correction: public English ASR
    hypothesis/reference pairs with token-level error labels.
  - A business-focused Chinese/code-switch synthetic set for terms that are
    hard to recover from semantic retrieval alone, e.g. 癌症特 -> Agent.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import statistics
import time
from collections import Counter
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Iterable

from pypinyin import Style, lazy_pinyin
from rapidfuzz.distance import Levenshtein


OUT_DIR = Path(__file__).resolve().parents[1] / "reports" / "asr_correction_eval"

WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9_./+-]*|[\u4e00-\u9fff]+")


@dataclass(frozen=True)
class Candidate:
    term: str
    aliases: tuple[str, ...]


@dataclass(frozen=True)
class Query:
    observed: str
    gold: str
    sentence: str
    language: str
    kind: str


TECH_TERM_ALIASES: dict[str, tuple[str, ...]] = {
    "Agent": ("agent", "癌症特", "爱真特", "诶真特", "诶正特", "a gent"),
    "Cursor": ("cursor", "刻色", "卡色", "咔瑟", "颗色"),
    "Claude": ("claude", "克劳德", "克洛德"),
    "Qwen": ("qwen", "千问", "Q文", "扣问"),
    "OpenAI": ("openai", "open ai", "欧喷AI", "欧盆AI"),
    "ChatGPT": ("chatgpt", "chat gpt", "差几批踢", "恰几皮提"),
    "GitHub": ("github", "git hub", "给他哈布", "鸡特哈布"),
    "Docker": ("docker", "多克尔", "刀客"),
    "Kubernetes": ("kubernetes", "库伯内提斯", "k8s", "K八S"),
    "Redis": ("redis", "瑞迪斯", "雷迪斯"),
    "MongoDB": ("mongodb", "芒果DB", "mongo db"),
    "PostgreSQL": ("postgresql", "postgre sql", "破思特格瑞SQL"),
    "FastAPI": ("fastapi", "fast api", "法斯特API"),
    "WebSocket": ("websocket", "web socket", "外部socket"),
    "ASR": ("asr", "A S R", "诶诶斯阿尔"),
    "LLM": ("llm", "L L M", "大模型"),
    "Embedding": ("embedding", "安贝丁", "恩贝丁"),
    "Prompt": ("prompt", "普朗普特", "破朗普特"),
    "Token": ("token", "偷肯", "托肯"),
    "Transformer": ("transformer", "传思former", "变压器"),
    "RAG": ("rag", "R A G", "瑞格"),
    "Middleware": ("middleware", "middle ware", "中间件"),
    "Callback": ("callback", "call back", "回调"),
    "Promise": ("promise", "prom miss", "普罗米斯"),
    "Repository": ("repository", "repo story", "仓库"),
    "Authentication": ("authentication", "authentic ation", "鉴权"),
    "Authorization": ("authorization", "author ization", "授权"),
}

CHINESE_TERMS: dict[str, tuple[str, ...]] = {
    "部署": ("部署", "不输", "布署", "步数"),
    "编译": ("编译", "编离", "编义"),
    "调试": ("调试", "掉试", "条式"),
    "重构": ("重构", "重复", "充构"),
    "递归": ("递归", "地柜", "迪归"),
    "变量": ("变量", "变亮", "便量"),
    "函数": ("函数", "含数", "寒数"),
    "参数": ("参数", "餐数", "惨数"),
    "缓存": ("缓存", "缓冲", "换存"),
    "鉴权": ("鉴权", "检权", "间权"),
    "令牌": ("令牌", "零排"),
    "剪贴板": ("剪贴板", "剪切板", "粘贴板"),
}

TEMPLATES = (
    "帮我查一下{term}最新技术文档",
    "看一下{term}这块为什么超时",
    "把{term}相关的配置整理一下",
    "检查一下{term}接口的错误日志",
    "总结一下{term}在我们后端里的使用场景",
    "帮我确认{term}是不是会影响实时识别",
)


def normalize_text(value: str) -> str:
    return " ".join(WORD_RE.findall(str(value or "").lower()))


def tokenize(value: str) -> list[str]:
    return WORD_RE.findall(str(value or "").lower())


def soundex(word: str) -> str:
    raw = re.sub(r"[^a-z]", "", word.lower())
    if not raw:
        return ""
    first = raw[0].upper()
    table = {
        **dict.fromkeys("bfpv", "1"),
        **dict.fromkeys("cgjkqsxz", "2"),
        **dict.fromkeys("dt", "3"),
        "l": "4",
        **dict.fromkeys("mn", "5"),
        "r": "6",
    }
    digits = [table.get(char, "") for char in raw[1:]]
    collapsed: list[str] = []
    prev = table.get(raw[0], "")
    for digit in digits:
        if digit and digit != prev:
            collapsed.append(digit)
        prev = digit
    return (first + "".join(collapsed) + "000")[:4]


def pinyin_key(text: str) -> str:
    normalized = str(text or "").strip().lower()
    if not normalized:
        return ""
    parts: list[str] = []
    buffer = ""
    for char in normalized:
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


def best_alias_score(observed: str, candidate: Candidate, mode: str) -> float:
    obs_norm = normalize_text(observed)
    obs_pinyin = pinyin_key(observed)
    best = 0.0
    for alias in candidate.aliases:
        alias_norm = normalize_text(alias)
        if mode == "edit":
            score = Levenshtein.normalized_similarity(obs_norm, alias_norm)
        elif mode == "soundex":
            score = Levenshtein.normalized_similarity(obs_norm, alias_norm)
            if soundex(obs_norm) and soundex(obs_norm) == soundex(alias_norm):
                score = max(score, 0.92)
        elif mode == "pinyin":
            alias_pinyin = pinyin_key(alias)
            score = max(
                Levenshtein.normalized_similarity(obs_norm, alias_norm),
                Levenshtein.normalized_similarity(obs_pinyin, alias_pinyin),
            )
        else:
            raise ValueError(f"Unknown mode: {mode}")
        best = max(best, score)
    return best


def rank_candidates(
    observed: str,
    candidates: list[Candidate],
    mode: str,
    *,
    top_k: int = 5,
    indexes: dict[str, dict[str, list[int]]] | None = None,
) -> list[tuple[str, float]]:
    candidate_indexes = retrieve_candidate_indexes(observed, candidates, mode, indexes)
    scored = [
        (candidate.term, best_alias_score(observed, candidate, mode))
        for candidate in (candidates[index] for index in candidate_indexes)
    ]
    scored.sort(key=lambda item: item[1], reverse=True)
    return scored[:top_k]


def build_indexes(candidates: list[Candidate]) -> dict[str, dict[str, list[int]]]:
    indexes: dict[str, dict[str, list[int]]] = {
        "soundex": {},
        "first": {},
        "pinyin": {},
        "pinyin_first": {},
    }
    for index, candidate in enumerate(candidates):
        for alias in candidate.aliases:
            alias_norm = normalize_text(alias)
            sx = soundex(alias_norm)
            if sx:
                indexes["soundex"].setdefault(sx, []).append(index)
            if alias_norm:
                indexes["first"].setdefault(alias_norm[:1], []).append(index)
            py = pinyin_key(alias)
            if py:
                indexes["pinyin"].setdefault(py, []).append(index)
                indexes["pinyin_first"].setdefault(py.split(" ", 1)[0], []).append(index)
    return indexes


def unique_indexes(values: Iterable[int], limit: int = 256) -> list[int]:
    seen: set[int] = set()
    result: list[int] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
        if len(result) >= limit:
            break
    return result


def retrieve_candidate_indexes(
    observed: str,
    candidates: list[Candidate],
    mode: str,
    indexes: dict[str, dict[str, list[int]]] | None,
) -> list[int]:
    if not indexes or mode == "edit":
        return list(range(len(candidates)))

    observed_norm = normalize_text(observed)
    if mode == "soundex":
        sx = soundex(observed_norm)
        bucket = list(indexes["soundex"].get(sx, []))
        if len(bucket) < 20 and observed_norm:
            bucket.extend(indexes["first"].get(observed_norm[:1], []))
        return unique_indexes(bucket, limit=256) or list(range(min(len(candidates), 256)))

    if mode == "pinyin":
        py = pinyin_key(observed)
        bucket = list(indexes["pinyin"].get(py, []))
        if len(bucket) < 20 and py:
            bucket.extend(indexes["pinyin_first"].get(py.split(" ", 1)[0], []))
        return unique_indexes(bucket, limit=256) or list(range(min(len(candidates), 256)))

    return list(range(len(candidates)))


def summarize_latencies(values_ms: list[float]) -> dict[str, float]:
    if not values_ms:
        return {"avg_ms": 0.0, "p50_ms": 0.0, "p95_ms": 0.0, "p99_ms": 0.0}
    ordered = sorted(values_ms)
    return {
        "avg_ms": round(statistics.fmean(ordered), 4),
        "p50_ms": round(ordered[int(len(ordered) * 0.50)], 4),
        "p95_ms": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))], 4),
        "p99_ms": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.99))], 4),
    }


def evaluate_queries(
    queries: list[Query],
    candidates: list[Candidate],
    modes: tuple[str, ...],
    *,
    top_k: int,
    threshold: float,
) -> dict[str, dict[str, float]]:
    metrics: dict[str, dict[str, float]] = {}
    candidate_by_term = {candidate.term.casefold(): candidate for candidate in candidates}
    for mode in modes:
        indexes = build_indexes(candidates) if mode in {"soundex", "pinyin"} else None
        top1 = top3 = top5 = 0
        false_positive = 0
        latencies: list[float] = []
        evaluated = 0
        for query in queries:
            gold_key = query.gold.casefold()
            if gold_key not in candidate_by_term:
                continue
            start = time.perf_counter()
            ranked = rank_candidates(query.observed, candidates, mode, top_k=top_k, indexes=indexes)
            latencies.append((time.perf_counter() - start) * 1000.0)
            terms = [term.casefold() for term, score in ranked]
            evaluated += 1
            if terms and terms[0] == gold_key:
                top1 += 1
            if gold_key in terms[:3]:
                top3 += 1
            if gold_key in terms[:5]:
                top5 += 1
            if query.observed.casefold() == query.gold.casefold():
                if ranked and ranked[0][1] >= threshold and ranked[0][0].casefold() != gold_key:
                    false_positive += 1
        denominator = max(1, evaluated)
        metrics[mode] = {
            "queries": evaluated,
            "top1": round(top1 / denominator, 4),
            "top3": round(top3 / denominator, 4),
            "top5": round(top5 / denominator, 4),
            "false_positive_rate": round(false_positive / denominator, 4),
            **summarize_latencies(latencies),
        }
    return metrics


def red_ace_queries(sample_size: int, max_queries: int, seed: int) -> tuple[list[Query], list[Candidate]]:
    try:
        from datasets import load_dataset
    except ImportError as exc:
        raise RuntimeError(
            "RED-ACE evaluation requires optional package 'datasets'. "
            "Install it in the evaluation environment before running this script."
        ) from exc

    random.seed(seed)
    ds = load_dataset("google/red_ace_asr_error_detection_and_correction", split="test", streaming=True)
    vocab_counter: Counter[str] = Counter()
    rows = []
    for row in ds.take(sample_size):
        truth_tokens = tokenize(row["truth"])
        hyp_tokens = [str(item).lower() for item in row["asr_hypothesis"]]
        rows.append((truth_tokens, hyp_tokens))
        vocab_counter.update(token for token in truth_tokens if len(token) > 2)

    vocab = [word for word, _count in vocab_counter.most_common(5000)]
    candidates = [Candidate(term=word, aliases=(word,)) for word in vocab]
    queries: list[Query] = []
    for truth_tokens, hyp_tokens in rows:
        matcher = SequenceMatcher(a=hyp_tokens, b=truth_tokens, autojunk=False)
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == "equal":
                continue
            hyp_span = hyp_tokens[i1:i2]
            truth_span = truth_tokens[j1:j2]
            if tag == "replace":
                for observed, gold in zip(hyp_span, truth_span):
                    if len(gold) > 2 and gold in vocab:
                        queries.append(Query(
                            observed=observed,
                            gold=gold,
                            sentence=" ".join(hyp_tokens),
                            language="en",
                            kind="red_ace_replace",
                        ))
                        if len(queries) >= max_queries:
                            random.shuffle(queries)
                            return queries, candidates
    random.shuffle(queries)
    return queries, candidates


def public_lexicon_gap_report() -> dict[str, object]:
    """Document why a fixed public lexicon is not a reliable correction source.

    The business aliases below are intentionally small and interpretable. They
    represent the exact class of errors found in manual tests: user-specific
    technical terms misrecognized into unrelated Chinese homophones.
    """
    all_terms = {**TECH_TERM_ALIASES, **CHINESE_TERMS}
    total_aliases = 0
    high_risk_examples: list[dict[str, str]] = []
    for correct, aliases in all_terms.items():
        for alias in aliases:
            if alias.casefold() == correct.casefold():
                continue
            total_aliases += 1
            if len(high_risk_examples) < 40:
                high_risk_examples.append({"correct": correct, "alias": alias})
    return {
        "business_aliases": total_aliases,
        "conclusion": (
            "These aliases are valuable only when the intended term is already "
            "in the user's dictionary. A global public lexicon cannot know which "
            "homophone should be preferred for each user and domain."
        ),
        "high_risk_examples": high_risk_examples,
    }


def synthetic_business_queries(seed: int, repeats: int) -> tuple[list[Query], list[Candidate]]:
    random.seed(seed)
    candidates = [
        Candidate(term=term, aliases=aliases)
        for term, aliases in {**TECH_TERM_ALIASES, **CHINESE_TERMS}.items()
    ]
    queries: list[Query] = []
    for _ in range(repeats):
        for term, aliases in {**TECH_TERM_ALIASES, **CHINESE_TERMS}.items():
            template = random.choice(TEMPLATES)
            for alias in aliases:
                if alias.casefold() == term.casefold():
                    continue
                observed_sentence = template.format(term=alias)
                queries.append(Query(
                    observed=alias,
                    gold=term,
                    sentence=observed_sentence,
                    language="zh",
                    kind="business_alias",
                ))
            correct_sentence = template.format(term=term)
            queries.append(Query(
                observed=term,
                gold=term,
                sentence=correct_sentence,
                language="zh",
                kind="business_correct_negative",
            ))
    random.shuffle(queries)
    return queries, candidates


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--red-ace-sample", type=int, default=10000)
    parser.add_argument("--red-ace-max-queries", type=int, default=5000)
    parser.add_argument("--synthetic-repeats", type=int, default=20)
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--threshold", type=float, default=0.88)
    parser.add_argument("--seed", type=int, default=20260601)
    args = parser.parse_args()

    started = time.perf_counter()
    report: dict[str, object] = {
        "config": vars(args),
        "notes": [
            "Candidate retrieval only; no ASR/LLM calls.",
            "A correction is only expected when the gold term exists in the dynamic candidate list.",
        ],
    }

    red_queries, red_candidates = red_ace_queries(args.red_ace_sample, args.red_ace_max_queries, args.seed)
    report["red_ace"] = {
        "queries": len(red_queries),
        "candidates": len(red_candidates),
        "metrics": evaluate_queries(
            red_queries,
            red_candidates,
            ("soundex",),
            top_k=args.top_k,
            threshold=args.threshold,
        ),
        "skipped": "Full edit-distance scan over 5k candidates is intentionally skipped because it is not viable for online latency.",
    }

    business_queries, business_candidates = synthetic_business_queries(args.seed, args.synthetic_repeats)
    report["business_synthetic"] = {
        "queries": len(business_queries),
        "candidates": len(business_candidates),
        "metrics": evaluate_queries(
            business_queries,
            business_candidates,
            ("pinyin",),
            top_k=args.top_k,
            threshold=args.threshold,
        ),
        "skipped": "Full edit-distance scan is slow and is not a deployable online strategy; indexed pinyin is the candidate production path.",
    }

    report["public_lexicon_gap"] = public_lexicon_gap_report()
    report["elapsed_sec"] = round(time.perf_counter() - started, 3)
    output_path = OUT_DIR / "retrieval_eval_report.json"
    write_json(output_path, report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"\nWrote {output_path}")


if __name__ == "__main__":
    main()
