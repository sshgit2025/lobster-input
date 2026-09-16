"""PinyinEngine 参照实现(镜像 Android HEAD 2575ae7 的 PinyinEngine.kt)。
支持注入补丁开关,用于对比"现状 vs 新方案"。
"""
import os

from engine_base import ASSETS, T9, LETTER2DIGIT, SortedTable

LEVEL_W = 1_000
LEN_W = 400
LAYER_SENTENCE = 5_000_000
LAYER_EXACT = 4_000_000
LAYER_SENTENCE_FULL = 3_900_000
LAYER_SENTENCE_PARTIAL = 1_800_000
PEN_MISS = 8_000
LAYER_FUZZY = 3_500_000
LAYER_ABBR = 3_000_000
LAYER_PREFIX = 2_000_000
LAYER_CORRECTION = 1_500_000
LAYER_ABBR_PREFIX = 1_000_000
LAYER_SINGLE = 0
USER_WEIGHT = 20_000
USER_CAP = 20
MATCH_W = 1_000_000
MAX_T9_WORD_DIGITS = 9
MAX_T9_SEG = 13
MAX_T9_SENTENCE = 64
SEG_PENALTY = 300
SENT_PEN = 380
SENT_TOPK = 3
BIGRAM_W = 200


class Dictionary:
    def __init__(self):
        self.full = SortedTable()
        self.initials = SortedTable()
        self.syllables = set()
        self.syllable_prefixes = set()
        self.max_syllable_len = 6
        # 字→合法读音集(由词典单字条目构建):切分歧义的权威裁决数据
        self.char_readings = {}

    def load(self):
        self.full.load(os.path.join(ASSETS, "pinyin_dict.txt"))
        self.initials.load(os.path.join(ASSETS, "initials_dict.txt"))
        with open(os.path.join(ASSETS, "syllables.txt"), encoding="utf-8") as f:
            for raw in f:
                s = raw.strip()
                if not s:
                    continue
                self.syllables.add(s)
                for i in range(1, len(s) + 1):
                    self.syllable_prefixes.add(s[:i])
                self.max_syllable_len = max(self.max_syllable_len, len(s))
        # 字读音表:单字条目(key 为合法音节)反查 字→读音集,切分歧义的权威裁决数据。
        # 华→{hua} 纳→{na}:huana 对齐 华纳 唯一切 hua|na,根治贪心切成 huan|a。
        for idx, key in enumerate(self.full.keys):
            if key not in self.syllables:
                continue
            for w, _lv in self.full.words_at(idx):
                if len(w) == 1:
                    self.char_readings.setdefault(w, set()).add(key)

    def is_syllable(self, s):
        return s in self.syllables

    def is_syllable_prefix(self, s):
        return s in self.syllable_prefixes

    def longest_syllable_at(self, s, pos):
        max_len = min(self.max_syllable_len, len(s) - pos)
        for ln in range(max_len, 0, -1):
            if s[pos:pos + ln] in self.syllables:
                return ln
        return 0

    def exact_words(self, key):
        return self.full.exact(key)

    def prefix_words(self, prefix, limit):
        return self.full.prefix(prefix, limit)

    def best_word(self, key):
        ws = self.full.exact(key)
        return ws[0] if ws else None

    def initials_exact(self, key):
        return self.initials.exact(key)

    def initials_prefix(self, prefix, limit):
        return self.initials.prefix(prefix, limit)

    def initials_has_prefix(self, prefix):
        return self.initials.has_prefix(prefix)

    def split_syllables(self, inp):
        out = []
        pos = 0
        n = len(inp)
        while pos < n:
            if inp[pos] == "'":
                pos += 1
                continue
            matched = -1
            for ln in range(min(self.max_syllable_len, n - pos), 0, -1):
                if inp[pos:pos + ln] in self.syllables:
                    matched = ln
                    break
            if matched > 0:
                out.append(inp[pos:pos + matched])
                pos += matched
            else:
                out.append(inp[pos:])
                break
        return out


class Candidate:
    __slots__ = ("word", "matched_len", "score", "pinyin")

    def __init__(self, word, matched_len, score, pinyin=""):
        self.word = word
        self.matched_len = matched_len
        self.score = score
        self.pinyin = pinyin

    def __repr__(self):
        return f"{self.word}({self.matched_len},{self.score})"


class Engine:
    def __init__(self, dictionary, patches=None):
        self.dict = dictionary
        self.patches = set(patches or [])
        self.user_freq = {}
        self.user_bigram = {}
        self.custom_words = []  # (word, pinyin, digits, freq)
        self.expand_cache = {}
        self.top_words_cache = {}
        self.t9_cache = {}
        self._load_custom()

    def _load_custom(self):
        """legacy 线性表加载(V1 对照引擎用),只认旧 3 列平铺格式(拼音\\t词\\t词频)。
        custom_dict v2 起文件为主词库同格式分组行(key\\t词1 lv1 ...)——V1 是历史基线,
        不掺入 v2 词库,直接跳过分组行;v2 的正式通道是 EngineV3 的 CustomTable。"""
        path = os.path.join(ASSETS, "custom_dict.txt")
        if not os.path.exists(path):
            return
        with open(path, encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) < 3 or not parts[2].strip().isdigit():
                    continue  # 非旧 3 列平铺格式(v2 分组行):V1 基线不加载
                pinyin = parts[0].strip().lower()
                word = parts[1].strip()
                freq = int(parts[2])
                if not pinyin or not word or not self._all_valid_syllables(pinyin):
                    continue
                digits = "".join(LETTER2DIGIT.get(c, ' ') for c in pinyin)
                if ' ' in digits:
                    continue
                self.custom_words.append((word, pinyin, digits, freq))

    def _all_valid_syllables(self, pinyin):
        i = 0
        while i < len(pinyin):
            matched = 0
            for L in range(min(self.dict.max_syllable_len, len(pinyin) - i), 0, -1):
                if self.dict.is_syllable(pinyin[i:i + L]):
                    matched = L
                    break
            if matched == 0:
                return False
            i += matched
        return True

    # ===== 用户学习 =====
    def learn_sequence(self, prev, word):
        self.user_freq[word] = self.user_freq.get(word, 0) + 1
        if prev:
            m = self.user_bigram.setdefault(prev, {})
            m[word] = m.get(word, 0) + 1
        self.t9_cache.clear()

    def user_bonus(self, word):
        return min(self.user_freq.get(word, 0), USER_CAP) * USER_WEIGHT

    def pair_count(self, a, b):
        return self.user_bigram.get(a, {}).get(b, 0)

    def len_bonus(self, word):
        return (min(len(word), 5) - 1) * LEN_W

    def layer_score(self, layer, level, word, penalty=0):
        return layer + level * LEVEL_W + self.len_bonus(word) - penalty + self.user_bonus(word)

    # ===== 26 键(HEAD 版本,含 2575ae7 的前缀补全) =====
    def candidates(self, inp, limit=40):
        pinyin = inp.replace("'", "")
        if not pinyin:
            return []
        n = len(pinyin)
        merged = {}

        def push(word, matched_len, score):
            if not word:
                return
            old = merged.get(word)
            if old is None or score > old.score:
                merged[word] = Candidate(word, matched_len, score)

        exacts = self.dict.exact_words(pinyin)
        prefixes = self.dict.prefix_words(pinyin, 400)
        has_full_word = bool(exacts) or bool(prefixes)
        for w, lv in exacts:
            push(w, n, self.layer_score(LAYER_EXACT, lv, w))
        for w, lv, klen in prefixes:
            push(w, klen, self.layer_score(LAYER_EXACT, lv, w, (klen - n) * PEN_MISS))

        s = self.sentence_candidate(pinyin)
        if s:
            if s.matched_len >= n and not has_full_word:
                layer = LAYER_SENTENCE
            elif s.matched_len >= n:
                layer = LAYER_SENTENCE_FULL
            else:
                layer = LAYER_SENTENCE_PARTIAL
            push(s.word, s.matched_len, layer + max(s.score, 0))

        for w, lv in self.dict.initials_exact(pinyin):
            push(w, n, self.layer_score(LAYER_ABBR, lv, w))
        for w, lv, klen in self.dict.initials_prefix(pinyin, 60):
            push(w, klen, self.layer_score(LAYER_ABBR_PREFIX, lv, w, (klen - n) * 15))

        syls = self.dict.split_syllables(pinyin)
        if syls and syls[0] != pinyin and self.dict.is_syllable(syls[0]):
            for w, lv in self.dict.exact_words(syls[0]):
                if len(w) == 1:
                    push(w, len(syls[0]), self.layer_score(LAYER_SINGLE, lv, w))

        for word, py, digits, freq in self.custom_words:
            if pinyin.startswith(py):
                push(word, len(py), LAYER_EXACT + freq * LEVEL_W + self.len_bonus(word))
            elif n >= 2 and py.startswith(pinyin):
                push(word, len(py), LAYER_EXACT + freq * LEVEL_W + self.len_bonus(word) - (len(py) - n) * PEN_MISS)

        if len(merged) < 2:
            self._segmented_fallback(pinyin, push)
        if not merged:
            push(pinyin, n, LAYER_SINGLE - 1)
        return sorted(merged.values(), key=lambda c: -c.score)[:limit]

    def _segmented_fallback(self, pinyin, push):
        pos = 0
        seg = 0
        while pos < len(pinyin) and seg < 2:
            ln = self.dict.longest_syllable_at(pinyin, pos)
            if ln == 0:
                push(pinyin[pos:], len(pinyin), LAYER_SINGLE - 2)
                return
            syl = pinyin[pos:pos + ln]
            for w, lv in self.dict.exact_words(syl):
                if len(w) == 1:
                    push(w, pos + ln, self.layer_score(LAYER_SINGLE, lv, w))
            pos += ln
            seg += 1

    def sentence_candidate(self, inp):
        n = len(inp)
        if n < 2:
            return None
        NEG = float("-inf")
        dp = [NEG] * (n + 1)
        frm = [-1] * (n + 1)
        word = [None] * (n + 1)
        dp[0] = 0
        for i in range(1, n + 1):
            lo = max(0, i - self.dict.max_syllable_len * 4)
            for j in range(lo, i):
                if dp[j] == NEG:
                    continue
                best = self.dict.best_word(inp[j:i])
                if best is None and i == n and j > 0:
                    comp = None
                    for w, lv, klen in self.dict.prefix_words(inp[j:i], 30):
                        adj = lv - (klen - (i - j)) * 8
                        if comp is None or adj > comp[1]:
                            comp = (w, adj)
                    best = comp
                if best is None:
                    continue
                gain = best[1] - SEG_PENALTY + min(self.user_freq.get(best[0], 0), USER_CAP)
                if dp[j] + gain > dp[i]:
                    dp[i] = dp[j] + gain
                    frm[i] = j
                    word[i] = best[0]
        end = n
        while end > 0 and dp[end] == NEG:
            end -= 1
        if end < 2 or frm[end] < 0:
            return None
        parts = []
        cur = end
        while cur > 0 and frm[cur] >= 0:
            parts.append(word[cur])
            cur = frm[cur]
        if cur != 0 or len(parts) < 2:
            return None
        return Candidate("".join(reversed(parts)), end, int(dp[end]))

    # ===== T9 展开 =====
    def expand_full_pinyin(self, digits):
        cached = self.expand_cache.get(digits)
        if cached is not None:
            return cached
        out = []
        buf = [' '] * len(digits)

        def dfs(pos, syl_start):
            if len(out) >= 512:
                return
            if pos == len(digits):
                out.append("".join(buf))
                return
            letters = T9.get(digits[pos])
            if not letters:
                return
            for c in letters:
                buf[pos] = c
                cur = "".join(buf[syl_start:pos + 1])
                if self.dict.is_syllable_prefix(cur):
                    dfs(pos + 1, syl_start)
                    if self.dict.is_syllable(cur):
                        dfs(pos + 1, pos + 1)

        dfs(0, 0)
        if len(self.expand_cache) > 4000:
            self.expand_cache.clear()
        self.expand_cache[digits] = out
        return out

    def expand_initials(self, digits):
        out = []
        buf = [' '] * len(digits)

        def dfs(pos):
            if len(out) >= 120:
                return
            if pos == len(digits):
                out.append("".join(buf))
                return
            letters = T9.get(digits[pos])
            if not letters:
                return
            for c in letters:
                buf[pos] = c
                if self.dict.initials_has_prefix("".join(buf[:pos + 1])):
                    dfs(pos + 1)

        dfs(0)
        return out

    def best_t9_seg_partial(self, digits):
        if not digits:
            return [], 0
        n = len(digits)
        NEG = float("-inf")
        dp = [NEG] * (n + 1)
        back_len = [0] * (n + 1)
        back_syl = [None] * (n + 1)
        dp[0] = 0
        for i in range(1, n + 1):
            max_l = min(self.dict.max_syllable_len, i)
            for L in range(1, max_l + 1):
                if dp[i - L] == NEG:
                    continue
                best_syl = None
                best_lv = -1
                for exp in self.expand_full_pinyin(digits[i - L:i]):
                    if not self.dict.is_syllable(exp):
                        continue
                    ws = self.dict.exact_words(exp)
                    lv = ws[0][1] if ws else 0
                    if lv > best_lv:
                        best_lv = lv
                        best_syl = exp
                if best_syl is None:
                    continue
                score = dp[i - L] + best_lv - SEG_PENALTY
                if score > dp[i]:
                    dp[i] = score
                    back_len[i] = L
                    back_syl[i] = best_syl
        covered = 0
        for i in range(n, -1, -1):
            if dp[i] != NEG:
                covered = i
                break
        parts = []
        i = covered
        while i > 0:
            parts.append(back_syl[i])
            i -= back_len[i]
        return list(reversed(parts)), covered

    def best_t9_seg(self, digits):
        segs, covered = self.best_t9_seg_partial(digits)
        return segs if covered == len(digits) and covered > 0 else None

    def top_t9_words(self, seg):
        cached = self.top_words_cache.get(seg)
        if cached is not None:
            return cached
        best = {}
        for exp in self.expand_full_pinyin(seg):
            for w, lv in self.dict.exact_words(exp)[:SENT_TOPK]:
                if lv > best.get(w, -1):
                    best[w] = lv
        r = sorted(best.items(), key=lambda kv: -kv[1])[:SENT_TOPK]
        if len(self.top_words_cache) > 8000:
            self.top_words_cache.clear()
        self.top_words_cache[seg] = r
        return r

    def sentence_t9(self, digits):
        raw = len(digits)
        if raw < 4:
            return None
        n = min(raw, MAX_T9_SENTENCE)
        dp = [dict() for _ in range(n + 1)]
        dp[0][""] = (0, -1, "")
        for i in range(1, n + 1):
            cand = {}

            def relax(w, base, j):
                for pw, st in dp[j].items():
                    g = base
                    if pw:
                        c = self.pair_count(pw, w)
                        if c > 0:
                            g += min(c, 2) * BIGRAM_W
                    sc = st[0] + g
                    old = cand.get(w)
                    if old is None or sc > old[0]:
                        cand[w] = (sc, j, pw)

            lo = max(0, i - MAX_T9_SEG)
            for j in range(lo, i):
                if not dp[j]:
                    continue
                for w, lv in self.top_t9_words(digits[j:i]):
                    relax(w, lv - SENT_PEN, j)
            for word, py, cw_digits, freq in self.custom_words:
                ln = len(cw_digits)
                if i >= ln and dp[i - ln] and digits[i - ln:i] == cw_digits:
                    relax(word, freq * LEVEL_W, i - ln)
            if cand:
                for w, st in sorted(cand.items(), key=lambda kv: -kv[1][0])[:SENT_TOPK]:
                    dp[i][w] = st
        cov = 0
        for i in range(n, 1, -1):
            if dp[i]:
                cov = i
                break
        if cov < 2:
            return None
        w = max(dp[cov].items(), key=lambda kv: kv[1][0])[0]
        parts = []
        i = cov
        while i > 0:
            st = dp[i].get(w)
            if st is None:
                return None
            parts.append(w)
            i = st[1]
            w = st[2]
        if len(parts) < 2:
            return None
        return "".join(reversed(parts)), cov

    # ===== T9 候选(HEAD 现状) =====
    def candidates_t9(self, digits, limit=40):
        if not digits:
            return []
        merged = {}

        def consider(word, matched_len, base, level, pinyin):
            score = matched_len * MATCH_W + base + level * LEVEL_W + self.len_bonus(word) + self.user_bonus(word)
            old = merged.get(word)
            if old is None or score > old.score:
                merged[word] = Candidate(word, matched_len, score, pinyin)

        n = len(digits)
        if n >= 4:
            st = self.sentence_t9(digits)
            if st:
                whole, cov = st
                sc = cov * MATCH_W + LAYER_SENTENCE
                old = merged.get(whole)
                if old is None or sc > old.score:
                    merged[whole] = Candidate(whole, cov, sc)
        max_l = min(n, MAX_T9_WORD_DIGITS)
        if n <= MAX_T9_WORD_DIGITS:
            for s in self.expand_initials(digits):
                for w, lv in self.dict.initials_exact(s):
                    consider(w, n, LAYER_ABBR, lv, "")
        for L in range(2, max_l + 1):
            prefix = digits[:L]
            exps = self.expand_full_pinyin(prefix)
            for exp in exps:
                for w, lv in self.dict.exact_words(exp):
                    consider(w, L, LAYER_EXACT, lv, exp)
            if L == n and n <= MAX_T9_WORD_DIGITS and len(exps) <= 24:
                for exp in exps:
                    for w, lv, klen in self.dict.prefix_words(exp, 500):
                        penalized = lv * LEVEL_W - (klen - L) * 15
                        score = L * MATCH_W + LAYER_PREFIX + penalized + self.len_bonus(w) + self.user_bonus(w)
                        old = merged.get(w)
                        if old is None or score > old.score:
                            merged[w] = Candidate(w, L, score, exp)
        for word, py, cw_digits, freq in self.custom_words:
            if digits.startswith(cw_digits):
                sc = len(cw_digits) * MATCH_W + LAYER_SENTENCE + freq * LEVEL_W + self.len_bonus(word)
                old = merged.get(word)
                if old is None or sc > old.score:
                    merged[word] = Candidate(word, len(cw_digits), sc, py)
            elif n >= 2 and cw_digits.startswith(digits):
                sc = n * MATCH_W + LAYER_ABBR_PREFIX + freq
                old = merged.get(word)
                if old is None or sc > old.score:
                    merged[word] = Candidate(word, n, sc, py)
        if not merged:
            for L in range(min(n, MAX_T9_WORD_DIGITS), 0, -1):
                for exp in self.expand_full_pinyin(digits[:L]):
                    for w, lv in self.dict.exact_words(exp):
                        consider(w, L, LAYER_SINGLE, lv, exp)
                if merged:
                    break
        if not merged:
            self._append_partial_chinese(digits, merged)
        return sorted(merged.values(), key=lambda c: -c.score)[:limit]

    def _append_partial_chinese(self, digits, merged):
        segs, covered = self.best_t9_seg_partial(digits)
        covered_pinyin = "".join(segs)

        def put(w, mlen, score, py):
            if not w:
                return
            old = merged.get(w)
            if old is None or score > old.score:
                merged[w] = Candidate(w, mlen, score, py)

        if covered_pinyin:
            for w, lv in self.dict.exact_words(covered_pinyin):
                put(w, covered, LAYER_EXACT + lv * LEVEL_W + self.len_bonus(w) + self.user_bonus(w), covered_pinyin)
        if covered < len(digits):
            for letter in T9.get(digits[covered], ""):
                pre = covered_pinyin + letter
                for w, lv in self.dict.exact_words(pre):
                    put(w, len(digits), LAYER_ABBR + lv * LEVEL_W, pre)
                for w, lv, klen in self.dict.prefix_words(pre, 30):
                    put(w, len(digits), LAYER_PREFIX + lv * LEVEL_W - (klen - len(pre)) * 15, pre)

    def candidates_for_t9(self, digits, limit=40):
        key = digits
        cached = self.t9_cache.get(key)
        if cached is None:
            cached = self.candidates_t9(digits, 60)
            self.t9_cache[key] = cached
        return cached[:limit]

    # ===== 锁定态过滤(HEAD 现状) =====
    def sentence_from_pinyin(self, pinyin):
        n = len(pinyin)
        if n < 2:
            return None
        NEG = float("-inf")
        dp = [NEG] * (n + 1)
        frm = [-1] * (n + 1)
        word = [None] * (n + 1)
        dp[0] = 0
        for i in range(1, n + 1):
            lo = max(0, i - self.dict.max_syllable_len * 4)
            for j in range(lo, i):
                if dp[j] == NEG:
                    continue
                best = self.dict.best_word(pinyin[j:i])
                if best is None:
                    continue
                gain = best[1] - SEG_PENALTY
                if dp[j] + gain > dp[i]:
                    dp[i] = dp[j] + gain
                    frm[i] = j
                    word[i] = best[0]
        end = n
        while end > 0 and dp[end] == NEG:
            end -= 1
        if end < 2 or frm[end] < 0:
            return None
        parts = []
        cur = end
        while cur > 0 and frm[cur] >= 0:
            parts.append(word[cur])
            cur = frm[cur]
        if cur != 0 or len(parts) < 2:
            return None
        return Candidate("".join(reversed(parts)), end, end * MATCH_W + LAYER_SENTENCE, pinyin[:end])

    def candidates_for_t9_filtered(self, digits, locked_pinyin, limit=40):
        if not locked_pinyin:
            return self.candidates_for_t9(digits, limit)
        remain_digits = digits[len(locked_pinyin):] if len(locked_pinyin) < len(digits) else ""
        remain_pinyin = "".join(self.best_t9_seg_partial(remain_digits)[0]) if remain_digits else ""
        full = locked_pinyin + remain_pinyin
        out = {}

        def put(w, ml, sc):
            if not w:
                return
            o = out.get(w)
            if o is None or sc > o.score:
                out[w] = Candidate(w, ml, sc, full[:ml])

        s = self.sentence_from_pinyin(full)
        if s:
            out[s.word] = s
        for w, lv in self.dict.exact_words(full):
            put(w, len(full), len(full) * MATCH_W + LAYER_EXACT + lv * LEVEL_W + self.len_bonus(w))
        for w, lv, klen in self.dict.prefix_words(full, 80):
            put(w, len(full), len(full) * MATCH_W + LAYER_PREFIX + lv * LEVEL_W - (klen - len(full)) * 15)
        syls = self.dict.split_syllables(full)
        if syls and self.dict.is_syllable(syls[0]):
            for w, lv in self.dict.exact_words(syls[0]):
                put(w, len(syls[0]), len(syls[0]) * MATCH_W + LAYER_SINGLE + lv * LEVEL_W)
        if not out:
            return self.candidates(full, limit)
        return sorted(out.values(), key=lambda c: -c.score)[:limit]

    def t9_display_pinyin(self, digits):
        if not digits:
            return digits
        cands = self.candidates_for_t9(digits, 60)
        if cands and cands[0].pinyin:
            return self._split_known(cands[0].pinyin)
        segs, covered = self.best_t9_seg_partial(digits)
        parts = list(segs)
        for idx in range(covered, len(digits)):
            parts.append(self._default_letter(digits[idx]))
        return "'".join(parts)

    def _default_letter(self, d):
        for c in T9.get(d, ""):
            if self.dict.is_syllable_prefix(c):
                return c
        return T9.get(d, d)[0] if T9.get(d) else d

    def _split_known(self, py):
        parts = []
        i = 0
        while i < len(py):
            matched = 0
            for L in range(min(self.dict.max_syllable_len, len(py) - i), 0, -1):
                if self.dict.is_syllable(py[i:i + L]):
                    matched = L
                    break
            if matched == 0:
                parts.append(py[i:])
                break
            parts.append(py[i:i + matched])
            i += matched
        return "'".join(parts)


def to_digits(pinyin):
    return "".join(LETTER2DIGIT.get(c, c) for c in pinyin)


_dict = None


def load_engine(patches=None):
    global _dict
    if _dict is None:
        _dict = Dictionary()
        _dict.load()
    return Engine(_dict, patches)
