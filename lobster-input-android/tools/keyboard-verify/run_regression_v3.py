#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 全量回归运行器:把 load_engine_v2 替换为 EngineV3(海量自定义词库),
原样重跑全部历史验证电池——确保 61 万自定义词追加后过去所有修复/优化零回归。

用法: python3 run_regression_v3.py [--legacy]
  --legacy  不打补丁,跑原始 V2(对照基线)
"""
import sys
import runpy
import io
import os
import contextlib
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

BATTERIES = [
    "test_v2.py",                 # V2 核心:T9不完整拼音+自造词+旧修复回归+性能
    "test_full_coverage.py",      # 单字全量可达(yi打不出咦)
    "test_choice_memory.py",      # 用户选择记忆(RIME调频)
    "test_seg_fix.py",            # 切分歧义(huana)+锁定边界+性能
    "test_t9_lock.py",            # T9锁定音节栈
    "test_t9_typo_tolerance.py",  # 九宫格错键容忍
    "test_t9_prefix_lock.py",     # 单键/前缀锁定点选生效(2026-07 任务1)
    "test_symbol_autoreturn.py",  # 符号页点选自动回跳(2026-07 任务2,状态机模型)
    "test_key1_symbols.py",       # 九宫格1键高频符号候选(2026-07 任务3,交互模型)
    "test_proper_nouns.py",       # T5 专有名词扩充(2026-07 任务4:地名/单位/小区/店铺)
    "test_voice_toolbar_layout.py",  # 语音工具栏去滑动重设计(2026-07 任务5,布局预算模型)
    "test_t9_selector_persist.py",   # 候选拼音列常驻可改选(2026-07-11,控制器模型)
    "test_mode_switch.py",           # 中英↔九宫格模式切换UX(2026-07,状态机复现+修复)
    "test_brands_chunks.py",         # T6品牌层+T7组块层+口语加权(2026-07-17)
    "test_punct_suggestion.py",      # 候选栏标点联想(2026-07-23,交互模型)
]

FAIL_MARKERS = ("FAIL", "Traceback", "AssertionError")
PASS_MARKERS = ("全部通过", "全部通过", "模型全部通过")


def main():
    legacy = "--legacy" in sys.argv
    if not legacy:
        import engine_v2
        import engine_v3
        engine_v2.load_engine_v2 = engine_v3.load_engine_v3
        # 部分电池 from engine_v2 import CAND_LIMIT 等常量——不受影响(V3 复用同值)
        print("== 已启用 EngineV3(海量自定义词库)补丁 ==")
    else:
        print("== 对照基线:原始 V2 ==")

    results = []
    for t in BATTERIES:
        buf = io.StringIO()
        t0 = time.time()
        ok = True
        err = ""
        try:
            with contextlib.redirect_stdout(buf):
                runpy.run_path(os.path.join(HERE, t), run_name="__main__")
        except SystemExit as e:
            if e.code not in (0, None):
                ok = False
                err = f"exit={e.code}"
        except Exception as e:  # noqa
            ok = False
            err = repr(e)
        out = buf.getvalue()
        if any(m in out for m in FAIL_MARKERS):
            ok = False
        dt = time.time() - t0
        results.append((t, ok, dt, out, err))
        print(f"{'PASS' if ok else 'FAIL'}  {t:32s} {dt:6.1f}s")
        if not ok:
            print("------ 失败输出(尾部 40 行) ------")
            print("\n".join(out.splitlines()[-40:]))
            if err:
                print("EXC:", err)
            print("-----------------------------------")

    n_ok = sum(1 for _, ok, _, _, _ in results if ok)
    print(f"\n===== {n_ok}/{len(results)} 电池通过 =====")
    sys.exit(0 if n_ok == len(results) else 1)


if __name__ == "__main__":
    main()
