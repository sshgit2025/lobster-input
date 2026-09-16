# -*- coding: utf-8 -*-
"""从 held-out 真实句子自动生成整句 benchmark(句→主读音数字→检查引擎重建)。

train/test 分离:LM 用 A 语料训练,benchmark 抽 B 语料(不同集)。
每字取"单字频率最高的读音"作为标准拼音(多音字取主音)。只收 5-12 字纯中文短句。
输出 bench_cases.tsv: 句子<TAB>digits
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from engine import load_engine
from engine_base import LETTER2DIGIT

CJK = re.compile(r'^[一-鿿]+$')


def build_char_digits(eng):
    """char -> digits(主读音)。主读音=该字作为单字条目 level 最高的读音。"""
    cr = eng.dict.char_readings
    out = {}
    for ch, readings in cr.items():
        best = None
        best_lv = -1
        for r in readings:
            lv = 0
            for w, l in eng.dict.exact_words(r):
                if w == ch:
                    lv = l
                    break
            if lv > best_lv:
                best_lv = lv
                best = r
        if best:
            dg = "".join(LETTER2DIGIT.get(c, "") for c in best)
            if dg and all(c.isdigit() for c in dg):
                out[ch] = dg
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--out", default=os.path.join(HERE, "bench_cases.tsv"))
    ap.add_argument("--n", type=int, default=800)
    ap.add_argument("--minlen", type=int, default=5)
    ap.add_argument("--maxlen", type=int, default=12)
    ap.add_argument("--stride", type=int, default=137, help="抽样步长(散布全语料)")
    args = ap.parse_args()

    eng = load_engine()
    ch2d = build_char_digits(eng)
    print(f"字→数字映射 {len(ch2d)} 字", file=sys.stderr)

    cases = []
    seen = set()
    idx = 0
    with open(args.corpus, encoding="utf-8", errors="ignore") as f:
        for line in f:
            tab = line.find("\t")
            text = line[tab + 1:].strip() if tab >= 0 else line.strip()
            # 取句中第一段纯中文
            for seg in re.split(r'[^一-鿿]+', text):
                if not (args.minlen <= len(seg) <= args.maxlen):
                    continue
                if not CJK.match(seg) or seg in seen:
                    continue
                if any(c not in ch2d for c in seg):
                    continue
                idx += 1
                if idx % args.stride != 0:
                    continue
                digits = "".join(ch2d[c] for c in seg)
                cases.append((seg, digits))
                seen.add(seg)
                break
            if len(cases) >= args.n:
                break

    with open(args.out, "w", encoding="utf-8") as f:
        for seg, d in cases:
            f.write(f"{seg}\t{d}\n")
    print(f"生成 benchmark {len(cases)} 例 → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
