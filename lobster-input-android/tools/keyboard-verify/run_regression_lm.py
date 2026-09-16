#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LM 模式全量历史回归:load_engine_v2/v3 全部换成加载了字bigram LM 的 EngineLM,
原样重跑历史电池,看 LM 对历史整句/候选断言的影响(确保历史功能不回退)。"""
import os, sys, io, runpy, contextlib, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_regression_v3 as R
import engine_v2, engine_v3, engine_lm
from char_lm import CharBigramLM

LM_PATH = os.environ.get("CHAR_LM", os.path.join(HERE, "..", "..", "app", "src", "main", "assets", "char_bigram.txt"))
_lm = CharBigramLM().load(LM_PATH)

def _load(*a, **k):
    e = engine_lm.load_engine_lm()
    e.set_lm(_lm)
    return e

engine_v2.load_engine_v2 = _load
engine_v3.load_engine_v3 = _load
print(f"== LM 模式回归(char_bigram {LM_PATH}) ==")

results = []
for t in R.BATTERIES:
    buf = io.StringIO(); t0=time.time(); ok=True; err=""
    try:
        with contextlib.redirect_stdout(buf):
            runpy.run_path(os.path.join(HERE, t), run_name="__main__")
    except SystemExit as e:
        if e.code not in (0, None): ok=False; err=f"exit={e.code}"
    except Exception as e:
        ok=False; err=repr(e)
    out = buf.getvalue()
    if any(m in out for m in R.FAIL_MARKERS): ok=False
    results.append((t, ok, out, err))
    print(f"{'PASS' if ok else 'FAIL'}  {t:32s} {time.time()-t0:6.1f}s")
    if not ok:
        for ln in out.splitlines():
            if "FAIL" in ln or "Traceback" in ln: print("   ", ln)
        if err: print("   EXC:", err)
npass = sum(1 for _,ok,_,_ in results if ok)
print(f"\n===== {npass}/{len(results)} 电池通过 =====")
