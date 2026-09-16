"""切分歧义修复验证电池:
A. huanameduoqian 核心场景(整句/显示/锁定过滤/边界裁决)
B. 字对齐切分(西安 xian、天鹅 tiane、皮袄 piao 类经典歧义)
C. 锁定一致性(锁 hua 排除 huan* 词;锁 huan 排除 hua|na* 词)
D. 性能
"""
import time

from engine_v2 import load_engine_v2
from engine import to_digits

e = load_engine_v2()
FAILS = []


def check(tag, cond, detail=""):
    mark = "OK " if cond else "FAIL"
    if not cond:
        FAILS.append(f"{tag} {detail}")
    print(f"{mark} {tag} {detail}")


print("===== A. 核心场景 huanameduoqian =====")
digits = to_digits("huanameduoqian")

# sentence_t9 现返回 top-2 路径列表(2026-07 选择记忆升级);首条=最优,断言不变。
# 2026-07 整句语言模型(词bigram)上线后,首选由"话那么多钱"→"花那么多钱"(花钱=spend money
# 更通顺,LM 正向改进);基线V3(无LM)仍为"话那么多钱"。两者均为合法切分,断言同时接受。
_HUA = ("话那么多钱", "花那么多钱")
st = (e.sentence_t9(digits) or [None])[0]
check("A1 整句", st is not None and st[0] in _HUA, f"got={st}")
check("A2 整句拼音回溯", st is not None and st[2] == "huanameduoqian", f"py={st[2] if st else None}")

disp = e.t9_display_pinyin(digits)
check("A3 显示切分", disp == "hua'na'me'duo'qian", f"disp={disp}(旧BUG: hua'na'ne'duo'qian 幻觉音节)")

# 锁 hua 后:huan* 词(换/缓/还)必须消失,hua* 词保留
w_hua = [c.word for c in e.candidates_for_t9_filtered(digits, "hua", 20, locked_sylls=["hua"])]
check("A4 锁hua排除huan词", "换" not in w_hua and "还" not in w_hua, f"got={w_hua[:10]}")
check("A5 锁hua保留整句", any(h in w_hua[:3] for h in _HUA), f"got={w_hua[:5]}")
check("A6 锁hua单字通道", any(x in w_hua for x in ("花", "话", "华")), f"got={w_hua[:10]}")

# 锁 hua|na 后
w_hn = [c.word for c in e.candidates_for_t9_filtered(digits, "huana", 20, locked_sylls=["hua", "na"])]
check("A7 锁hua+na整句", any(h in w_hn[:3] for h in _HUA), f"got={w_hn[:5]}")
check("A8 锁hua+na排除华南", "华南" not in w_hn, f"got={w_hn[:10]}")  # 华南=huanan,na 后是 n 不对齐 me

# 反向:锁 huan 后 hua* 应消失、huan* 保留
w_huan = [c.word for c in e.candidates_for_t9_filtered(digits, "huan", 20, locked_sylls=["huan"])]
check("A9 锁huan保留换", any(x in w_huan for x in ("换", "还", "环", "欢")), f"got={w_huan[:10]}")
check("A10 锁huan排除华纳", "华纳" not in w_huan, f"got={w_huan[:10]}")

print()
print("===== B. 字对齐切分经典歧义 =====")
align_cases = [
    ("华纳", "huana", ["hua", "na"]),
    ("西安", "xian", ["xi", "an"]),
    ("天鹅", "tiane", ["tian", "e"]),
    ("平安", "pingan", ["ping", "an"]),
    ("你好", "nihao", ["ni", "hao"]),
    ("哪儿", "naer", ["na", "er"]),
]
for w, key, want in align_cases:
    got = e.align_word_pinyin(w, key)
    check("B 对齐", got == want, f"{w}+{key} → {got} want={want}")

d_xian = to_digits("xian")
cands = {c.word: c.pinyin for c in e.candidates_for_t9(d_xian, 30)}
if "西安" in cands:
    check("B 西安显示", e.display_split("西安", "xian") == "xi'an", f"got={e.display_split('西安', 'xian')}")
check("B 先显示", e.display_split("先", "xian") == "xian", f"got={e.display_split('先', 'xian')}")

print()
print("===== C. 锁定一致性(泛化场景) =====")
# 场景1: wanshan 锁 wan → 完善保留(wan|shan 对齐),万山也保留
d_ws = to_digits("wanshan")
w = [c.word for c in e.candidates_for_t9_filtered(d_ws, "wan", 20, locked_sylls=["wan"])]
check("C1 锁wan完善在前", "完善" in w[:5], f"got={w[:6]}")
# 场景2: nihao 锁 ni → 你好保留
w = [c.word for c in e.candidates_for_t9_filtered("64426", "ni", 20, locked_sylls=["ni"])]
check("C2 锁ni你好在前", "你好" in w[:3], f"got={w[:5]}")
# 场景3: 锁定态残段补全(旧A2电池):shaow 锁 shao → 稍微
w = [c.word for c in e.candidates_for_t9_filtered("74269", "shao", 10, locked_sylls=["shao"])]
check("C3 锁shao残段补全稍微", "稍微" in w[:5], f"got={w[:6]}")
w = [c.word for c in e.candidates_for_t9_filtered("9686349", "you", 10, locked_sylls=["you"])]
check("C4 锁you残段补全有没有", "有没有" in w[:5], f"got={w[:6]}")
# 场景4: 全锁定(锁定长度==输入长度)
w = [c.word for c in e.candidates_for_t9_filtered("64426", "nihao", 10, locked_sylls=["ni", "hao"])]
check("C5 全锁定你好", "你好" in w[:3], f"got={w[:5]}")
# 场景5: 锁定超长异常态不崩
w = e.candidates_for_t9_filtered("64426", "nihaoo", 5, locked_sylls=["ni", "hao", "o"])
check("C6 异常锁定不崩", True, f"got={[c.word for c in w[:3]]}")
# 场景6: 显示拼音跟随锁定
disp = e.t9_display_filtered(digits, "hua", locked_sylls=["hua"])
check("C7 锁hua显示", disp.startswith("hua'"), f"disp={disp}")

print()
print("===== C2. 选择器高亮对齐(#1候选读音的下一音节) =====")
# 48262(huana):#1候选 华纳@huana,高亮应为 hua(旧逻辑贪心取 huan)
c0 = e.candidates_for_t9("48262", 1)[0]
al = e.align_word_pinyin(c0.word, c0.pinyin) if c0.pinyin else None
check("C8 huana高亮hua", al is not None and al[0] == "hua", f"top={c0.word}@{c0.pinyin} aligned={al}")
# 整串:#1=话那么多钱@huanameduoqian,锁 hua 后下一高亮=na
c1 = e.candidates_for_t9_filtered(digits, "hua", 1, locked_sylls=["hua"])[0]
al1 = e.align_word_pinyin(c1.word, c1.pinyin) if c1.pinyin else None
check("C9 锁hua后高亮na", al1 is not None and len(al1) >= 2 and al1[1] == "na", f"top={c1.word}@{c1.pinyin} aligned={al1}")

print()
print("===== D. 性能 =====")
for d in [digits, to_digits("woxiangchihuoguo"), "5464664264942646426"]:
    e.t9_cache.clear()
    t0 = time.perf_counter()
    e.candidates_for_t9(d)
    cold = (time.perf_counter() - t0) * 1000
    t0 = time.perf_counter()
    for _ in range(20):
        e.candidates_for_t9_filtered(d, "hua", locked_sylls=["hua"])
    avg = (time.perf_counter() - t0) / 20 * 1000
    check("D 性能", avg < 80, f"d={d} cold={cold:.1f}ms lockedAvg={avg:.2f}ms(阈80ms,py参照)")

print()
if FAILS:
    print(f"共 {len(FAILS)} 项失败:")
    for f in FAILS:
        print("  " + f)
    raise SystemExit(1)
print("=" * 60)
print("切分修复电池全部通过")
