"""用户选择记忆电池(2026-07 修「选过 什么鬼 下次默认还是 什么会」)。

对齐业界:RIME enable_user_dict 动态调频 + encode_commit_history(上屏历史自动编码
进用户词典)/ 搜狗智能调频。三条规则:
  R1 单次点选覆盖整串输入的候选(含整句拼出的非词库词)= 上屏历史,必须 learnPhrase;
  R2 T9 全消耗且用户选过(调频>0)的词库词,层级提到整句之上;
  R3 26 键自造词吃下整串输入时压过整句(镜像 T9)。
控制器行为模拟:selectCandidate 单次全消耗 = learn_sequence + learn_phrase(新行为)。
"""
from engine_v2 import load_engine_v2
from engine import to_digits

e = load_engine_v2()
fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}")
    if not ok:
        fails.append(name)


def pick_full(pinyin, word):
    """模拟控制器:单次点选覆盖整串的候选。"""
    e.learn_sequence(None, word)
    e.learn_phrase(pinyin, word)


# ===== A. 用户实景:shenmegui(743663484) =====
D = to_digits("shenmegui")
before = [c.word for c in e.candidates_for_t9(D, 8)]
disp_before = e.t9_display_pinyin(D)
# 2026-07 custom_dict v2:「什么鬼」成为内置词(全消耗+同码无主词库精确词 → LAYER_SENTENCE),
# fresh 默认即为 什么鬼——当年"选过什么鬼默认还是什么会"的问题被词库正向解决。
# A0 断言从"复现原始问题"改为"新基线:内置热词直接置顶"。
check("A0 新基线:什么鬼内置置顶", before[0] == "什么鬼", f"top={before[:3]} disp={disp_before}")

pick_full("shenmegui", "什么鬼")  # 用户锁 gui 选了 什么鬼 并上屏

after = [c.word for c in e.candidates_for_t9(D, 8)]
disp_after = e.t9_display_pinyin(D)
check("A1 选后同串默认=什么鬼", after[0] == "什么鬼", f"top={after[:3]}")
check("A2 显示拼音跟随=shen'me'gui", disp_after == "shen'me'gui", f"disp={disp_after}")
# 再次输入(缓存路径)仍稳定
again = [c.word for c in e.candidates_for_t9(D, 8)]
check("A3 重复输入仍置顶", again[0] == "什么鬼")
# 2026-07 custom_dict v2:整句 top-2 变体名额被 什么鬼/什么贵 占据,「什么会」的可达
# 通道改为拼音选择器锁定 hui(与真实用户"要打某个读音"的操作一致)。
locked_hui = [c.word for c in e.candidates_for_t9_filtered(D, "shenmehui", locked_sylls=["shen", "me", "hui"])]
check("A4 什么会经锁定hui通道可达", "什么会" in locked_hui[:3], f"{locked_hui[:5]}")

# ===== B. 词库词形态:全消耗词被整句压住 → 选过即置顶 =====
# 找一个真实案例:存在整句置顶 且 有同码全消耗词库词不在第1位
case = None
for py in ["yiqilai", "zenmele", "weishenme", "shenghuo", "xianzai", "mingtian"]:
    d = to_digits(py)
    cands = e.candidates_for_t9(d, 30)
    exact_words = [w for w, lv, key in e.exact_by_digits(d)]
    lose = [w for w in exact_words if w in [c.word for c in cands] and w != cands[0].word]
    if lose:
        case = (py, d, lose[0], cands[0].word)
        break
check("B0 找到词库词被压案例", case is not None, f"{case}")
if case:
    py, d, w, old_top = case
    e.learn_sequence(None, w)  # 选词调频(词库词 learnPhrase 会跳过,靠 R2 层级提升)
    top = e.candidates_for_t9(d, 5)[0].word
    check(f"B1 选过的词库词 {w} 置顶(原top={old_top})", top == w, f"got={top}")

# ===== C. 26 键:无同码歧义,shenmegui 整句本就正确;学过的自造词必须仍压过整句 =====
e2 = load_engine_v2()  # 干净引擎
before26 = [c.word for c in e2.candidates("shenmegui", 8)]
check("C0 26键整句本就正确(无歧义)", before26[0] == "什么鬼", f"top={before26[:3]}")
e2.learn_sequence(None, "什么鬼")
e2.learn_phrase("shenmegui", "什么鬼")
after26 = [c.word for c in e2.candidates("shenmegui", 8)]
check("C1 26键选后仍置顶", after26[0] == "什么鬼", f"top={after26[:3]}")
# 26 键自造词压整句(R3):非词库组合 学过必出在整句之上
e2.learn_phrase("haozieweizhi", "耗子尾汁")
top26 = e2.candidates("haozieweizhi", 5)
check("C2 26键自造词压过整句", top26 and top26[0].word == "耗子尾汁", f"top={[c.word for c in top26[:3]]}")

# ===== D. 反复竞争:后来更常选的赢(A 已学 什么鬼 cnt=1) =====
e.learn_phrase("shenmegui", "什么会")
e.learn_phrase("shenmegui", "什么会")  # 用户后来连选两次 什么会(cnt=2)
e.learn_sequence(None, "什么会")
top = e.candidates_for_t9(D, 5)[0].word
check("D1 更高频选择胜出", top == "什么会", f"got={top}")

# ===== E. 关键不回归抽查(全量见各自电池) =====
e4 = load_engine_v2()
for pyin, want in [("nihao", "你好"), ("ceshi", "测试"), ("weizhi", "位置")]:
    got = e4.candidates_for_t9(to_digits(pyin), 5)[0].word
    check(f"E1 {pyin} 首选={want}", got == want, f"got={got}")
# 9267426 同码歧义(完善/要钱):历史行为=完善第1(98f18db),要钱必须同列前3(EXACT_FULL_BONUS)
tops = [c.word for c in e4.candidates_for_t9(to_digits("yaoqian"), 5)]
check("E1b 完善第1且要钱前3", tops[0] == "完善" and "要钱" in tops[:3], f"got={tops[:3]}")
# 整句核心交互:堪称完美 连打直接出
kcwm = [c.word for c in e4.candidates_for_t9(to_digits("kanchengwanmei"), 5)]
check("E2 整句 堪称完美 仍首选", kcwm[0] == "堪称完美", f"top={kcwm[:3]}")
# 学习后单字全量可达不破坏(锁定 yi 咦仍可达)
e.learn_sequence(None, "一")  # 高频单字调频后
ws = [c.word for c in e.candidates_for_t9_filtered("94", "yi", locked_sylls=["yi"])]
check("E3 调频后锁定yi咦仍可达", "咦" in ws and ws[0] == "一", f"top={ws[:3]}")

print()
print("=" * 60)
print("全部通过" if not fails else f"失败 {len(fails)} 项: {fails}")
raise SystemExit(0 if not fails else 1)
