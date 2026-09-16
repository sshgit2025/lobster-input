# -*- coding: utf-8 -*-
"""探针:定位 锁r 被默认候选污染 + 长串锁k 1.7s 的来源。"""
import cProfile
import io
import pstats
import time

from engine import to_digits
from engine_v2 import load_engine_v2, COMPLETION_TOP


def main():
    eng = load_engine_v2()

    # 1) 锁 r:各通道产出
    print("== initials_exact('r'):", eng.dict.initials_exact("r")[:8])
    comps = []
    for w, lv, klen, key in eng.prefix_by_digits("7", 200):
        comps.append((w, key))
    rs = [c for c in comps if c[1].startswith("r")]
    print(f"== prefix_by_digits('7',200): 总{len(comps)} r开头{len(rs)} 前8: {comps[:8]}")

    cands = eng.candidates_t9("7", 40, locked_sylls=["r"])
    for c in cands[:15]:
        print(f"   {c.word!r:10} ml={c.matched_len} sc={c.score} py={c.pinyin!r}")

    # 2) custom_words 是否掺入
    print("== custom_words 条数:", len(eng.custom_words), eng.custom_words[:3])
    print("== user_words:", dict(list(eng.user_words.items())[:3]))

    # 3) 性能:长串锁 k
    d = to_digits("kanchengwanmei")
    eng.t9_cache.clear()
    t0 = time.time()
    eng.candidates_for_t9_filtered(d, "k", 60, locked_sylls=["k"])
    print(f"== 首次锁k耗时 {(time.time()-t0)*1000:.0f}ms")
    pr = cProfile.Profile()
    eng.t9_cache.clear()
    pr.enable()
    eng.candidates_for_t9_filtered(d, "k", 60, locked_sylls=["k"])
    pr.disable()
    s = io.StringIO()
    pstats.Stats(pr, stream=s).sort_stats("cumulative").print_stats(12)
    print(s.getvalue())


if __name__ == "__main__":
    main()
