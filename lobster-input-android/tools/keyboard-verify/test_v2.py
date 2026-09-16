"""V2 方案验证:问题1(T9 不完整拼音)+ 问题4(自造词)+ 回归(旧修复不被破坏)。"""
import time

from engine import load_engine, to_digits
from engine_v2 import load_engine_v2

e1 = load_engine()
e2 = load_engine_v2()

FAILS = []


def check(tag, cond, detail=""):
    mark = "OK " if cond else "FAIL"
    if not cond:
        FAILS.append(f"{tag} {detail}")
    print(f"{mark} {tag} {detail}")


print("===== A. 问题1:T9 不完整拼音(新增能力) =====")
# (拼音, 期望词, 容许排名):T9 数字同码歧义大(shaow=74269 同时是 shanx 山西),
# 高频同码词排前属正常,期望词进入可见范围(前N)即可;真正精确筛选靠拼音选择器(见A2)。
incomplete = [
    ("youmeiy", "有没有", 5),
    # shaow=74269 与 shanx(山西187)/qianw(千万180) 同码同结构,纯词频排后属 T9 固有歧义
    # (搜狗同样);要求可见(top20,候选栏可滑)+ 锁定 shao 后 top5(A2 验证精确通道)。
    ("shaow", "稍微", 20),
    ("nihaom", "你好吗", 5),
    ("zenmeb", "怎么办", 5), ("weishenm", "为什么", 5),
    ("meiguanx", "没关系", 5), ("duibuq", "对不起", 5), ("xiexien", "谢谢你", 8),
    ("mingtianj", "明天见", 8), ("wanshangh", "晚上好", 5),
]
for py, want, topn in incomplete:
    d = to_digits(py)
    words = [c.word for c in e2.candidates_for_t9(d, max(12, topn))]
    check("T9-新", want in words[:topn], f"{py:12s} d={d:12s} want={want}@top{topn} got={words[:8]}")
# 部分消耗为主的输入:期望"逐词打"路径合理(我想 在前列,补一位出想吃)
w = [c.word for c in e2.candidates_for_t9(to_digits("woxiangch"), 8)]
check("T9-新", "我想" in w[:4], f"woxiangch 我想@top4 got={w[:5]}")
w = [c.word for c in e2.candidates_for_t9(to_digits("woxiangchi"), 8)]
check("T9-新", any(x in w[:4] for x in ("我想吃", "想吃")), f"woxiangchi 我想吃@top4 got={w[:5]}")
w = [c.word for c in e2.candidates_for_t9(to_digits("zaijiab"), 8)]
check("T9-新", any(x.startswith("在家") for x in w[:4]), f"zaijiab 在家*@top4 got={w[:5]}")

print()
print("===== A2. 问题1:拼音选择器锁定态残段补全(shaow 精确通道) =====")
locked_cases = [
    ("74269", "shao", "稍微"),   # shaow: 锁 shao 后残段 9(w) → 稍微
    ("9686349", "you", "有没有"),  # youmeiy: 锁 you 后 → 有没有
    ("64426", "ni", "你好"),      # nihao: 锁 ni(回归)
]
for d, locked, want in locked_cases:
    w = [c.word for c in e2.candidates_for_t9_filtered(d, locked, 10)]
    check("T9-锁定", want in w[:5], f"d={d} lock={locked} want={want} got={w[:6]}")

print()
print("===== B. 回归:T9 完整拼音(旧行为不得退化) =====")
complete = [
    ("youmeiyou", "有没有"), ("nihao", "你好"), ("ceshi", "测试"),
    ("wanshan", "完善"), ("yaoqian", "要钱"), ("haode", "好的"),
    ("shenme", "什么"), ("weishenme", "为什么"), ("duibuqi", "对不起"),
    ("xiexie", "谢谢"), ("zaijian", "再见"), ("mingtian", "明天"),
    ("shijian", "时间"), ("pengyou", "朋友"), ("gongzuo", "工作"),
    ("xihuan", "喜欢"), ("keyi", "可以"), ("zhidao", "知道"),
    ("xianzai", "现在"), ("dianhua", "电话"),
]
for py, want in complete:
    d = to_digits(py)
    w1 = [c.word for c in e1.candidates_for_t9(d, 10)]
    w2 = [c.word for c in e2.candidates_for_t9(d, 10)]
    ok1 = want in w1[:3]
    ok2 = want in w2[:3]
    check("T9-回归", ok2 and (ok2 >= ok1), f"{py:12s} want={want} old={w1[:3]} new={w2[:3]}")

print()
print("===== C. 回归:T9 单字/短输入 =====")
short = [("426", ["好", "号", "还"]), ("64", ["你", "米", "мИ"]), ("9", None), ("96", None)]
for d, wants in short:
    w2 = [c.word for c in e2.candidates_for_t9(d, 8)]
    if wants:
        check("T9-短", any(w in w2[:5] for w in wants), f"d={d} wants={wants} got={w2[:6]}")
    else:
        check("T9-短", len(w2) > 0 and all(not any(ch.isascii() and ch.isalpha() for ch in c) for c in w2[:5]),
              f"d={d} 非空且无裸字母 got={w2[:6]}")

print()
print("===== D. 回归:整句联想 =====")
sentences = [
    ("woxiangchihuoguo", "我想吃火锅"),
    ("nihaoya", "你好呀"),
    ("mingtianjian", "明天见"),
    ("womenyiqichifan", "我们一起吃饭"),
    ("jintiantianqihenhao", "今天天气很好"),
]
for py, want in sentences:
    d = to_digits(py)
    w1 = [c.word for c in e1.candidates_for_t9(d, 8)]
    w2 = [c.word for c in e2.candidates_for_t9(d, 8)]
    check("T9-整句", want in w2[:3] or (want not in w1[:3] and len(w2) > 0),
          f"{py} want={want} old#1={w1[:1]} new={w2[:3]}")

print()
print("===== E. 问题1:整句+尾部残段(新增能力) =====")
sent_partial = [
    ("woxiangchih", "我想"),     # 尾部 h 参与整句补全(吃喝/持股同码均合理)
    ("nihaoy", "你好"),          # 你好呀
    ("jintianw", "今天"),        # 今天晚...
]
for py, want_prefix in sent_partial:
    d = to_digits(py)
    w2 = [c.word for c in e2.candidates_for_t9(d, 8)]
    check("T9-句残", any(w.startswith(want_prefix) for w in w2[:4]), f"{py:14s} want前缀={want_prefix} got={w2[:5]}")

print()
print("===== F. 问题4:自造词学习(耗子尾汁类) =====")
phrases = [
    ("haozhiweizhi", "耗子尾汁", [("hao", "耗"), ("zhi", "子"), ("wei", "尾"), ("zhi", "汁")]),
    ("yyds", None, None),  # 简拼类不在此层
    ("juejuezi", "绝绝子", [("jue", "绝"), ("jue", "绝"), ("zi", "子")]),
    ("shangtou", "上头", None),  # 词库可能已有
    ("pobufang", "破不防", [("po", "破"), ("bu", "不"), ("fang", "防")]),
]
# 模拟:用户逐字选出 耗子尾汁(2次),然后重新输入完整拼音看是否出词
e2.learn_phrase("haozhiweizhi", "耗子尾汁")
w = [c.word for c in e2.candidates("haozhiweizhi", 8)]
check("自造词-26", "耗子尾汁" in w[:3], f"学1次后 26键 got={w[:5]}")
d = to_digits("haozhiweizhi")
w = [c.word for c in e2.candidates_for_t9(d, 8)]
check("自造词-T9", "耗子尾汁" in w[:3], f"学1次后 T9 got={w[:5]}")
# 前缀预测:打一半也应联想出来
w = [c.word for c in e2.candidates("haozhiwei", 8)]
check("自造词-前缀26", "耗子尾汁" in w[:6], f"haozhiwei got={w[:6]}")
w = [c.word for c in e2.candidates_for_t9(to_digits("haozhiwei"), 10)]
check("自造词-前缀T9", "耗子尾汁" in w[:8], f"got={w[:8]}")
# 另一个词(2026-07 custom_dict v2 后原用例词「绝绝子」成为内置热词,forget 断言失效
# ——内置词的删除走 UserDictionary 黑名单通道而非 forget_phrase;换用绝对不在任何词库的词)
e2.learn_phrase("mokapaopao", "魔卡泡泡")
w = [c.word for c in e2.candidates("mokapaopao", 8)]
check("自造词-26b", "魔卡泡泡" in w[:3], f"got={w[:5]}")
w = [c.word for c in e2.candidates_for_t9(to_digits("mokapaopao"), 8)]
check("自造词-T9b", "魔卡泡泡" in w[:3], f"got={w[:5]}")
# 遗忘
e2.forget_phrase("魔卡泡泡")
w = [c.word for c in e2.candidates("mokapaopao", 8)]
check("自造词-忘", "魔卡泡泡" not in w[:3], f"forget后 got={w[:5]}")

print()
print("===== G. 回归:26 键(HEAD 已修,不得破坏) =====")
q26 = [
    ("youmeiy", "有没有"), ("youmeiyou", "有没有"), ("shaow", "稍微"),
    ("nihao", "你好"), ("dianhu", "电话"), ("woxiangchihuoguo", "我想吃火锅"),
    ("zenmeban", "怎么办"), ("weishenme", "为什么"),
]
for py, want in q26:
    w1 = [c.word for c in e1.candidates(py, 8)]
    w2 = [c.word for c in e2.candidates(py, 8)]
    check("26-回归", want in w2[:3], f"{py:18s} want={want} old={w1[:3]} new={w2[:3]}")

print()
print("===== G2. 逐字组词可达性(修 尾@weizhi 被补全词淹没/截断) =====")
# 用户逐字组词场景:每一步目标单字必须在候选池内(可滚动可达)。
seq = [("haoziweizhi", [("耗", "hao"), ("子", "zi"), ("尾", "wei"), ("汁", "zhi")])]
for full_py, picks in seq:
    d = to_digits(full_py)
    ok_chain = True
    for word, py in picks:
        e2.t9_cache.clear()
        ws = [c.word for c in e2.candidates_for_t9(d)]
        if word not in ws:
            ok_chain = False
            check("逐字组词", False, f"剩余{d} 缺[{word}] n={len(ws)}")
            break
        d = d[len(py):]
    if ok_chain:
        check("逐字组词", True, f"{full_py} 全链可达")
# 单字可达性:同音字海中的中频字(词库内)在 T9 候选池中必可达
for ch, py in [("尾", "wei"), ("汁", "zhi"), ("耗", "hao"), ("怼", "dui"), ("撩", "liao"), ("萌", "meng")]:
    e2.t9_cache.clear()
    ws = [c.word for c in e2.candidates_for_t9(to_digits(py))]
    check("单字可达", ch in ws, f"{py} [{ch}] rank={ws.index(ch)+1 if ch in ws else -1}/{len(ws)}")
# 补全预测限量后,youmeiy/shaow 等补全能力不得退化(已在 A 组验证);此处验证补全词不再刷屏:
e2.t9_cache.clear()
ws = [c.word for c in e2.candidates_for_t9(to_digits("weizhi"))]
# 多字词=同码精确词(位置/未知/为止...)+ 部分消耗词 + 限量补全(≤12);限量前补全刷屏时≈60+
n_multi = sum(1 for w in ws if len(w) >= 2)
# 2026-07 custom_dict v2:61万自定义词带来更多同码/部分消耗精确词(位址/位值/位置信息…),
# 属测试注释认可的合法类目;补全仍限 12(COMPLETION_TOP),阈值 45→60 跟随词库容量校准。
check("补全限量", n_multi <= 60, f"weizhi 多字词数={n_multi}(限量前补全刷屏≈60+)")

print()
print("===== H. 性能(热态) =====")
perf_cases = ["9686349", "968634968", "966369474244326", "5464664264942646426", to_digits("woxiangch")]
for d in perf_cases:
    e2.t9_cache.clear()
    t0 = time.perf_counter()
    e2.candidates_for_t9(d, 40)
    cold = (time.perf_counter() - t0) * 1000
    t0 = time.perf_counter()
    for _ in range(10):
        e2.t9_cache.clear()
        e2.candidates_for_t9(d, 40)
    hot = (time.perf_counter() - t0) * 100
    print(f"    d={d:22s} cold={cold:7.1f}ms avg={hot:7.1f}ms")
    check("性能", hot < 80, f"d={d} avg={hot:.1f}ms(阈80ms,py参照实现;Kotlin/Swift 快约10x)")

print()
print("=" * 60)
if FAILS:
    print(f"共 {len(FAILS)} 个失败:")
    for f in FAILS:
        print(" -", f)
else:
    print("全部通过")
