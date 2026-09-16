# -*- coding: utf-8 -*-
"""benchmark 跑分:基线V3(无LM) vs LM 版,#1 整句重建正确率。
用法: CHAR_LM=/tmp/char_bigram.txt python3 bench_lm.py [bench_cases.tsv]
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from engine_v3 import load_engine_v3
from engine_lm import load_engine_lm
from char_lm import CharBigramLM

LM_PATH = os.environ.get("CHAR_LM", "/tmp/char_bigram.txt")
BENCH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "bench_cases.tsv")


def load_cases():
    out = []
    with open(BENCH, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) == 2:
                out.append((p[0], p[1]))
    return out


def run():
    cases = load_cases()
    e0 = load_engine_v3()
    lm = CharBigramLM().load(LM_PATH)
    e1 = load_engine_lm(); e1.set_lm(lm)

    n = len(cases)
    ok0 = ok1 = 0
    fixed = []
    regress = []
    t0 = time.time()
    for zh, d in cases:
        b0 = e0.candidates_for_t9(d, 1)
        b1 = e1.candidates_for_t9(d, 1)
        c0 = (b0 and b0[0].word == zh)
        c1 = (b1 and b1[0].word == zh)
        ok0 += c0; ok1 += c1
        if c1 and not c0:
            fixed.append((zh, b0[0].word if b0 else ""))
        elif c0 and not c1:
            regress.append((zh, b1[0].word if b1 else ""))
    dt = time.time() - t0
    print(f"benchmark {n} 例, 耗时 {dt:.1f}s ({dt/n/2*1000:.1f}ms/次)")
    print(f"基线 #1 正确率: {ok0}/{n} = {ok0/n:.1%}")
    print(f"LM   #1 正确率: {ok1}/{n} = {ok1/n:.1%}")
    print(f"净修复 {len(fixed)}  净回退 {len(regress)}")
    print("\n回退样例(前15):")
    for zh, got in regress[:15]:
        print(f"   目标 {zh}  →LM {got}")
    print("\n修复样例(前15):")
    for zh, got in fixed[:15]:
        print(f"   目标 {zh}  基线错→ {got}")


if __name__ == "__main__":
    run()
