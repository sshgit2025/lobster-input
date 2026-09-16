# -*- coding: utf-8 -*-
"""字级 bigram 语言模型(整句智能整句解码)。加载 char_bigram.txt,提供 score(c1,c2)。"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LM = os.environ.get("CHAR_LM", os.path.join("/tmp", "char_bigram_proto.txt"))

# OOV(表中缺失的转移)罚分:比表中最差(~-900)更低,但不至于把句子彻底压死。
OOV_SCORE = -1000


class CharBigramLM:
    def __init__(self):
        self.table = {}   # c1 -> {c2: weight}
        self.loaded = False

    def load(self, path=DEFAULT_LM):
        self.table.clear()
        with open(path, encoding="utf-8") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 2:
                    continue
                c1 = parts[0]
                toks = parts[1].split(" ")
                d = {}
                for i in range(0, len(toks) - 1, 2):
                    d[toks[i]] = int(toks[i + 1])
                self.table[c1] = d
        self.loaded = True
        return self

    def score(self, c1, c2):
        d = self.table.get(c1)
        if d is None:
            return OOV_SCORE
        return d.get(c2, OOV_SCORE)

    def sentence_score(self, s):
        """整串汉字的 bigram 链总分(相邻字对之和)。"""
        return sum(self.score(s[i], s[i + 1]) for i in range(len(s) - 1))


_lm = None


def load_lm(path=DEFAULT_LM):
    global _lm
    if _lm is None or _lm.path != path if hasattr(_lm, 'path') else True:
        _lm = CharBigramLM().load(path)
        _lm.path = path
    return _lm
