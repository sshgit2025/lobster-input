"""测量 expandFullPinyin 展开规模与耗时,确定 T9 前缀补全的可行预算。"""
import time

from engine import load_engine, to_digits

e = load_engine()

samples = ["youmeiy", "shaow", "nihaom", "woxiangch", "zenmeb", "shenmesh",
           "weishenm", "meiguanx", "haoziweizh", "womenyiqichifan"]
for py in samples:
    d = to_digits(py)
    t0 = time.perf_counter()
    exps = e.expand_full_pinyin(d)
    dt = (time.perf_counter() - t0) * 1000
    # 区分:整串可切成完整音节 vs 带残段
    full = [x for x in exps if e._all_valid_syllables(x)]
    partial = [x for x in exps if not e._all_valid_syllables(x)]
    print(f"{py:18s} d={d:16s} exps={len(exps):4d} full={len(full):3d} partial={len(partial):4d} {dt:6.1f}ms sample_partial={partial[:4]}")
