# 完整链路:haoziweizhi 逐字选 耗子尾汁 → 自造词学习 → 二次输入直接出整词。
# 同时扫多组"目标单字在同音词海里"的场景,确认逐字组词通道普遍可达。
from engine import to_digits
from engine_v2 import load_engine_v2

e = load_engine_v2()

def rank(cands, w):
    ws = [c.word for c in cands]
    return ws.index(w) + 1 if w in ws else -1

# ---- 链路:逐字组词 ----
session_py, session_words = "", ""
digits = to_digits("haoziweizhi")
picks = [("耗", "hao"), ("子", "zi"), ("尾", "wei"), ("汁", "zhi")]
ok = True
for word, py in picks:
    cands = e.candidates_for_t9(digits)
    r = rank(cands, word)
    print(f"剩余 {digits:12s} 选[{word}] rank={r} (n={len(cands)})")
    if r < 0:
        ok = False
        break
    session_py += py; session_words += word
    digits = digits[len(py):]
    e.t9_cache.clear()
print("逐字组词链路:", "通过" if ok and not digits else "失败")

# 学词
e.learn_phrase(session_py, session_words)
c2 = e.candidates_for_t9(to_digits("haoziweizhi"), 10)
print("二次输入 haoziweizhi top5:", [c.word for c in c2[:5]], " 耗子尾汁 rank:", rank(c2, "耗子尾汁"))

# ---- 扫描:常用 500 单字在"该字拼音+高频尾缀"组合下的可达性 ----
print("\n---- 单字可达性扫描(同音字海场景) ----")
cases = [
    ("尾", "wei"), ("汁", "zhi"), ("耗", "hao"), ("咩", "mie"), ("囧", "jiong"),
    ("犇", "ben"), ("鑫", "xin"), ("垚", "yao"), ("烎", "yin"), ("靐", "bing"),
    ("撩", "liao"), ("怼", "dui"), ("尬", "ga"), ("怂", "song"), ("萌", "meng"),
]
bad = []
for ch, py in cases:
    d = to_digits(py)
    cands = e.candidates_for_t9(d)
    r = rank(cands, ch)
    mark = "OK " if 0 < r <= 100 else "MISS"
    if r < 0 or r > 100:
        bad.append((ch, py, r))
    print(f"{mark} {py:8s}{d:8s} [{ch}] rank={r}/{len(cands)}")
print("\n不可达:", bad if bad else "无")
