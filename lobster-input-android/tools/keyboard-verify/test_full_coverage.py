"""单字全量可达性测试(2026-07 修「yi 打不出咦」)。

根因:build_dict.py 曾按 top-30/key 截断词库,yi 音节 137 个单字里第 31+ 位
(咦/呓/翊…)整库丢失;运行时 CAND_LIMIT=100 也会把大音节尾部单字再次截掉。

本电池保证:
A. 用户实景:九宫格打 yi(94)→ 点拼音选择器锁定 yi → 候选必含「咦」。
B. 全音节扫描:词库中每个合法音节的每个单字,锁定该音节后必须出现在候选中
   (=任何汉字都打得出,业界底线)。
C. 26 键全拼同样全量可达。
D. 排序不回归:高频常用输入的首选仍正确(抽查,主电池 test_v2 兜全量)。
E. 性能:锁定大音节(137 字)候选生成仍在阈值内。
"""
import time
from engine_v2 import load_engine_v2, CAND_LIMIT
from engine import to_digits

e = load_engine_v2()
fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}")
    if not ok:
        fails.append(name)


# ===== A. 用户实景:九宫格 yi → 锁定 yi → 咦 =====
digits = to_digits("yi")  # 94
cands = e.candidates_for_t9_filtered(digits, "yi", locked_sylls=["yi"])
words = [c.word for c in cands]
check("A1 锁定yi后候选含咦", "咦" in words, f"rank={words.index('咦')+1 if '咦' in words else '-'} 总数={len(words)}")
check("A2 锁定yi首选仍是一", words[0] == "一", f"top={words[:5]}")

# 同类受害大音节抽查(ji/yu/xi 等,锁定后尾部生僻字可达)
for syl, rare in [("ji", "叽"), ("yu", "喻"), ("xi", "熙"), ("yi", "咦")]:
    ws = [c.word for c in e.candidates_for_t9_filtered(to_digits(syl), syl, locked_sylls=[syl])]
    check(f"A3 锁定{syl}可达{rare}", rare in ws)

# ===== B. 全音节扫描:锁定音节后该音节全部单字可达 =====
t0 = time.time()
total_chars = 0
missing = []
for syl in sorted(e.dict.syllables):
    line = e.dict.full.exact(syl)
    singles = [w for w, _ in line if len(w) == 1]
    if not singles:
        continue
    ws = set(c.word for c in e.candidates_for_t9_filtered(to_digits(syl), syl, locked_sylls=[syl]))
    total_chars += len(singles)
    for ch in singles:
        if ch not in ws:
            missing.append((syl, ch))
check("B1 全音节单字锁定可达", not missing,
      f"音节数={len(e.dict.syllables)} 单字总数={total_chars} 缺失={len(missing)} {missing[:10]}")
print(f"     扫描耗时 {time.time()-t0:.1f}s")

# ===== A4. 无锁定态整串精确候选保底(94 不锁定也能找到 咦/檄 等同码字) =====
ws94 = [c.word for c in e.candidates_for_t9("94")]
check("A4 无锁定94可达咦", "咦" in ws94, f"总数={len(ws94)}")
check("A5 候选列表规模有界", len(ws94) <= CAND_LIMIT + 400, f"len={len(ws94)}")

# ===== C. 26 键全拼全量可达(输入完整音节,单字必在候选中) =====
missing26 = []
for syl in sorted(e.dict.syllables):
    singles = [w for w, _ in e.dict.full.exact(syl) if len(w) == 1]
    if not singles:
        continue
    ws = set(c.word for c in e.candidates(syl, CAND_LIMIT))
    for ch in singles:
        if ch not in ws:
            missing26.append((syl, ch))
check("C1 26键全拼单字全量可达", not missing26, f"缺失={len(missing26)} {missing26[:10]}")

# ===== D. 排序不回归(高频抽查;详见 test_v2 全电池) =====
for inp, want in [("yi", "一"), ("de", "的"), ("shi", "是"), ("hao", "好"), ("ni", "你")]:
    top = e.candidates(inp, 5)[0].word
    check(f"D1 26键 {inp} 首选={want}", top == want, f"got={top}")
for pyin, want in [("nihao", "你好"), ("ceshi", "测试"), ("weizhi", "位置")]:
    top = e.candidates_for_t9(to_digits(pyin), 5)[0].word
    check(f"D2 T9 {pyin} 首选={want}", top == want, f"got={top}")
# 曾修过的「weizhi 打不出 尾」:放宽池后 尾 仍可达
ws = [c.word for c in e.candidates_for_t9(to_digits("weizhi"), CAND_LIMIT)]
check("D3 T9 weizhi 单字'尾'仍可达", "尾" in ws)

# ===== E. 性能:锁定大音节候选生成 =====
e.candidates_for_t9_filtered("94", "yi", locked_sylls=["yi"])  # 热身
t0 = time.time()
N = 50
for _ in range(N):
    e.t9_cache.clear()  # 绕过缓存,测真实计算
    e.candidates_for_t9_filtered("94", "yi", locked_sylls=["yi"])
avg = (time.time() - t0) / N * 1000
check("E1 锁定yi性能", avg < 80, f"avg={avg:.1f}ms(py参照,Kotlin/Swift 快约10x)")

print()
print("=" * 60)
print("全部通过" if not fails else f"失败 {len(fails)} 项: {fails}")
raise SystemExit(0 if not fails else 1)
