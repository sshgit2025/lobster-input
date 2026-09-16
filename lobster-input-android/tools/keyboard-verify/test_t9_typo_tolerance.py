"""九宫格错键容忍电池(2026-07 修「连敲错几个键后候选/拼音永久冻结」)。

方案:整句 DP 增加「跳过该位(误触)」转移(GAP_PEN=600 重罚,对齐 Gboard 插入
错误容忍解码);matchedLen 含跳过位(选词一次吃净误触);锁定前缀区禁止跳过。

覆盖:实景中部垃圾/头部垃圾/尾部垃圾/不可成拼段/两步恢复流/锁定态/
随机乱序花式 fuzz(正误混合、长句、纯垃圾)/性能/旧行为关键抽查。
"""
import random
import time
from engine_v2 import load_engine_v2
from engine import to_digits

e = load_engine_v2()
fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}")
    if not ok:
        fails.append(name)


WORDS = ["nihao", "shenme", "shihou", "shijian", "weizhi", "ceshi", "mingtian", "haode"]
GARBAGE = ["77", "779", "7777", "99", "222", "7979"]


def cands(d, limit=8):
    return e.candidates_for_t9(d, limit)


# ===== A. 实景:shenme + 垃圾 + shihou,候选不得永久冻结 =====
for g in ["779", "7777"]:
    seq = to_digits("shenme") + g + to_digits("shihou")
    prev, max_frozen, frozen = None, 0, 0
    for i in range(4, len(seq) + 1):
        ws = [c.word for c in cands(seq[:i])]
        frozen = frozen + 1 if ws == prev else 0
        max_frozen = max(max_frozen, frozen)
        prev = ws
    # 垃圾段内候选可短暂不变(无新信息),但恢复合法输入后必须变化:
    # 连续冻结步数必须 < 垃圾长度+1(旧 BUG 是从垃圾开始一路冻结到底)
    check(f"A1 中部垃圾{g}不永久冻结", max_frozen <= len(g), f"max连续冻结={max_frozen}")
    full = [c for c in cands(seq) if c.matched_len == len(seq)]
    check(f"A2 中部垃圾{g}存在全消耗候选", bool(full), f"{[(c.word, c.matched_len) for c in cands(seq)[:3]]}")

# 两步恢复流:选「什么」(消耗6位)后,剩余串(垃圾开头)必须能出全消耗候选
rest = "779" + to_digits("shihou")
rc = cands(rest)
check("A3 两步恢复:剩余串出全消耗「时候」", any(c.word == "时候" and c.matched_len == len(rest) for c in rc),
      f"{[(c.word, c.matched_len) for c in rc[:3]]}")

# ===== B. 头部垃圾 + 单词:词可达且吃净垃圾 =====
for g in GARBAGE[:3]:
    for w_py, w in [("nihao", "你好"), ("shijian", "时间")]:
        d = g + to_digits(w_py)
        got = cands(d)
        hit = any(c.word == w and c.matched_len == len(d) for c in got)
        check(f"B1 头垃圾{g}+{w_py}可达{w}且全消耗", hit, f"{[(c.word, c.matched_len) for c in got[:3]]}")

# ===== C. 尾部垃圾:词仍可达,存在吃净尾垃圾的候选 =====
for g in ["7777", "99"]:
    d = to_digits("nihao") + g
    got = cands(d)
    check(f"C1 尾垃圾{g}你好全消耗可达", any(c.word == "你好" and c.matched_len == len(d) for c in got),
          f"{[(c.word, c.matched_len) for c in got[:4]]}")

# ===== D. 锁定态:垃圾在锁定区之后,不崩溃且候选非空;锁定音节单字仍可达 =====
d = to_digits("shenme") + "7777"
got = e.candidates_for_t9_filtered(d, "shen", locked_sylls=["shen"])
check("D1 锁定+尾垃圾候选非空", bool(got), f"n={len(got)}")
check("D2 锁定单字通道完好", any(c.word == "深" for c in got))

# ===== E. 随机 fuzz:乱序/花式/正误混合/长句 =====
random.seed(20260708)
t_max = 0.0
fuzz_fail = None
for trial in range(60):
    parts = []
    for _ in range(random.randint(2, 5)):
        parts.append(to_digits(random.choice(WORDS)) if random.random() < 0.6
                     else "".join(random.choice("23456789") for _ in range(random.randint(1, 4))))
    seq = "".join(parts)[:20]
    prev = None
    for i in range(1, len(seq) + 1):
        d = seq[:i]
        t0 = time.time()
        try:
            got = cands(d)
        except Exception as ex:  # noqa
            fuzz_fail = f"{d} 异常 {ex}"
            break
        t_max = max(t_max, time.time() - t0)
        if not got:
            fuzz_fail = f"{d} 候选为空"
            break
        if got[0].matched_len > len(d):
            fuzz_fail = f"{d} matchedLen 越界"
            break
        if [c.word for c in cands(d)] != [c.word for c in got]:
            fuzz_fail = f"{d} 不确定性"
            break
    if fuzz_fail:
        break
check("E1 随机fuzz 60条(候选非空/无异常/matchedLen合法/确定性)", fuzz_fail is None, fuzz_fail or "")
check("E2 fuzz单步性能", t_max < 0.08, f"max={t_max*1000:.1f}ms(py参照)")

# 纯垃圾长串
for d in ["7" * 16, "79" * 8, "2" * 12]:
    got = cands(d)
    check(f"E3 纯垃圾{d[:6]}..非空无崩溃", bool(got), f"top={[c.word for c in got[:2]]}")

# ===== F. 旧行为关键抽查(不回归;全量见旧电池) =====
e2 = load_engine_v2()
for pyin, want in [("nihao", "你好"), ("ceshi", "测试"), ("weizhi", "位置")]:
    got = e2.candidates_for_t9(to_digits(pyin), 3)[0].word
    check(f"F1 {pyin} 首选={want}", got == want, f"got={got}")
tops = [c.word for c in e2.candidates_for_t9(to_digits("yaoqian"), 5)]
check("F2 完善第1且要钱前3", tops[0] == "完善" and "要钱" in tops[:3], f"{tops[:3]}")
kc = e2.candidates_for_t9(to_digits("kanchengwanmei"), 3)[0].word
check("F3 整句堪称完美", kc == "堪称完美", f"got={kc}")
# 残拼(真实未打完的尾巴)绝不能被当垃圾跳过:youmeiy→有没有、shaow→稍微
ym = [c.word for c in e2.candidates_for_t9(to_digits("youmeiy"), 5)]
check("F4 残拼youmeiy补全有没有(非跳过)", "有没有" in ym[:3], f"{ym[:3]}")
# shaow 与 山西/千万 同码同结构,历史基准(test_v2)容许排名≤20;锁 shao 精确通道另测
sw = [c.word for c in e2.candidates_for_t9(to_digits("shaow"), 20)]
check("F5 残拼shaow补全稍微(非跳过,历史基准rank≤20)", "稍微" in sw, f"rank={sw.index('稍微')+1 if '稍微' in sw else '-'}")

print()
print("=" * 60)
print("全部通过" if not fails else f"失败 {len(fails)} 项: {fails}")
raise SystemExit(0 if not fails else 1)
