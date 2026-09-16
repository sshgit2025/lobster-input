"""
Regression runner focused on Correction Hints behavior.

This script bypasses vector search and injects mocked candidate hints through
the same LLMService path used in production. It verifies that hints act as
low-priority evidence instead of blind replacement commands.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

try:
    from app.services.llm.llm_service import LLMService
except ModuleNotFoundError:
    LLMService = None


@dataclass(frozen=True)
class HintCase:
    id: str
    category: str
    text: str
    hints: str
    contains: tuple[str, ...] = ()
    not_contains: tuple[str, ...] = ()
    note: str = ""


@dataclass
class HintResult:
    case: HintCase
    output: str
    latency_ms: int
    passed: bool
    failures: list[str] = field(default_factory=list)


def build_cases() -> list[HintCase]:
    return [
        HintCase(
            id="ignore_title_001",
            category="ignore_bad_hint",
            text="可以的小哥哥，你是干这个的",
            hints='  - 原词 "小哥哥" -> 候选: ["小广告", "小格格"]',
            contains=("小哥哥", "你是干这个的"),
            not_contains=("小广告", "小格格"),
        ),
        HintCase(
            id="ignore_domain_001",
            category="ignore_bad_hint",
            text="我今天想去银行办卡，顺便查一下信用卡额度",
            hints='  - 原词 "银行" -> 候选: ["营养", "影音"]\n  - 原词 "额度" -> 候选: ["恶毒"]',
            contains=("银行", "办卡", "信用卡额度"),
            not_contains=("营养", "影音", "恶毒"),
        ),
        HintCase(
            id="ignore_meta_001",
            category="ignore_bad_hint",
            text="这个接口不要把语音停顿都写成逗号",
            hints='  - 原词 "逗号" -> 候选: ["豆号", "都好"]',
            contains=("接口", "语音停顿", "逗号"),
            not_contains=("豆号", "都好"),
        ),
        HintCase(
            id="ignore_person_001",
            category="ignore_bad_hint",
            text="老板这个线上问题不是我刚刚改出来的",
            hints='  - 原词 "老板" -> 候选: ["老版", "老板娘"]\n  - 原词 "我" -> 候选: ["用户"]',
            contains=("老板", "不是我", "改出来"),
            not_contains=("老板娘", "用户"),
        ),
        HintCase(
            id="ignore_multilingual_001",
            category="ignore_bad_hint",
            text="please check 这个 preview 环境的 timeout 问题",
            hints='  - 原词 "preview" -> 候选: ["previous", "预览"]\n  - 原词 "timeout" -> 候选: ["time out翻译为超时"]',
            contains=("please check", "preview", "timeout"),
            not_contains=("previous", "预览", "翻译为"),
        ),
        HintCase(
            id="apply_typo_001",
            category="apply_good_hint",
            text="这个接口需要重新布署preview环境",
            hints='  - 原词 "布署" -> 候选: ["部署"]',
            contains=("部署", "preview环境"),
            not_contains=("布署",),
        ),
        HintCase(
            id="apply_typo_002",
            category="apply_good_hint",
            text="截图以后要写入剪切板然后立刻关闭浮窗",
            hints='  - 原词 "剪切板" -> 候选: ["剪贴板"]',
            contains=("剪贴板", "关闭浮窗"),
            not_contains=("剪切板",),
        ),
        HintCase(
            id="apply_brand_001",
            category="apply_good_hint",
            text="帮我查一下deepseek和gpt五的最新版本",
            hints='  - 原词 "deepseek" -> 候选: ["DeepSeek"]\n  - 原词 "gpt五" -> 候选: ["GPT-5"]',
            contains=("DeepSeek", "GPT-5", "最新版本"),
            not_contains=("deepseek", "gpt五"),
        ),
        HintCase(
            id="apply_brand_002",
            category="apply_good_hint",
            text="这个open ai接口调用失败了",
            hints='  - 原词 "open ai" -> 候选: ["OpenAI"]',
            contains=("OpenAI", "接口调用失败"),
            not_contains=("open ai",),
        ),
        HintCase(
            id="apply_brand_003",
            category="apply_good_hint",
            text="claude的opus版本和sonnet版本都要支持",
            hints='  - 原词 "claude" -> 候选: ["Claude"]\n  - 原词 "opus" -> 候选: ["Opus"]\n  - 原词 "sonnet" -> 候选: ["Sonnet"]',
            contains=("Claude", "Opus", "Sonnet"),
            not_contains=("claude", "opus", "sonnet"),
        ),
        HintCase(
            id="apply_tech_001",
            category="apply_good_hint",
            text="这个request time out以后要自动重试",
            hints='  - 原词 "request time out" -> 候选: ["request timeout"]',
            contains=("request timeout", "自动重试"),
            not_contains=("request time out",),
        ),
        HintCase(
            id="apply_tech_002",
            category="apply_good_hint",
            text="前端build以后要上传到cloud flare r two",
            hints='  - 原词 "cloud flare r two" -> 候选: ["Cloudflare R2"]',
            contains=("Cloudflare R2", "上传"),
            not_contains=("cloud flare", "r two"),
        ),
        HintCase(
            id="apply_tech_003",
            category="apply_good_hint",
            text="把这个拉取request先跑一下ci",
            hints='  - 原词 "拉取request" -> 候选: ["pull request"]\n  - 原词 "ci" -> 候选: ["CI"]',
            contains=("pull request", "CI"),
            not_contains=("拉取request",),
        ),
        HintCase(
            id="apply_tech_004",
            category="apply_good_hint",
            text="数据库的斯ki马版本不一致",
            hints='  - 原词 "斯ki马" -> 候选: ["schema"]',
            contains=("schema版本", "不一致"),
            not_contains=("斯ki马",),
        ),
        HintCase(
            id="apply_tech_005",
            category="apply_good_hint",
            text="这个接口的token eyes超过限制了",
            hints='  - 原词 "token eyes" -> 候选: ["tokenize"]',
            contains=("tokenize", "超过限制"),
            not_contains=("token eyes",),
        ),
        HintCase(
            id="apply_mixed_001",
            category="apply_mixed_language",
            text="please check这个普review环境的time out问题",
            hints='  - 原词 "普review" -> 候选: ["preview"]\n  - 原词 "time out" -> 候选: ["timeout"]',
            contains=("please check", "preview环境", "timeout问题"),
            not_contains=("普review", "time out"),
        ),
        HintCase(
            id="apply_mixed_002",
            category="apply_mixed_language",
            text="帮我看一下prod环境的deploy ment日志",
            hints='  - 原词 "deploy ment" -> 候选: ["deployment"]',
            contains=("prod环境", "deployment日志"),
            not_contains=("deploy ment",),
        ),
        HintCase(
            id="apply_mixed_003",
            category="apply_mixed_language",
            text="这个俄文privet字段不要翻译",
            hints='  - 原词 "privet" -> 候选: ["привет"]',
            contains=("привет字段", "不要翻译"),
            not_contains=("privet字段",),
        ),
        HintCase(
            id="apply_mixed_004",
            category="apply_mixed_language",
            text="韩文annyeong字段原样保存",
            hints='  - 原词 "annyeong" -> 候选: ["안녕"]',
            contains=("안녕字段", "原样保存"),
            not_contains=("annyeong字段",),
        ),
        HintCase(
            id="apply_noise_001",
            category="apply_with_noise_cleanup",
            text="这个截图要写入剪切板板然后关闭",
            hints='  - 原词 "剪切板板" -> 候选: ["剪贴板"]',
            contains=("写入剪贴板", "关闭"),
            not_contains=("剪切板", "板板"),
        ),
        HintCase(
            id="apply_noise_002",
            category="apply_with_noise_cleanup",
            text="在线更新的veloo pack包下载失败",
            hints='  - 原词 "veloo pack包" -> 候选: ["Velopack包"]',
            contains=("在线更新", "Velopack", "下载失败"),
            not_contains=("veloo",),
        ),
        HintCase(
            id="apply_noise_003",
            category="apply_with_noise_cleanup",
            text="这个输入框要用control v v方式回填",
            hints='  - 原词 "control v v" -> 候选: ["Ctrl+V"]',
            contains=("输入框", "Ctrl+V", "回填"),
            not_contains=("control v v",),
        ),
        HintCase(
            id="apply_noise_004",
            category="apply_with_noise_cleanup",
            text="把截图上传到r two two存储桶",
            hints='  - 原词 "r two two" -> 候选: ["R2"]',
            contains=("截图", "R2存储桶"),
            not_contains=("r two",),
        ),
        HintCase(
            id="ignore_near_miss_001",
            category="ignore_bad_hint",
            text="客户说预算不是问题主要担心部署周期",
            hints='  - 原词 "预算" -> 候选: ["预览"]\n  - 原词 "周期" -> 候选: ["周琪"]',
            contains=("预算不是问题", "部署周期"),
            not_contains=("预览", "周琪"),
        ),
        HintCase(
            id="ignore_near_miss_002",
            category="ignore_bad_hint",
            text="医生说血压趋势需要连续记录三天",
            hints='  - 原词 "血压" -> 候选: ["雪鸭"]\n  - 原词 "三天" -> 候选: ["3天后"]',
            contains=("血压趋势", "连续记录三天"),
            not_contains=("雪鸭", "3天后"),
        ),
        HintCase(
            id="ignore_near_miss_003",
            category="ignore_bad_hint",
            text="我不是要翻译这段英文只是要保留原文",
            hints='  - 原词 "英文" -> 候选: ["English"]\n  - 原词 "原文" -> 候选: ["source text"]',
            contains=("我不是要翻译", "英文", "原文"),
            not_contains=("English", "source text"),
        ),
        HintCase(
            id="choose_context_001",
            category="choose_contextual_hint",
            text="这个缓存命中绿太低了",
            hints='  - 原词 "命中绿" -> 候选: ["命中率", "命中率低"]',
            contains=("缓存命中率太低",),
            not_contains=("命中绿",),
        ),
        HintCase(
            id="choose_context_002",
            category="choose_contextual_hint",
            text="这个安装包要支持开机紫气",
            hints='  - 原词 "开机紫气" -> 候选: ["开机自启"]',
            contains=("安装包", "开机自启"),
            not_contains=("开机紫气",),
        ),
        HintCase(
            id="choose_context_003",
            category="choose_contextual_hint",
            text="管理端的号池平太登录不了",
            hints='  - 原词 "号池平太" -> 候选: ["号池平台"]',
            contains=("管理端", "号池平台", "登录不了"),
            not_contains=("号池平太",),
        ),
        HintCase(
            id="choose_context_004",
            category="choose_contextual_hint",
            text="这个接口返回的状态吗是四零一",
            hints='  - 原词 "状态吗" -> 候选: ["状态码"]',
            contains=("状态码", "401"),
            not_contains=("状态吗",),
        ),
    ]


def evaluate(case: HintCase, output: str) -> tuple[bool, list[str]]:
    """空白归一化后再匹配（空格排版差异不算失败），大小写保持敏感以校验品牌写法。"""
    import re

    failures: list[str] = []
    output_compact = re.sub(r"\s+", "", output)
    for value in case.contains:
        value_compact = re.sub(r"\s+", "", value)
        if value and value not in output and value_compact not in output_compact:
            failures.append(f"missing contains={value!r}")
    for value in case.not_contains:
        if value and value in output:
            failures.append(f"unexpected contains={value!r}")
    return not failures, failures


async def run_case(
    service: LLMService,
    case: HintCase,
    semaphore: asyncio.Semaphore,
    platform: str,
    provider: str,
    model: str,
) -> HintResult:
    async with semaphore:
        start = time.monotonic()
        try:
            output = await service.run(
                operation="transcribe",
                transcript=case.text,
                correction_hints=case.hints,
                client_platform=platform,
                provider=provider or None,
                model=model or None,
                user_email=None,
                flow_name="standard",
                transcript_language="zh",
            )
        except Exception as exc:
            output = f"ERROR {type(exc).__name__}: {exc}"
        latency_ms = int((time.monotonic() - start) * 1000)
        passed, failures = evaluate(case, output)
        if output.startswith("ERROR "):
            passed = False
            failures.append("llm_error")
        return HintResult(case=case, output=output, latency_ms=latency_ms, passed=passed, failures=failures)


def select_cases(args: argparse.Namespace, cases: list[HintCase]) -> list[HintCase]:
    selected = cases
    if args.category:
        categories = set(args.category)
        selected = [case for case in selected if case.category in categories]
    if args.id:
        ids = set(args.id)
        selected = [case for case in selected if case.id in ids]
    return selected


def write_results(path: Path, results: list[HintResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        for result in results:
            file.write(json.dumps({
                "id": result.case.id,
                "category": result.case.category,
                "input": result.case.text,
                "correction_hints": result.case.hints,
                "output": result.output,
                "passed": result.passed,
                "failures": result.failures,
                "latency_ms": result.latency_ms,
            }, ensure_ascii=False) + "\n")


def print_summary(results: list[HintResult], show_failures: int) -> None:
    total = len(results)
    passed = sum(1 for result in results if result.passed)
    rate = passed / total * 100 if total else 0
    latencies = [result.latency_ms for result in results]
    p50 = int(statistics.median(latencies)) if latencies else 0
    p95 = int(sorted(latencies)[int(len(latencies) * 0.95) - 1]) if len(latencies) >= 2 else p50
    print(f"TOTAL={total} PASSED={passed} FAILED={total - passed} PASS_RATE={rate:.1f}% P50={p50}ms P95={p95}ms")

    by_category: dict[str, list[HintResult]] = {}
    for result in results:
        by_category.setdefault(result.case.category, []).append(result)
    for category in sorted(by_category):
        items = by_category[category]
        ok = sum(1 for item in items if item.passed)
        print(f"{category}: {ok}/{len(items)} ({ok / len(items) * 100:.1f}%)")

    failures = [result for result in results if not result.passed]
    if failures:
        print("\nFAILURES")
        for result in failures[:show_failures]:
            print(f"- {result.case.id} [{result.case.category}] {', '.join(result.failures)}")
            print(f"  IN   : {result.case.text}")
            print(f"  HINTS: {result.case.hints}")
            print(f"  OUT  : {result.output}")


async def async_main(args: argparse.Namespace) -> int:
    cases = select_cases(args, build_cases())
    if args.dry_run:
        print(f"selected={len(cases)}")
        for case in cases:
            print(json.dumps(case.__dict__, ensure_ascii=False))
        return 0

    if LLMService is None:
        raise RuntimeError("LLMService dependencies are not installed. Use --dry-run to inspect cases locally.")

    service = LLMService()
    semaphore = asyncio.Semaphore(args.concurrency)
    results = await asyncio.gather(*[
        run_case(service, case, semaphore, args.platform, args.provider, args.model)
        for case in cases
    ])
    if args.output:
        write_results(Path(args.output), results)
    print_summary(results, args.show_failures)
    failed = sum(1 for result in results if not result.passed)
    return 1 if args.fail_on_failure and failed else 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Correction Hints prompt regression cases.")
    parser.add_argument("--platform", default="windows")
    parser.add_argument("--provider", default="")
    parser.add_argument("--model", default="")
    parser.add_argument("--category", action="append")
    parser.add_argument("--id", action="append")
    parser.add_argument("--concurrency", type=int, default=3)
    parser.add_argument("--output", default="")
    parser.add_argument("--show-failures", type=int, default=20)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fail-on-failure", action="store_true")
    return parser.parse_args()


def main() -> int:
    return asyncio.run(async_main(parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
