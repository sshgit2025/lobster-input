"""基线测试:验证当前 HEAD 实现在 T9 下的不完整拼音问题(问题1)。"""
from engine import load_engine, to_digits

e = load_engine()

cases = [
    # (拼音输入, 期望词, 说明)
    ("youmeiy", "有没有", "尾字母是下一字声母"),
    ("youmeiyou", "有没有", "完整拼音"),
    ("shaow", "稍微", "旧修复案例"),
    ("nihaom", "你好吗", "你好吗前缀"),
    ("woxiangch", "我想吃", "我想吃前缀"),
    ("zenmeb", "怎么办", "怎么办前缀"),
    ("shenmesh", "什么时候", "什么时候简拼混合"),
    ("weishenm", "为什么", "为什么前缀"),
    ("duibuq", "对不起", "对不起前缀"),
    ("meiguanx", "没关系", "没关系前缀"),
]

print("===== 26 键 candidates() =====")
for py, want, desc in cases:
    cands = e.candidates(py, 10)
    words = [c.word for c in cands]
    hit = want in words[:5]
    print(f"{'OK ' if hit else 'FAIL'} 26键 {py:14s} want={want:6s} got={words[:6]}")

print()
print("===== 九宫格 candidatesForT9() =====")
for py, want, desc in cases:
    digits = to_digits(py)
    cands = e.candidates_for_t9(digits, 10)
    words = [c.word for c in cands]
    hit = want in words[:5]
    print(f"{'OK ' if hit else 'FAIL'} T9 {py:14s} d={digits:12s} want={want:6s} got={words[:6]}")

print()
print("===== 九宫格 显示拼音 =====")
for py in ["youmeiy", "youmeiyou", "shaow"]:
    digits = to_digits(py)
    print(f"{py:12s} d={digits:12s} display={e.t9_display_pinyin(digits)}")
