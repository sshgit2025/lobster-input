"""
Prompt regression runner for transcribe post-processing.

Runs deterministic, business-oriented cases against the real LLMService and
scores lightweight expectations. The corpus is generated in code so it stays
easy to extend without maintaining a huge hand-written fixture file.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import random
import re
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

try:
    from app.services.llm.llm_service import LLMService
except ModuleNotFoundError:
    LLMService = None


@dataclass(frozen=True)
class PromptCase:
    id: str
    category: str
    text: str
    correction_hints: str = ""
    contains: tuple[str, ...] = ()
    not_contains: tuple[str, ...] = ()
    regex: tuple[str, ...] = ()
    not_regex: tuple[str, ...] = ()
    note: str = ""


@dataclass
class CaseResult:
    case: PromptCase
    output: str
    latency_ms: int
    passed: bool
    failures: list[str] = field(default_factory=list)


FILLERS = ("嗯", "啊", "呃", "就是说", "我的意思是说", "我想说的是", "对吧", "对不对")
TARGET_CASE_COUNT = 570
QUESTION_MARKERS = ("怎么样", "有没有", "能不能", "是不是", "为什么", "怎么办", "如何", "要不要", "可不可以", "大不大", "哪里", "可以吗")


def expect_clean_text(case_id: str, category: str, text: str, contains: Iterable[str] = ()) -> PromptCase:
    return PromptCase(
        id=case_id,
        category=category,
        text=text,
        contains=tuple(contains),
        not_contains=FILLERS,
    )


def build_cases() -> list[PromptCase]:
    cases: list[PromptCase] = []

    # Short text and punctuation: fragments should not be forced into sentence punctuation.
    short_terms = [
        ("剪切板", ("剪贴板",), ("剪切板",)),
        ("deepseek最新版本", ("DeepSeek最新版本",), ()),
        ("打开设置页面", ("打开设置页面",), ()),
        ("后台运行", ("后台运行",), ()),
        ("检查更新", ("检查更新",), ()),
        ("今日汇率", ("今日汇率",), ()),
        ("医保报销比例", ("医保报销比例",), ()),
        ("合同违约金", ("合同违约金",), ()),
        ("明天北京天气怎么样", ("明天北京天气怎么样",), ()),
        ("帮我检查一下这个截图功能", ("检查", "截图功能"), ()),
    ]
    for i, (text, contains, not_contains) in enumerate(short_terms, 1):
        is_question_like = any(marker in text for marker in QUESTION_MARKERS)
        cases.append(PromptCase(
            id=f"short_{i:03d}",
            category="short_punctuation",
            text=text,
            contains=contains,
            not_contains=not_contains,
            not_regex=(r"[。！？!?]$",) if len(text) <= 12 and not is_question_like else (),
        ))

    question_intent_cases = [
        (
            "你检查一下当前的代码看看有没有什么问题呀然后能不能给我一些建议呀",
            ("有没有什么问题", "能不能", "建议"),
            ("检查代码问题且需要给我建议",),
        ),
        (
            "这个设置是不是会影响线上环境呀如果会的话应该怎么处理呢",
            ("是不是", "如果会", "怎么处理"),
            ("这个设置会影响线上环境",),
        ),
        (
            "你帮我看一下为什么录音浮窗会突然消失呀",
            ("为什么", "录音浮窗", "突然消失"),
            ("录音浮窗突然消失这个问题",),
        ),
        (
            "能不能帮我确认一下DeepSeek最新版本到底是不是V三",
            ("能不能", "DeepSeek", "是不是V3"),
            ("确认DeepSeek最新版本是V3",),
        ),
        (
            "如果今天发布的话风险大不大有没有必要先灰度",
            ("风险大不大", "有没有必要", "灰度"),
            ("发布风险大",),
        ),
        (
            "这个接口现在还有没有超时问题要不要加重试",
            ("还有没有", "要不要", "重试"),
            ("接口现在还有超时问题",),
        ),
        (
            "你看看这个方案哪里不太合理有没有更稳妥的做法",
            ("哪里不太合理", "有没有", "更稳妥"),
            ("方案不合理且需要更稳妥做法",),
        ),
        (
            "明天下午三点开会可以吗还是要改到四点",
            ("可以吗", "还是", "4点"),
            (),
        ),
    ]
    for i, (text, contains, not_contains) in enumerate(question_intent_cases, 1):
        cases.append(PromptCase(
            id=f"question_intent_{i:03d}",
            category="question_intent",
            text=text,
            contains=contains,
            not_contains=not_contains,
            regex=(r"[？?]",),
        ))

    # Semantic preservation and Correction Hints integration guards.
    semantic_cases = [
        ("可以的小哥哥，你是干这个的", ("小哥哥", "你是干这个的")),
        ("好的小姐姐这个问题我稍后处理", ("小姐姐", "问题", "稍后处理")),
        ("谢谢师傅你先帮我看一下这个配置", ("师傅", "你先帮我", "配置")),
        ("老板这个线上问题不是我刚刚改出来的", ("老板", "不是我", "改出来")),
        ("非常好，你做的这个事情是对的，然后可以帮我提交git并推送远程", ("非常好", "事情是对的", "提交 git", "推送远程")),
        ("嗯，非常好你这个效果我觉得好多了嗯，感觉我们的语音输入法又一次进化了。", ("非常好", "效果", "好多了", "语音输入法", "进化")),
        ("很好，这个方向是对的，接下来帮我把提示词同步到四个端", ("很好", "方向是对的", "提示词", "四个端")),
        ("不错，刚才那个修复效果挺稳定的，继续跑一下完整回归", ("不错", "效果挺稳定", "完整回归")),
        ("辛苦了，这次候选词处理得比较稳，顺便帮我部署到preview服务器", ("辛苦了", "候选词", "比较稳", "preview", "服务器")),
        ("抱歉刚才我说得不太清楚，我的意思是保留疑问语气", ("抱歉", "我说得不太清楚", "保留疑问语气")),
    ]
    for i, (text, contains) in enumerate(semantic_cases, 1):
        cases.append(PromptCase(
            id=f"semantic_{i:03d}",
            category="semantic_preservation",
            text=text,
            contains=contains,
        ))

    correction_hint_cases = [
        (
            "可以的小哥哥，你是干这个的",
            "  - 原词 \"小哥哥\" -> 候选: [\"小广告\", \"小格格\"]",
            ("小哥哥", "你是干这个的"),
            ("小广告", "小格格"),
        ),
        (
            "我今天想去银行办卡",
            "  - 原词 \"银行\" -> 候选: [\"营养\", \"影音\"]",
            ("银行", "办卡"),
            ("营养", "影音"),
        ),
        (
            "这个接口不要把语音停顿都写成逗号",
            "  - 原词 \"逗号\" -> 候选: [\"豆号\", \"都好\"]",
            ("接口", "语音停顿", "逗号"),
            ("豆号", "都好"),
        ),
        (
            "这个接口需要重新布署preview环境",
            "  - 原词 \"布署\" -> 候选: [\"部署\"]",
            ("部署",),
            ("布署",),
        ),
    ]
    for i, (text, hints, contains, not_contains) in enumerate(correction_hint_cases, 1):
        regex = (r"preview\s*环境",) if i == 4 else ()
        cases.append(PromptCase(
            id=f"correction_hint_{i:03d}",
            category="correction_hints",
            text=text,
            correction_hints=hints,
            contains=contains,
            not_contains=not_contains,
            regex=regex,
        ))

    # Filler cleanup and self-correction.
    filler_templates = [
        ("嗯就是帮我看一下{topic}为什么一直{problem}啊", ("帮我看一下",)),
        ("我的意思是说{topic}吧就是打开以后呢它会{problem}对吧", ("打开",)),
        ("我想说的是不是先{wrong}啊不是不是先{right}再{wrong}", ("不是先", "先")),
        ("那个{topic}有点{problem}你明白吧帮我整理一下", ("帮我整理",)),
        ("呃这个{topic}就是需要先{first}然后再{second}", ("先", "再")),
    ]
    topics = ["接口", "登录页", "历史记录", "快捷键", "截图功能", "回填流程", "账号区域", "安装包", "在线更新", "麦克风选择"]
    problems = ["报错", "转圈", "卡住", "闪退", "无响应", "显示错乱", "重复弹窗", "识别失败"]
    actions = ["提交代码", "跑测试", "备份数据", "重启服务", "部署 preview", "查看日志"]
    idx = 1
    for topic in topics:
        for problem in problems[:4]:
            template, contains = filler_templates[idx % len(filler_templates)]
            wrong = actions[idx % len(actions)]
            right = actions[(idx + 1) % len(actions)]
            text = template.format(topic=topic, problem=problem, wrong=wrong, right=right, first=right, second=wrong)
            if contains == ("帮我整理",):
                contains = (topic, problem)
            elif contains == ("先", "再"):
                contains = ("先", right, wrong)
            cases.append(expect_clean_text(f"filler_{idx:03d}", "filler_cleanup", text, contains))
            idx += 1

    # Punctuation and semantic-boundary cases.
    punctuation_cases = [
        ("这个接口 如果失败 就重试 三次 不要 每个停顿 都加逗号", ("不要", "逗号")),
        ("如果登录失败就提示用户重新输入验证码不要直接清空邮箱", ("如果", "不要")),
        ("不是先关闭 UI 再截图而是截图完成后立刻写入剪贴板", ("不是先", "而是", "剪贴板")),
        ("合同里如果没有写违约金就按照实际损失计算不要乱填百分比", ("如果", "不要")),
        ("血压如果连续三天偏高就记录下来不要自己乱吃药", ("如果", "不要")),
        ("这个表格如果金额为空就保留空值不要写零", ("如果", "不要")),
        ("用户说的是V五不是五个版本不要理解错", ("V5", "不是")),
        ("这句话只是标题新员工入职流程不要加句号", ("新员工入职流程",)),
    ]
    for i, (text, contains) in enumerate(punctuation_cases, 1):
        cases.append(PromptCase(
            id=f"punctuation_{i:03d}",
            category="punctuation",
            text=text,
            contains=contains,
            not_contains=("剪切板",),
        ))

    # Numbers and structured formats.
    number_cases = [
        ("验证码是一二三四", ("1234",)),
        ("手机号是一三九三五二七三三三三", ("13935273333",)),
        ("订单号是二零二六零五零七零零一", ("20260507001",)),
        ("金额是一千二百三十四块五毛六", ("1234",)),
        ("折扣是百分之十五", ("15%",)),
        ("版本号是V四还是V五", ("V4", "V5")),
        ("API延迟大概二百毫秒", ("200毫秒",)),
        ("二零二六年五月七号下午三点开会", ("2026年5月7", "下午3点")),
        ("我们家有五个兄弟姐妹其中三个是男孩两个是女孩", ("五个", "三个", "两个")),
        ("我需要三个方案不是3.0版本", ("三个方案", "3.0版本")),
    ]
    for i, (text, contains) in enumerate(number_cases, 1):
        cases.append(PromptCase(
            id=f"number_{i:03d}",
            category="numbers",
            text=text,
            contains=contains,
        ))

    # Identifiers: account, domain, path, variables.
    identifier_cases = [
        ("账号是邵华点孙邮箱是邵华点孙艾特gmail点com", ("shaohua.sun", "shaohua.sun@gmail.com")),
        ("路径是user斜杠邵华下划线孙杠test变量名是user下划线id", ("user/shaohua_sun", "user_id")),
        ("域名是lobster input点com斜杠privacy点html", ("example.org/privacy.html",)),
        ("变量名叫用户下划线id不是用户id", ("user_id",)),
        ("命令是git checkout杠b feature斜杠hotkey", ("git checkout -b feature/hotkey",)),
        ("文件名是deploy下划线preview点sh", ("deploy_preview.sh",)),
        ("接口路径是api斜杠v一斜杠users", ("api/v1/users",)),
        ("邮箱是support艾特lobster input点com", ("support@example.org",)),
    ]
    for i, (text, contains) in enumerate(identifier_cases, 1):
        cases.append(PromptCase(
            id=f"identifier_{i:03d}",
            category="identifiers",
            text=text,
            contains=contains,
            not_contains=("艾特", "斜杠", "下划线"),
        ))

    # Multilingual and code-switching.
    multilingual_cases = [
        ("My name is 邵华点孙对邵华点孙别搞错了啊", ("My name is", "shaohua.sun")),
        ("сравни deepseek V三 和 GPT五 的 API latency", ("сравни", "DeepSeek", "V3", "GPT-5", "API latency")),
        ("明日のmeetingは十点开始然后下午review一下PR", ("明日", "meeting", "review", "PR")),
        ("오늘 meeting 十点开始下午review PR", ("오늘", "meeting", "review", "PR")),
        ("please check 这个接口为什么 timeout", ("please check", "接口", "timeout")),
        ("帮我把 status code 四零四 写成英文解释", ("status code 404",)),
        ("Das ist 一个preview环境的问题", ("Das ist", "preview")),
        ("révise 这个 privacy policy 的 wording", ("révise", "privacy policy", "wording")),
    ]
    for i, (text, contains) in enumerate(multilingual_cases, 1):
        cases.append(PromptCase(
            id=f"multilingual_{i:03d}",
            category="multilingual",
            text=text,
            contains=contains,
        ))
    cases.extend([
        PromptCase(
            id="multilingual_009",
            category="multilingual",
            text="오늘 회의는 오후 세 시에 시작하고 끝나면 바로 공유해 주세요",
            contains=("오늘", "회의", "오후", "공유해 주세요"),
            not_contains=("今天", "会议", "下午", "分享"),
            note="pure Korean must not be translated to Chinese",
        ),
        PromptCase(
            id="multilingual_010",
            category="multilingual",
            text="明日の会議は午後三時に始まります終わったらすぐ共有してください",
            contains=("明日", "会議", "午後", "共有してください"),
            not_contains=("明天", "会议", "下午", "请分享"),
            note="pure Japanese must not be translated to Chinese",
        ),
        PromptCase(
            id="multilingual_011",
            category="multilingual",
            text="오늘 preview 환경에서 timeout 문제가 다시 발생했어요",
            contains=("오늘", "preview", "timeout", "발생했어요"),
            not_contains=("今天", "环境", "超时", "发生"),
            note="Korean with technical English should keep code-switch",
        ),
    ])

    perspective_cases = [
        (
            "我想查询目前市面上deepseek模型的最新版本然后查询gpt模型的最新版本最后核实deepseek最新版本是不是V四因为我不确定也可能是V三",
            ("我", "DeepSeek", "GPT", "V4", "V3"),
            ("用户", "他"),
        ),
        (
            "我们不是要先关闭UI而是要等截图写入剪贴板以后再关闭浮窗",
            ("我们", "不是", "而是", "剪贴板"),
            ("用户", "他们"),
        ),
        (
            "你帮我记录一下我今天不想改这个设置因为我担心影响线上环境",
            ("你", "我今天", "我担心", "线上环境"),
            ("用户担心",),
        ),
    ]
    for i, (text, contains, not_contains) in enumerate(perspective_cases, 1):
        cases.append(PromptCase(
            id=f"perspective_{i:03d}",
            category="perspective",
            text=text,
            contains=contains,
            not_contains=not_contains,
        ))

    # Professional domains: IT, finance, legal, medical, education, sales, ops.
    domains = {
        "it": [
            ("Redis缓存命中率下降需要检查key过期策略和连接池", ("Redis", "缓存命中率", "key", "连接池")),
            ("前端路由刷新以后四零四应该配置nginx fallback到index.html", ("前端路由", "404", "fallback", "index.html")),
            ("这个pull request先跑单元测试再合并不要跳过CI", ("pull request", "单元测试", "CI")),
            ("数据库迁移失败要先回滚再检查schema版本", ("数据库迁移", "回滚", "schema")),
        ],
        "finance": [
            ("本季度毛利率下降主要因为获客成本和云服务成本都增加了", ("毛利率", "获客成本", "云服务成本")),
            ("人民币兑美元汇率波动会影响海外收入折算", ("人民币兑美元", "汇率", "海外收入")),
            ("现金流预测要区分应收账款和实际到账", ("现金流", "应收账款", "实际到账")),
            ("基金净值回撤超过百分之五需要触发风控提醒", ("基金净值", "回撤", "5%", "风控")),
        ],
        "legal": [
            ("合同里没有约定管辖法院就不要随便写北京仲裁", ("合同", "管辖法院", "北京仲裁")),
            ("隐私政策要明确说明数据保存时间和用户删除权", ("隐私政策", "数据保存时间", "用户删除权")),
            ("这条条款可能涉及格式条款需要单独提示用户注意", ("格式条款", "单独提示")),
            ("如果用户撤回授权就必须停止处理对应个人信息", ("撤回授权", "停止处理", "个人信息")),
        ],
        "medical": [
            ("这个报告只记录血压趋势不要给诊断结论", ("血压趋势", "不要", "诊断结论")),
            ("空腹血糖连续偏高建议去医院复查不要自行用药", ("空腹血糖", "复查", "不要自行用药")),
            ("过敏史要写清楚青霉素和头孢都不能用", ("过敏史", "青霉素", "头孢")),
            ("运动建议要根据年龄体重和心率区间调整", ("运动建议", "年龄", "体重", "心率区间")),
        ],
        "education": [
            ("这节课先讲分数再讲小数最后做应用题", ("先讲分数", "再讲小数", "最后")),
            ("学生作文的问题不是词汇少而是结构不清楚", ("不是词汇少", "结构不清楚")),
            ("这道题要引导孩子自己画图不要直接给答案", ("画图", "不要直接给答案")),
            ("课程反馈里要区分理解困难和注意力不集中", ("理解困难", "注意力不集中")),
        ],
        "sales": [
            ("客户关注点不是价格而是部署周期和售后响应", ("不是价格", "部署周期", "售后响应")),
            ("报价单里把试用版和正式版权益分开写", ("报价单", "试用版", "正式版")),
            ("这次跟进先确认预算再约技术评审", ("先确认预算", "技术评审")),
            ("不要承诺定制功能下周一定上线", ("不要承诺", "定制功能")),
        ],
        "daily": [
            ("晚上下班以后先买菜再去接孩子", ("先买菜", "接孩子")),
            ("明天如果下雨就改成线上会议", ("如果下雨", "线上会议")),
            ("我不是不想去只是今天时间太赶", ("不是不想去", "时间太赶")),
            ("周末把客厅收拾一下顺便检查水电费", ("周末", "客厅", "水电费")),
        ],
    }
    idx = 1
    for category, items in domains.items():
        for text, contains in items:
            cases.append(PromptCase(
                id=f"domain_{category}_{idx:03d}",
                category=f"domain_{category}",
                text=text,
                contains=contains,
                not_contains=FILLERS,
            ))
            idx += 1

    # Large combinatorial real-world corpus. These cases keep the same scoring
    # style but cover varied wording, topics, and noisy ASR-like expressions.
    people = ["我", "用户", "客户", "医生", "老师", "财务", "法务", "运营", "开发", "测试"]
    verbs = ["希望", "要求", "建议", "反馈", "担心", "发现", "确认", "强调"]
    objects = [
        "登录流程", "截图功能", "剪贴板写入", "在线更新", "历史记录", "账号区域", "合同条款", "现金流预测",
        "血压记录", "课程反馈", "客户报价", "接口重试", "数据库迁移", "隐私政策", "发票抬头", "售后响应",
    ]
    constraints = [
        "不要先关闭窗口再处理结果",
        "如果失败就给出明确提示",
        "不是删除数据而是先备份",
        "必须保留用户原本的否定语气",
        "不要把语音停顿都写成逗号",
        "先验证状态再执行下一步",
        "不要把片段翻译成另一种语言",
        "需要区分测试环境和正式环境",
    ]
    idx = 1
    for person in people:
        for verb in verbs:
            for obj in objects[:8]:
                constraint = constraints[idx % len(constraints)]
                filler = ("嗯", "就是说", "我的意思是说", "那个")[idx % 4]
                text = f"{filler}{person}{verb}{obj}{constraint}啊"
                if constraint == "先验证状态再执行下一步":
                    constraint_checks = ("先验证", "状态", "执行下一步")
                elif constraint == "如果失败就给出明确提示":
                    constraint_checks = ("明确提示",)
                else:
                    constraint_checks = (constraint[:6],)
                cases.append(PromptCase(
                    id=f"generated_{idx:03d}",
                    category="generated_realistic",
                    text=text,
                    contains=(obj, *constraint_checks),
                    not_contains=FILLERS,
                ))
                idx += 1
                if len(cases) >= TARGET_CASE_COUNT:
                    break
            if len(cases) >= TARGET_CASE_COUNT:
                break
        if len(cases) >= TARGET_CASE_COUNT:
            break

    # Ensure stable order and ids.
    return cases


def evaluate(case: PromptCase, output: str) -> tuple[bool, list[str]]:
    failures: list[str] = []
    output_casefold = output.casefold()
    output_compact = re.sub(r"\s+", "", output_casefold)
    for value in case.contains:
        value_casefold = value.casefold()
        value_compact = re.sub(r"\s+", "", value_casefold)
        if value and value_casefold not in output_casefold and value_compact not in output_compact:
            failures.append(f"missing contains={value!r}")
    for value in case.not_contains:
        if value and value.casefold() in output_casefold:
            failures.append(f"unexpected contains={value!r}")
    for pattern in case.regex:
        if not re.search(pattern, output):
            failures.append(f"missing regex={pattern!r}")
    for pattern in case.not_regex:
        if re.search(pattern, output):
            failures.append(f"unexpected regex={pattern!r}")
    return not failures, failures


async def run_case(
    service,
    case: PromptCase,
    semaphore: asyncio.Semaphore,
    platform: str,
    provider: str | None,
    model: str | None,
    language: str,
) -> CaseResult:
    async with semaphore:
        start = time.monotonic()
        try:
            output = await service.run(
                operation="transcribe",
                transcript=case.text,
                client_platform=platform,
                provider=provider or None,
                model=model or None,
                user_email=None,
                correction_hints=case.correction_hints or None,
                flow_name="standard",
                transcript_language=language,
            )
        except Exception as exc:
            output = f"ERROR {type(exc).__name__}: {exc}"
        latency_ms = int((time.monotonic() - start) * 1000)
        passed, failures = evaluate(case, output)
        if output.startswith("ERROR "):
            passed = False
            failures.append("llm_error")
        return CaseResult(case=case, output=output, latency_ms=latency_ms, passed=passed, failures=failures)


def select_cases(args: argparse.Namespace, cases: list[PromptCase]) -> list[PromptCase]:
    selected = cases
    if args.category:
        wanted = set(args.category)
        selected = [case for case in selected if case.category in wanted]
    if args.id:
        wanted_ids = set(args.id)
        selected = [case for case in selected if case.id in wanted_ids]
    if args.sample:
        rng = random.Random(args.seed)
        selected = rng.sample(selected, min(args.sample, len(selected)))
    if args.limit:
        selected = selected[:args.limit]
    return selected


def write_cases(path: Path, cases: list[PromptCase]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        for case in cases:
            file.write(json.dumps(case.__dict__, ensure_ascii=False) + "\n")


def load_cases(path: Path) -> list[PromptCase]:
    cases: list[PromptCase] = []
    with path.open("r", encoding="utf-8") as file:
        for line in file:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            cases.append(PromptCase(
                id=row["id"],
                category=row["category"],
                text=row["text"],
                correction_hints=row.get("correction_hints", ""),
                contains=tuple(row.get("contains", ())),
                not_contains=tuple(row.get("not_contains", ())),
                regex=tuple(row.get("regex", ())),
                not_regex=tuple(row.get("not_regex", ())),
                note=row.get("note", ""),
            ))
    return cases


def write_results(path: Path, results: list[CaseResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        for result in results:
            row = {
                "id": result.case.id,
                "category": result.case.category,
                "input": result.case.text,
                "correction_hints": result.case.correction_hints,
                "output": result.output,
                "passed": result.passed,
                "failures": result.failures,
                "latency_ms": result.latency_ms,
            }
            file.write(json.dumps(row, ensure_ascii=False) + "\n")


def print_summary(results: list[CaseResult], show_failures: int) -> None:
    total = len(results)
    passed = sum(1 for result in results if result.passed)
    rate = passed / total * 100 if total else 0
    latencies = [result.latency_ms for result in results]
    p50 = int(statistics.median(latencies)) if latencies else 0
    p95 = int(sorted(latencies)[int(len(latencies) * 0.95) - 1]) if len(latencies) >= 2 else p50

    print(f"TOTAL={total} PASSED={passed} FAILED={total - passed} PASS_RATE={rate:.1f}% P50={p50}ms P95={p95}ms")

    by_category: dict[str, list[CaseResult]] = {}
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
            print(f"  IN : {result.case.text}")
            print(f"  OUT: {result.output}")


async def async_main(args: argparse.Namespace) -> int:
    cases = load_cases(Path(args.cases_file)) if args.cases_file else build_cases()
    if args.write_cases:
        write_cases(Path(args.write_cases), cases)
        print(f"wrote {len(cases)} cases to {args.write_cases}")
    selected = select_cases(args, cases)
    if args.dry_run:
        print(f"selected={len(selected)} total={len(cases)}")
        return 0

    if LLMService is None:
        raise RuntimeError("LLMService dependencies are not installed. Use --dry-run to inspect cases locally.")

    service = LLMService()
    semaphore = asyncio.Semaphore(args.concurrency)
    tasks = [
        run_case(service, case, semaphore, args.platform, args.provider, args.model, args.language)
        for case in selected
    ]
    results = await asyncio.gather(*tasks)

    if args.output:
        write_results(Path(args.output), results)
    print_summary(results, args.show_failures)
    failed = sum(1 for result in results if not result.passed)
    return 1 if args.fail_on_failure and failed else 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run transcribe prompt regression cases.")
    parser.add_argument("--platform", default="windows")
    parser.add_argument("--language", default="zh")
    parser.add_argument("--cases-file", default="")
    parser.add_argument("--provider", default="")
    parser.add_argument("--model", default="")
    parser.add_argument("--category", action="append")
    parser.add_argument("--id", action="append")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--sample", type=int, default=0)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--output", default="")
    parser.add_argument("--write-cases", default="")
    parser.add_argument("--show-failures", type=int, default=30)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fail-on-failure", action="store_true")
    return parser.parse_args()


def main() -> int:
    return asyncio.run(async_main(parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
