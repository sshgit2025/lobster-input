# -*- coding: utf-8 -*-
"""词级 bigram 语言模型构建器(jieba 分词 → 相邻词对计数)。

词级 bigram 精确捕捉字级缺失的词法/语法搭配:P(完美|堪称) >> P(赞美|堪称)、
P(是|人民) >> P(事|人民)——字级恰好相反(称→完 比 称→赞 罕见),故字级修不了这类。

输出 word_bigram.txt: 每行 "w1<TAB>w2 b2 w3 b3 ...",b=量化奖励分=round(ALPHA*log2(cnt+1))。
只保留纯中文词(长度1-4);每 w1 取 top-K 后继;cnt>=min-count。
"""
import argparse
import math
import os
import re
import sys
from collections import defaultdict

import jieba
jieba.setLogLevel(60)

CJK_ONLY = re.compile(r'^[一-鿿]{1,4}$')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpora", nargs="+")
    ap.add_argument("--out", default="/tmp/word_bigram.txt")
    ap.add_argument("--min-count", type=int, default=5)
    ap.add_argument("--topk", type=int, default=32)
    ap.add_argument("--alpha", type=int, default=48, help="奖励量化尺度")
    ap.add_argument("--max-lines", type=int, default=6_000_000)
    args = ap.parse_args()

    bi = defaultdict(int)
    n = 0
    for path in args.corpora:
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                tab = line.find("\t")
                text = line[tab + 1:] if tab >= 0 else line
                n += 1
                if n > args.max_lines:
                    break
                # 按非中文切段,段内 jieba 分词计相邻词对
                for seg in re.split(r'[^一-鿿]+', text):
                    if len(seg) < 2:
                        continue
                    toks = [t for t in jieba.cut(seg, HMM=False) if CJK_ONLY.match(t)]
                    for a, b in zip(toks, toks[1:]):
                        bi[(a, b)] += 1
                if n % 1_000_000 == 0:
                    print(f"  已处理 {n} 行, bigram {len(bi)}", file=sys.stderr)
        if n > args.max_lines:
            break

    succ = defaultdict(list)
    total = defaultdict(int)   # count(w1) = Σ 后继计数(近似,用于条件概率)
    for (w1, w2), c in bi.items():
        if c >= args.min_count:
            succ[w1].append((w2, c))
            total[w1] += c

    lines_out = []
    kept = 0
    for w1 in sorted(succ.keys()):
        lt = math.log2(total[w1] + 1)
        items = sorted(succ[w1], key=lambda t: -t[1])[:args.topk]
        toks = []
        for w2, c in items:
            # 条件对数概率(负值);中心化 clamp 在引擎侧做。与字bigram同量纲(scale=100)。
            b = round(100 * (math.log2(c + 1) - lt))
            toks.append(w2)
            toks.append(str(b))
            kept += 1
        lines_out.append(w1 + "\t" + " ".join(toks))
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines_out) + "\n")
    size = os.path.getsize(args.out)
    print(f"输出 {args.out}: w1={len(lines_out)} bigram={kept} 大小={size/1048576:.2f}MB", file=sys.stderr)


if __name__ == "__main__":
    main()
