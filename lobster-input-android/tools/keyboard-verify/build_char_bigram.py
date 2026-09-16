# -*- coding: utf-8 -*-
"""字级 bigram 语言模型构建器(拼音输入法整句智能核心)。

原理:整句候选的合理度 = 相邻汉字对的 bigram 条件概率之和(词内+跨词边界统一打分)。
只需原始中文文本、无需分词。剪枝到"可打出的汉字"(主词库 char_readings),控制体积。

输入:Leipzig 等语料(每行 "id\\t句子"),流式统计 unigram + adjacent bigram。
输出:char_bigram.txt —— 每行 "c1<TAB>c2 w2 c3 w3 ...",按 c1 排序,后继按权重降序。
      权重 w = round(K * (log2(count(c1,c2)+1) - log2(unigram_total(c1))) )  ——量化的条件对数概率。
      引擎侧:score(c1,c2) = 表中权重(缺失=OOV_PEN 负值,平滑)。

用法: python3 build_char_bigram.py corpus1-sentences.txt [corpus2 ...] [--out PATH] [--min-count N] [--topk K]
"""
import argparse
import math
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "..", "app", "src", "main", "assets")

CJK = re.compile(r'[㐀-䶿一-鿿\U00020000-\U0003ffff]')


def load_typeable_chars():
    """主词库中作为单字条目出现过的汉字(可打出的字);bigram 只保留这些字。"""
    chars = set()
    path = os.path.join(ASSETS, "pinyin_dict.txt")
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            toks = parts[1].split(" ")
            for i in range(0, len(toks) - 1, 2):
                w = toks[i]
                if len(w) == 1 and CJK.match(w):
                    chars.add(w)
    return chars


def runs_of_chinese(line, charset):
    """把一行切成"连续可打出汉字"的段(标点/外文/数字处断开)。"""
    cur = []
    for ch in line:
        if ch in charset:
            cur.append(ch)
        else:
            if len(cur) >= 2:
                yield cur
            cur = []
    if len(cur) >= 2:
        yield cur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpora", nargs="+")
    ap.add_argument("--out", default=os.path.join(HERE, "char_bigram.txt"))
    ap.add_argument("--min-count", type=int, default=4)
    ap.add_argument("--topk", type=int, default=48, help="每个 c1 最多保留的后继数(体积控制)")
    ap.add_argument("--scale", type=int, default=100, help="量化尺度 K")
    args = ap.parse_args()

    charset = load_typeable_chars()
    print(f"可打出汉字集: {len(charset)}", file=sys.stderr)

    uni = defaultdict(int)
    bi = defaultdict(int)
    nlines = 0
    for path in args.corpora:
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                # Leipzig 格式 "id\t句子";无 tab 则整行
                tab = line.find("\t")
                text = line[tab + 1:] if tab >= 0 else line
                nlines += 1
                for run in runs_of_chinese(text, charset):
                    prev = None
                    for ch in run:
                        uni[ch] += 1
                        if prev is not None:
                            bi[(prev, ch)] += 1
                        prev = ch
    print(f"读入 {nlines} 行;unigram {len(uni)} 字;bigram {len(bi)} 对(剪枝前)", file=sys.stderr)

    # 按 c1 聚合后继
    succ = defaultdict(list)
    for (c1, c2), cnt in bi.items():
        if cnt < args.min_count:
            continue
        succ[c1].append((c2, cnt))

    lines_out = []
    kept_bi = 0
    for c1 in sorted(succ.keys()):
        u1 = uni[c1]
        lu1 = math.log2(u1 + 1)
        items = sorted(succ[c1], key=lambda t: -t[1])[:args.topk]
        toks = []
        for c2, cnt in items:
            # 量化条件对数概率(负值);+ 常数抬升到正区间便于紧凑存储
            w = round(args.scale * (math.log2(cnt + 1) - lu1))
            toks.append(c2)
            toks.append(str(w))
            kept_bi += 1
        lines_out.append(c1 + "\t" + " ".join(toks))

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines_out) + "\n")
    size = os.path.getsize(args.out)
    print(f"输出 {args.out}: c1={len(lines_out)} bigram={kept_bi} 大小={size/1048576:.2f}MB", file=sys.stderr)


if __name__ == "__main__":
    main()
