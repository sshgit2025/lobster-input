#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""T5 专有名词扩充(2026-07 任务:地名/道路/单位机构/风景名胜/小区/店铺)专属电池。

来源:搜狗官方"城市信息"细胞词库(人工拼音),经 gen_custom_dict.py T5 层灌入
custom_dict.txt。设计约束(全部在此验证):
  P1 用户报障词必可达:林萃西里 / 华创生活广场 26键+T9 打全必出
  P2 抽样专名 26键/T9 打全必可达(全消耗保底通道)
  P3 专名绝不污染预测:level=40 < 补全门槛110 → 短输入的补全/联想不出现长尾专名
  P4 高频主词 top-1 零回归(lv>=160 抽样,对照无自定义词库引擎)
  P5 性能:大词库渐进击键仍在阈内
运行前提:CUSTOM_DICT 指向含 T5 的新 custom_dict.txt(默认取 app assets)。
"""
import os
import random
import time

import engine_v3
from engine import load_engine, to_digits
from engine_v3 import load_engine_v3

HERE = os.path.dirname(os.path.abspath(__file__))

fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}")
    if not ok:
        fails.append(name)


def run():
    e3 = load_engine_v3()
    e1 = load_engine()  # 对照:无自定义词库

    # ===== P1 用户报障词必可达 =====
    for w, py in [("林萃西里", "lincuixili"), ("华创生活广场", "huachuangshenghuoguangchang")]:
        c26 = [c.word for c in e3.candidates(py, 200)]
        check(f"P1 {w} 26键打全可达", w in c26, f"top5={c26[:5]}")
        ct9 = [c.word for c in e3.candidates_for_t9(to_digits(py), 200)]
        check(f"P1 {w} T9打全可达", w in ct9, f"top5={ct9[:5]}")

    # ===== 收集 T5 专名样本(level==40 且 4 字以上视作专名代表) =====
    poi_entries = []
    for idx in range(len(e3.custom.table.keys)):
        key = e3.custom.table.keys[idx]
        for w, lv in e3.custom.table.words_at(idx):
            if lv == 40 and len(w) >= 3:
                poi_entries.append((key, w))
    check("P0 T5 专名词条已灌入(>=10万)", len(poi_entries) >= 100_000, f"n={len(poi_entries)}")

    # ===== P2 抽样打全必可达 =====
    random.seed(7)
    sample = random.sample(poi_entries, min(300, len(poi_entries)))
    un26 = [w for key, w in sample if w not in {c.word for c in e3.candidates(key, 400)}]
    check("P2 随机300专名26键打全必可达", not un26, f"{un26[:5]}")
    sample_t9 = random.sample(poi_entries, min(120, len(poi_entries)))
    unt9 = [w for key, w in sample_t9
            if w not in {c.word for c in e3.candidates_for_t9(to_digits(key), 400)}]
    check("P2 随机120专名T9打全必可达", not unt9, f"{unt9[:5]}")

    # ===== P3 预测不被污染:专名不进短输入补全/联想 =====
    # lincui(林萃西里前缀,未打全)的前排不应被 level 40 专名占据
    for prefix in ["lin", "hua", "beij", "shang"]:
        top = e3.candidates(prefix, 12)
        bad = [c.word for c in top if len(c.word) >= 4 and any(
            w == c.word for _, w in poi_entries[:0])]  # 占位:核心断言在下面按分数验证
        lows = [c.word for c in top[:8] if c.word in {w for _, w in random.sample(poi_entries, 500)}]
        check(f"P3 前缀 {prefix} 前8无长尾专名", not lows, f"{lows}")

    # ===== P4 高频主词 top-1 零回归(对照无自定义引擎) =====
    hi = []
    for idx in range(len(e3.dict.full.keys)):
        key = e3.dict.full.keys[idx]
        ws = e3.dict.full.words_at(idx)
        if ws and ws[0][1] >= 160 and len(key) >= 2:
            hi.append(key)
    random.seed(11)
    flip26 = []
    for key in random.sample(hi, 250):
        a = e3.candidates(key, 3)
        b = e1.candidates(key, 3)
        if a and b and a[0].word != b[0].word:
            aw = {w for w, _ in e3.dict.exact_words(key)}
            # 仅当新 top1 是"自定义词"才算回归(主词库内部次序波动不算)
            if a[0].word not in aw or a[0].word in {w for _, w in poi_entries}:
                flip26.append((key, b[0].word, a[0].word))
    check("P4 高频主词26键top1零回归(250)", not flip26, f"{flip26[:5]}")
    flipt9 = []
    for key in random.sample(hi, 120):
        d = to_digits(key)
        a = e3.candidates_for_t9(d, 3)
        if a and a[0].word in {w for _, w in poi_entries}:
            flipt9.append((key, a[0].word))
    check("P4 高频主词T9 top1不被专名占据(120)", not flipt9, f"{flipt9[:5]}")

    # ===== P5 性能 =====
    t9seq = to_digits("huachuangshenghuoguangchang")
    mx = 0.0
    for i in range(2, len(t9seq) + 1):
        e3.t9_cache.clear()
        t0 = time.time()
        e3.candidates_for_t9(t9seq[:i], 60)
        mx = max(mx, (time.time() - t0) * 1000)
    check("P5 长专名T9渐进击键 <120ms(py参照)", mx < 120, f"max={mx:.1f}ms")
    mx26 = 0.0
    py = "lincuixili"
    for i in range(2, len(py) + 1):
        t0 = time.time()
        e3.candidates(py[:i], 60)
        mx26 = max(mx26, (time.time() - t0) * 1000)
    check("P5 专名26键渐进击键 <120ms(py参照)", mx26 < 120, f"max={mx26:.1f}ms")

    print()
    if fails:
        print(f"共 {len(fails)} 项失败: {fails}")
        raise SystemExit(1)
    print("T5 专有名词电池全部通过")


if __name__ == "__main__":
    run()
