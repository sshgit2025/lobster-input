# 复现:hua na me duo qian(花那么多钱)被切成 huan a me duo qian
from engine_v2 import load_engine_v2
from engine import to_digits

e = load_engine_v2()

phrase = "huanameduoqian"
digits = to_digits(phrase)
print("digits:", digits)

print("\n--- 整句 sentence_t9 ---")
print(e.sentence_t9(digits))

print("\n--- 候选 top15 ---")
for c in e.candidates_for_t9(digits)[:15]:
    print(f"  {c.word}  ml={c.matched_len} py={c.pinyin} score={c.score}")

print("\n--- 显示拼音 ---")
print(e.t9_display_pinyin(digits))

print("\n--- 切分 best_t9_seg_partial ---")
print(e.best_t9_seg_partial(digits))

print("\n--- 选择器选项(前导) ---")
print(e.t9_leading_options(digits, max_seg=6, limit=12) if hasattr(e, "t9_leading_options") else "N/A")

# 用户实际操作路径:逐个点选拼音 hua na me duo qian
print("\n--- 锁定 hua 后 ---")
print("display:", e.t9_display_filtered(digits, "hua") if hasattr(e, "t9_display_filtered") else "N/A")
for c in e.candidates_for_t9_filtered(digits, "hua")[:8]:
    print(f"  {c.word}  ml={c.matched_len} py={c.pinyin}")

print("\n--- 锁定 huana 后 ---")
for c in e.candidates_for_t9_filtered(digits, "huana")[:8]:
    print(f"  {c.word}  ml={c.matched_len} py={c.pinyin}")

# 词典检查
print("\n--- 词典关键词 ---")
for k in ["hua", "huan", "na", "me", "duo", "qian", "name", "nameduo", "huaname"]:
    ws = e.dict.exact_words(k)[:3]
    print(f"  {k}: {ws}")
