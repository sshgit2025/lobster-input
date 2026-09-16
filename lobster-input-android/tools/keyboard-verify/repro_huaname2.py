# 逐键模拟 hua|na|me|duo|qian 的中间态:显示拼音 + top5 候选 + 选择器行为
from engine_v2 import load_engine_v2
from engine import to_digits, T9

e = load_engine_v2()

phrase = "huanameduoqian"
digits = to_digits(phrase)

print("== 逐键中间态 ==")
for i in range(2, len(digits) + 1):
    d = digits[:i]
    disp = e.t9_display_pinyin(d)
    cands = e.candidates_for_t9(d)[:5]
    words = " ".join(f"{c.word}@{c.pinyin or '-'}" for c in cands)
    seg, cov = e.best_t9_seg_partial(d)
    print(f"{d:<16} disp={disp:<22} seg={'|'.join(seg)}({cov}/{i})  top5: {words}")

print("\n== 锁定态链路(用户逐音节点选) ==")
locked = ""
for syl in ["hua", "na", "me", "duo", "qian"]:
    locked += syl
    cands = e.candidates_for_t9_filtered(digits, locked)[:8]
    words = " ".join(f"{c.word}@{c.pinyin or '-'}#ml{c.matched_len}" for c in cands)
    print(f"locked={locked:<16} {words}")

print("\n== splitSyllables 贪心 vs 期望 ==")
for py in ["huanameduoqian", "huaname", "huana"]:
    # 贪心最长
    parts, i = [], 0
    while i < len(py):
        m = 0
        for L in range(min(e.dict.max_syllable_len, len(py) - i), 0, -1):
            if e.dict.is_syllable(py[i:i+L]):
                m = L; break
        if m == 0:
            parts.append(py[i:]); break
        parts.append(py[i:i+m]); i += m
    print(f"{py:<16} greedy={'|'.join(parts)}")
