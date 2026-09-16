"""花式测试:模拟真实打字会话,自主发现不好用的功能。
1. 逐键输入:每一击后候选不得为空、不得出现裸字母候选(T9)。
2. 逐词选择消耗:模拟用户逐词把整句打完,验证 matchedLen 消耗链正确。
3. 自造词全流程:20 个网络词,逐字组合 → 学习 → 复现。
4. 学习调频:选过的词下次应排名提升。
"""
import random

from engine import load_engine, to_digits
from engine_v2 import load_engine_v2

e2 = load_engine_v2()
FAILS = []


def check(tag, cond, detail=""):
    if not cond:
        FAILS.append(f"{tag} {detail}")
        print(f"FAIL {tag} {detail}")


print("===== 1. 逐键输入稳定性(每击候选非空、T9 无裸字母) =====")
sentences_py = [
    "nihao", "woxiangchihuoguo", "jintiantianqizenmeyang", "mingtianjianba",
    "xiexienidebangzhu", "zhegedongxiduoshaoqian", "haozhiweizhi", "manmanlai",
    "buhaoyisi", "wanshangyiqichifanma", "zhoumoqunaliwan", "gongzuoxinkule",
]
for py in sentences_py:
    d = to_digits(py)
    for i in range(1, len(d) + 1):
        cands = e2.candidates_for_t9(d[:i], 20)
        check("逐键-T9非空", len(cands) > 0, f"{py[:i]} d={d[:i]} 空候选")
        for c in cands[:8]:
            has_ascii = any(ch.isascii() and ch.isalpha() for ch in c.word)
            # T9 里裸字母候选只允许在极端兜底(全串非法),此处输入都是合法拼音前缀
            check("逐键-T9无裸字母", not has_ascii, f"d={d[:i]} 出现裸字母候选 {c.word}")
    # 26 键逐键
    for i in range(1, len(py) + 1):
        cands = e2.candidates(py[:i], 20)
        check("逐键-26非空", len(cands) > 0, f"{py[:i]} 空候选")
print("    ...done", len(sentences_py), "句 × 全击键")

print()
print("===== 2. 逐词选择消耗链(T9) =====")
def type_and_pick(pinyin, expect_words=None, max_steps=12):
    """模拟:整串输入后反复选首个'消耗>0'的候选,直到 composing 清空。返回上屏文本。"""
    d = to_digits(pinyin)
    committed = []
    prev = None
    steps = 0
    while d and steps < max_steps:
        cands = e2.candidates_for_t9(d, 20)
        if not cands:
            return None, f"空候选 at d={d}"
        pick = None
        for c in cands:
            if c.matched_len > 0:
                pick = c
                break
        if pick is None:
            return None, f"无可消耗候选 at d={d}: {[x.word for x in cands[:5]]}"
        committed.append(pick.word)
        e2.learn_sequence(prev, pick.word)
        prev = pick.word
        d = d[pick.matched_len:]
        steps += 1
    return "".join(committed), None


session_cases = ["nihao", "woxiangchihuoguo", "jintianhenkaixin", "mingtianjian", "xiexieni"]
for py in session_cases:
    text, err = type_and_pick(py)
    check("消耗链", err is None and text, f"{py} err={err}")
    print(f"    {py:22s} → {text}")

print()
print("===== 3. 自造词全流程(20 个网络词/人名) =====")
custom_phrases = [
    ("haozhiweizhi", "耗子尾汁"), ("juejuezi", "绝绝子"), ("yygq", None),
    ("posifang", "破斯防"), ("shuanq", None), ("dianzijianmianli", "电子见面礼"),
    ("xiaozhassd", None), ("langlihaoqiu", "浪里好球"), ("yishishenwu", "一世神物"),
    ("zhangxiaoli", "张晓丽"), ("wangtiechui", "王铁锤"), ("lidangao", "李蛋糕"),
    ("chenpixia", "陈皮虾"), ("liuliuda", "溜溜哒"), ("gongjijiao", "公鸡叫"),
    ("maimaiti", "买买提"), ("doubaoqia", "豆包恰"), ("xiongdazhuang", "熊大壮"),
    ("feichangganxie", None), ("kuaidianshuijiao", None),
]
learned = 0
for py, word in custom_phrases:
    if word is None:
        continue
    # 检查学习前:词不应在 top3(否则说明词库已有,不测)
    pre = [c.word for c in e2.candidates(py, 5)]
    if word in pre[:3]:
        continue
    e2.learn_phrase(py, word)
    learned += 1
    post26 = [c.word for c in e2.candidates(py, 5)]
    check("自造词26", word in post26[:3], f"{py}→{word} got={post26}")
    postT9 = [c.word for c in e2.candidates_for_t9(to_digits(py), 5)]
    check("自造词T9", word in postT9[:3], f"{py}→{word} got={postT9}")
print(f"    learned {learned} phrases, all recall OK (unless FAIL above)")

print()
print("===== 4. 调频学习(选过的词下次排名上升) =====")
freq_cases = [("gongsi", "公司"), ("shangban", "上班"), ("xiawu", "下午")]
for py, word in freq_cases:
    d = to_digits(py)
    before = [c.word for c in e2.candidates_for_t9(d, 10)]
    for _ in range(3):
        e2.learn_sequence(None, word)
    after = [c.word for c in e2.candidates_for_t9(d, 10)]
    bi = before.index(word) if word in before else 99
    ai = after.index(word) if word in after else 99
    check("调频", ai <= bi and ai <= 2, f"{py} {word} before#{bi+1} after#{ai+1}")
    print(f"    {py:10s} {word} 排名 {bi+1} → {ai+1}")

print()
print("===== 5. 边界/异常输入 =====")
edge = ["1", "0", "11111", "10101", "22222222222222222222", "9999999999",
        "2", "7", "979797979", "246824682468"]
for d in edge:
    try:
        cands = e2.candidates_for_t9(d, 10)
        # 1/0 不是 T9 字母键,candidatesT9 应优雅返回(空或兜底,但不崩)
        print(f"    d={d:24s} → {[c.word for c in cands[:4]]}")
    except Exception as ex:
        check("边界", False, f"d={d} 抛异常 {ex}")
try:
    e2.candidates("", 5)
    e2.candidates("'", 5)
    e2.candidates_for_t9("", 5)
    e2.candidates_for_t9_filtered("64426", "nihao", 5)  # 锁定==全部
    e2.candidates_for_t9_filtered("64426", "nihaoo", 5)  # 锁定超长(异常态)
except Exception as ex:
    check("边界", False, f"空输入/超长锁定抛异常 {ex}")
print("    边界输入无崩溃")

print()
print("=" * 60)
if FAILS:
    print(f"共 {len(FAILS)} 个失败:")
    for f in FAILS[:30]:
        print(" -", f)
else:
    print("全部通过")
