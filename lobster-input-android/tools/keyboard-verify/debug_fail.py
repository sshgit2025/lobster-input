"""调试 shaow/woxiangch 在 T9 下的失败原因。"""
from engine_v2 import load_engine_v2
from engine import to_digits

e = load_engine_v2()

# 1. shaow: 74269 的展开里有没有 shaow?
d = to_digits("shaow")
exps = e.expand_full_pinyin(d)
print("shaow in exps:", "shaow" in exps, "total:", len(exps))
print("prefix_words(shaow):", e.dict.prefix_words("shaow", 10))

# 2. 逐一展开打分,看稍微的分数和排它的谁
n = len(d)
from engine import MATCH_W, LAYER_EXACT, LEVEL_W, PEN_MISS
rows = []
for exp in exps:
    for w, lv, klen in e.dict.prefix_words(exp, 30):
        sc = n * MATCH_W + LAYER_EXACT + lv * LEVEL_W + e.len_bonus(w) - (klen - n) * PEN_MISS
        rows.append((sc, w, exp, lv, klen))
rows.sort(reverse=True)
print("top10 补全:", [(w, exp, lv, klen, sc) for sc, w, exp, lv, klen in rows[:10]])

# 3. woxiangch: xiangchi 在词库吗
print()
print("xiangchi:", e.dict.exact_words("xiangchi")[:3])
print("woxiangchi prefix:", e.dict.prefix_words("woxiangch", 5))
d2 = to_digits("woxiangch")
exps2 = e.expand_full_pinyin(d2)
print("woxiangch in exps:", "woxiangch" in exps2, "total:", len(exps2))
# tail seg 24 的词
print("top_t9_words('24'):", e.top_t9_words("24"))
print("top_t9_words('9426424'):", e.top_t9_words("9426424"))
