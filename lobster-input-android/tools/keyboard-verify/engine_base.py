"""PinyinEngine 的 Python 参照实现(与 Kotlin/Swift 逐行对齐),用于本地全量回归验证。
词库直接读 lobster-input-android/app/src/main/assets/ 下真实文件。
"""
import bisect
import os

ASSETS = os.path.join(os.path.dirname(__file__), "..", "..", "app", "src", "main", "assets")

T9 = {'2': "abc", '3': "def", '4': "ghi", '5': "jkl",
      '6': "mno", '7': "pqrs", '8': "tuv", '9': "wxyz"}
LETTER2DIGIT = {c: d for d, ls in T9.items() for c in ls}


class SortedTable:
    def __init__(self):
        self.keys = []
        self.vals = []

    def load(self, path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                tab = line.find('\t')
                if tab <= 0:
                    continue
                self.keys.append(line[:tab])
                self.vals.append(line[tab + 1:].rstrip('\n'))

    def words_at(self, idx):
        parts = self.vals[idx].split(' ')
        out = []
        for i in range(0, len(parts) - 1, 2):
            w = parts[i]
            try:
                lv = int(parts[i + 1])
            except ValueError:
                lv = 0
            if w:
                out.append((w, lv))
        return out

    def exact(self, key):
        i = bisect.bisect_left(self.keys, key)
        if i < len(self.keys) and self.keys[i] == key:
            return self.words_at(i)
        return []

    def has_prefix(self, prefix):
        i = bisect.bisect_left(self.keys, prefix)
        return i < len(self.keys) and self.keys[i].startswith(prefix)

    def prefix(self, prefix, limit):
        out = []
        i = bisect.bisect_left(self.keys, prefix)
        while i < len(self.keys) and len(out) < limit:
            k = self.keys[i]
            if not k.startswith(prefix):
                break
            if len(k) != len(prefix):
                ws = self.words_at(i)
                if ws:
                    out.append((ws[0][0], ws[0][1], len(k)))
            i += 1
        return out
