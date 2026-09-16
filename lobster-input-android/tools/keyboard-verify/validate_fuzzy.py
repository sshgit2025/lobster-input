# -*- coding: utf-8 -*-
"""2b 模糊音整句解码验证:打错平翘舌/前后鼻音 → 出正确句;打对 → 不被破坏;纠正拼音可标注。"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import to_digits
from engine_lm import load_engine_lm

e = load_engine_lm()
e.build_fuzzy_index()
print(f"模糊索引 {len(e.fuzzy_index)} 键")

# (期望句, 打错的拼音, 正确拼音) —— 平翘舌/前后鼻音打错
TYPO = [
    ("你吃饭了吗", "nicifanlema", "nichifanlema"),      # chi→ci
    ("我在吃饭", "wozaicifan", "wozaichifan"),          # chi→ci
    ("我是学生", "wosixuesheng", "woshixuesheng"),      # shi→si
    ("知道了", "zidaole", "zhidaole"),                  # zhi→zi
    ("上班很累", "sanbanhenlei", "shangbanhenlei"),     # shang→san (sh→s + ang→an 双)
    ("我们去逛街", "womenquguanjie", "womenquguangjie"),# guang→guan
]
# 打对的句子(不能被模糊破坏)
CORRECT = [
    ("你吃饭了吗", "nichifanlema"),
    ("次数", "cishu"),
    ("四是四", "sishisi"),
    ("我们一起去吃饭吧", "womenyiqiquchifanba"),
    ("知道", "zhidao"),
    ("自己", "ziji"),
]

fails = []
def ck(name, cond, det=""):
    print(f"{'PASS' if cond else 'FAIL'} {name} {det}")
    if not cond: fails.append(name)

print("\n=== 打错平翘舌/鼻音 → fuzzy_correction 独立纠错候选(带纠正拼音标注)===")
for zh, wrong, right in TYPO:
    d = to_digits(wrong)
    fc = e.fuzzy_correction(d)
    got = fc[0] if fc else None
    ck(f"打错'{wrong}' 纠错候选'{zh}'", got == zh, f"纠错={fc}")

print("\n=== 打对 → 不产生纠错候选(或纠错=原句)===")
for zh, right in CORRECT:
    d = to_digits(right)
    fc = e.fuzzy_correction(d)
    # 打对时:要么无纠错,要么纠错句==字面首选(不干扰)
    lit = e.candidates_for_t9(d, 1)
    lit_w = lit[0].word if lit else ""
    ok = (fc is None) or (fc[0] == lit_w)
    ck(f"打对'{right}' 不误纠", ok, f"纠错={fc} 字面={lit_w}")

print()
if fails: print(f"共 {len(fails)} 失败: {fails}")
else: print("模糊音整句解码验证全部通过")
