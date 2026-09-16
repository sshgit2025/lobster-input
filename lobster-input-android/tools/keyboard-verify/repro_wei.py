# 复现:九宫格 haoziweizhi(42949394944?) 锁定 hao/zi/wei/zhi 后依次选 耗、子,
# 剩余段候选里"尾"的排名/是否被截断。
from engine import to_digits
from engine_v2 import load_engine_v2

e = load_engine_v2()

def show(tag, cands, target):
    words = [c.word for c in cands]
    pos = words.index(target) + 1 if target in words else -1
    print(f"{tag}: n={len(words)} target={target} rank={pos}")
    print("  head:", words[:15])
    if pos < 0:
        print("  tail:", words[-15:])
    return pos

digits_full = to_digits("haoziweizhi")
print("digits:", digits_full)

# 用户路径1: 直接打全串,锁定 hao zi wei zhi(选择器逐段点选)
c1 = e.candidates_for_t9_filtered(digits_full, "haoziweizhi", 999)
show("锁定全串 haoziweizhi", c1, "耗子尾汁")

# 选"耗"(hao,3位)后剩 ziweizhi
rem1 = to_digits("ziweizhi")
c2 = e.candidates_for_t9_filtered(rem1, "", 999)
show(f"选耗后 rem=ziweizhi {rem1}", c2, "子")

# 选"子"(zi,2位)后剩 weizhi
rem2 = to_digits("weizhi")
c3 = e.candidates_for_t9_filtered(rem2, "", 999)
p_all = show(f"选子后 rem=weizhi {rem2} limit=999", c3, "尾")
c3d = e.candidates_for_t9(rem2, 60)
p_60 = show(f"选子后 rem=weizhi limit=60(线上)", c3d, "尾")

# 用户也可能锁定了 wei(选择器):
c4 = e.candidates_for_t9_filtered(rem2, "wei", 999)
show("选子后 锁定wei limit=999", c4, "尾")
c4b = e.candidates_for_t9_filtered(rem2, "wei", 40)
show("选子后 锁定wei limit=40", c4b, "尾")

# 词库本身
ws = [w for w, _ in e.dict.exact_words("wei")]
print("\nwei 行词数:", len(ws), " 尾 index:", ws.index("尾") if "尾" in ws else -1)
print("wei 行前20:", ws[:20])

# 26 键对照
c26 = e.candidates("wei", 999)
show("26键 wei limit=999", c26, "尾")
c26b = e.candidates("weizhi", 999)
show("26键 weizhi limit=999", c26b, "尾")
