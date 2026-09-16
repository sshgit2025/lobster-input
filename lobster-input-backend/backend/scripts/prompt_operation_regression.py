from __future__ import annotations

import argparse
import asyncio
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from app.agent.intent_router import IntentRouter
from app.services.llm.llm_service import LLMService


@dataclass(frozen=True)
class OperationCase:
    id: str
    language: str
    operation: str
    transcript: str
    expected: str = ""
    selected_text: str = ""
    contains: tuple[str, ...] = ()
    not_contains: tuple[str, ...] = ()
    regex: tuple[str, ...] = ()


@dataclass
class OperationResult:
    case: OperationCase
    output: str
    latency_ms: int
    passed: bool
    failures: list[str] = field(default_factory=list)


def build_cases() -> list[OperationCase]:
    cases: list[OperationCase] = []

    def add(language: str, operation: str, transcript: str, **kwargs):
        cases.append(OperationCase(
            id=f"{language}_{operation}_{len(cases) + 1:03d}",
            language=language,
            operation=operation,
            transcript=transcript,
            **kwargs,
        ))

    for language, data in {
        "en": {
            "selected": "The login API fails after preview deploy because the token cache is stale.",
            "polish": "make this shorter but keep the technical meaning",
            "translate": "translate this to Russian",
            "polish_contains": ("API", "preview"),
            "translate_contains": ("API",),
            "draft": "write a short release note saying the screenshot fix is available in preview",
            "intent_rewrite": "write a short email to the customer about tomorrow's deployment",
            "intent_search": "what is the latest stable version of Qwen",
            "intent_transcribe": "the customer is worried about the preview deploy timing",
            "intent_on": "start OpenClaw conversation",
            "intent_off": "stop OpenClaw conversation",
            "intent_new": "start a new OpenClaw conversation",
            "open_text": "check the failing tests and explain the root cause",
        },
        "ru": {
            "selected": "После preview deploy login API иногда возвращает timeout из-за старого token cache.",
            "polish": "сделай короче но сохрани технический смысл",
            "translate": "переведи это на английский",
            "polish_contains": ("API", "preview"),
            "translate_contains": ("API", "preview"),
            "draft": "напиши короткий release note что исправление screenshot feature доступно в preview",
            "intent_rewrite": "напиши короткое письмо клиенту про завтрашний деплой",
            "intent_search": "какая последняя стабильная версия Qwen",
            "intent_transcribe": "клиент переживает из-за времени preview deploy",
            "intent_on": "включи OpenClaw разговор",
            "intent_off": "выключи OpenClaw разговор",
            "intent_new": "начни новый OpenClaw разговор",
            "open_text": "проверь падающие тесты и объясни root cause",
        },
        "ko": {
            "selected": "preview deploy 이후 login API가 오래된 token cache 때문에 가끔 timeout을 반환합니다.",
            "polish": "더 짧게 다듬되 기술 의미는 유지해 주세요",
            "translate": "영어로 번역해 주세요",
            "polish_contains": ("API", "preview"),
            "translate_contains": ("API", "preview"),
            "draft": "screenshot fix가 preview에 들어갔다는 짧은 release note를 써 주세요",
            "intent_rewrite": "내일 배포에 대해 고객에게 보낼 짧은 이메일을 써 주세요",
            "intent_search": "Qwen 최신 안정 버전이 뭐야",
            "intent_transcribe": "고객은 preview deploy 일정 때문에 걱정하고 있어요",
            "intent_on": "OpenClaw 대화를 시작해 줘",
            "intent_off": "OpenClaw 대화를 꺼 줘",
            "intent_new": "새 OpenClaw 대화를 시작해 줘",
            "open_text": "실패하는 테스트를 확인하고 root cause를 설명해 줘",
        },
    }.items():
        add(language, "rewrite_selected", data["polish"], selected_text=data["selected"], contains=data["polish_contains"])
        add(language, "rewrite_selected", data["translate"], selected_text=data["selected"], contains=data["translate_contains"])
        add(language, "rewrite", data["draft"], contains=("preview",))
        add(language, "agent_intent", data["intent_rewrite"], expected="REWRITE")
        add(language, "agent_intent", data["intent_search"], expected="SEARCH")
        add(language, "agent_intent", data["intent_transcribe"], expected="TRANSCRIBE")
        add(language, "agent_intent", data["intent_on"], expected="OPENCLAW_ON")
        add(language, "agent_intent", data["intent_off"], expected="OPENCLAW_OFF")
        add(language, "agent_intent", data["intent_new"], expected="OPENCLAW_NEW_SESSION")
        add(language, "openclaw_transcribe", "slash stop", expected="COMMAND:/stop")
        add(language, "openclaw_transcribe", data["open_text"], regex=(r"^TEXT:",), contains=("root cause",))

    return cases


def evaluate(case: OperationCase, output: str) -> tuple[bool, list[str]]:
    failures: list[str] = []
    if case.expected and output.strip() != case.expected:
        failures.append(f"expected={case.expected!r}")
    output_lower = output.lower()
    for value in case.contains:
        if value and value.lower() not in output_lower:
            failures.append(f"missing contains={value!r}")
    for value in case.not_contains:
        if value and value.lower() in output_lower:
            failures.append(f"unexpected contains={value!r}")
    for pattern in case.regex:
        if not re.search(pattern, output):
            failures.append(f"missing regex={pattern!r}")
    return not failures, failures


async def run_case(
    service: LLMService,
    router: IntentRouter,
    case: OperationCase,
    platform: str,
    provider: str,
    model: str,
) -> OperationResult:
    start = time.monotonic()
    try:
        if case.operation == "agent_intent":
            result = await router.classify(
                case.transcript,
                client_platform=platform,
                provider=provider or None,
                model=model or None,
                flow_name="standard",
                transcript_language=case.language,
            )
            output = result.value
        else:
            operation = "rewrite" if case.operation == "rewrite_selected" else case.operation
            output = await service.run(
                operation=operation,
                transcript=case.transcript,
                selected_text=case.selected_text or None,
                client_platform=platform,
                provider=provider or None,
                model=model or None,
                user_email=None,
                flow_name="standard",
                transcript_language=case.language,
            )
    except Exception as exc:
        output = f"ERROR {type(exc).__name__}: {exc}"
    latency_ms = int((time.monotonic() - start) * 1000)
    passed, failures = evaluate(case, output)
    if output.startswith("ERROR "):
        passed = False
        failures.append("llm_error")
    return OperationResult(case=case, output=output, latency_ms=latency_ms, passed=passed, failures=failures)


async def async_main(args: argparse.Namespace) -> int:
    cases = build_cases()
    if args.language:
        cases = [case for case in cases if case.language == args.language]
    if args.operation:
        cases = [case for case in cases if case.operation == args.operation]
    service = LLMService()
    router = IntentRouter()
    semaphore = asyncio.Semaphore(args.concurrency)

    async def guarded(case: OperationCase) -> OperationResult:
        async with semaphore:
            return await run_case(service, router, case, args.platform, args.provider, args.model)

    results = await asyncio.gather(*(guarded(case) for case in cases))
    total = len(results)
    passed = sum(1 for result in results if result.passed)
    print(f"TOTAL={total} PASSED={passed} FAILED={total - passed} PASS_RATE={(passed / total * 100 if total else 0):.1f}%")
    by_op: dict[str, list[OperationResult]] = {}
    for result in results:
        by_op.setdefault(f"{result.case.language}:{result.case.operation}", []).append(result)
    for key in sorted(by_op):
        items = by_op[key]
        ok = sum(1 for item in items if item.passed)
        print(f"{key}: {ok}/{len(items)}")
    failures = [result for result in results if not result.passed]
    if failures:
        print("\nFAILURES")
        for result in failures[:args.show_failures]:
            print(f"- {result.case.id} [{result.case.operation}] {', '.join(result.failures)}")
            print(f"  IN : {result.case.transcript}")
            print(f"  OUT: {result.output}")
    return 1 if args.fail_on_failure and failures else 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run prompt regression for non-transcribe operations.")
    parser.add_argument("--language", default="")
    parser.add_argument("--operation", default="")
    parser.add_argument("--platform", default="windows")
    parser.add_argument("--provider", default="")
    parser.add_argument("--model", default="")
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--show-failures", type=int, default=30)
    parser.add_argument("--fail-on-failure", action="store_true")
    return parser.parse_args()


def main() -> int:
    return asyncio.run(async_main(parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
