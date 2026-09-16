"""V3 方案:海量内置自定义词库(custom_dict v2,主词库同格式分组文件)。

继承 EngineV2,把"线性扫描 customWords"替换为"CustomTable(SortedTable+T9数字码索引)
二分直查",并重标定打分——落地时按此差异改 Kotlin/Swift/ArkTS。

关键设计(与 V2 legacy custom 的差异):
 1. CustomTable:与主词库同结构同 API(exact/prefix/exactByDigits/prefixByDigits),
    存储/索引方式各端复用主词库既有实现(Android SortedTable→建议改byte表、iOS ByteTable、
    鸿蒙 SortedTable),T9 数字码索引同主词库 buildT9Index。
 2. T9 全消耗规则:输入数字码整串命中自定义词时——
      同码存在主词库精确词 → LAYER_EXACT + EXACT_FULL_BONUS(与主词公平按词频竞争,
        防海量词劫持常用短码,九宫格正向的核心保护)
      同码无主词库精确词   → LAYER_SENTENCE + lv*LEVEL_W(防"破防了"这类新词被整句垃圾压住;
        镜像 legacy showcase 语义,biangbiangmian lv=500 仍置顶)
 3. T9 前缀预测:并入主词库补全统一 top-K 池(COMPLETION_TOP),同罚分同量纲,防淹没。
 4. 整句 DP:自定义词作为普通词参与(增益 lv - SENT_PEN,与主词库同量纲)。
    legacy 的 freq*LEVEL_W 千倍增益是单词条 showcase 设计,海量词会摧毁整句评分体系。
 5. 26 键:自定义精确与主词库精确同层同权;前缀补全同罚分;hasFullWord 计入自定义词
    (防止整句层在"只有自定义词能整词覆盖"时错误置顶)。
 6. 精确保底(takeWithExactGuarantee)的保底集并入自定义精确词:打全必可达。
 7. 加载:各端在主词库 READY 后异步挂载自定义表,不阻塞键盘冷启动(挂载前查询视为空表)。
"""
import os

import engine
from engine import (
    Candidate, load_engine,
    LEVEL_W, LAYER_SENTENCE, LAYER_EXACT, LAYER_SENTENCE_FULL, LAYER_SENTENCE_PARTIAL,
    PEN_MISS, LAYER_ABBR, LAYER_PREFIX, LAYER_ABBR_PREFIX, LAYER_SINGLE,
    MATCH_W, MAX_T9_WORD_DIGITS, SENT_PEN, SENT_TOPK, BIGRAM_W,
    MAX_T9_SEG, MAX_T9_SENTENCE, SEG_PENALTY,
)
from engine_base import SortedTable, LETTER2DIGIT
from engine_v2 import EngineV2, EXACT_FULL_BONUS, COMPLETION_TOP, CAND_LIMIT, T9_POOL, GAP_PEN

# 自定义词参与"补全预测"的最低词频等级:预测必须高置信(jieba 标定真实常用≥110 或
# 精选热词 142);长尾词(base残余/ext默认55)只在"打全"时可达,不进预测池——
# 防弱补全把部分消耗高频词(我想@woxiangch)挤出候选前排。
CUSTOM_COMPLETION_MIN_LV = 110

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CUSTOM = os.environ.get("CUSTOM_DICT", os.path.join(HERE, "..", "..", "app", "src", "main", "assets", "custom_dict.txt"))


class CustomTable:
    """自定义词表:主词库同格式(key\t词 lv 词 lv...),排序数组+二分 + T9数字码索引。
    镜像各端 CustomDictionary 实现。"""

    def __init__(self):
        self.table = SortedTable()
        self._digit_keys = []
        self._digit_refs = []
        self.max_digit_len = 0  # 自定义词最长数字码(T9 词层循环上限,biang=14 位不受 MAX_T9_WORD_DIGITS 截断)
        self.loaded = False

    def load(self, path):
        if not os.path.exists(path):
            return
        self.table.load(path)
        rows = []
        for idx, key in enumerate(self.table.keys):
            dk = "".join(LETTER2DIGIT.get(c, " ") for c in key)
            if " " in dk:
                continue
            rows.append((dk, idx))
        rows.sort()
        self._digit_keys = [r[0] for r in rows]
        self._digit_refs = [r[1] for r in rows]
        self.max_digit_len = max((len(k) for k in self._digit_keys), default=0)
        self.loaded = True
        # 模拟原生不可变词表(Kotlin/Swift/ArkTS 的静态表不参与 GC 扫描):
        # 60 万键的对象图会让 python gen2 GC 产生 ~100ms 级暂停,污染性能断言。
        import gc
        gc.collect()
        gc.freeze()

    def exact(self, key):
        return self.table.exact(key) if self.loaded else []

    def prefix(self, prefix, limit):
        return self.table.prefix(prefix, limit) if self.loaded else []

    def best_word(self, key):
        ws = self.exact(key)
        return ws[0] if ws else None

    def exact_by_digits(self, digits):
        if not self.loaded:
            return []
        import bisect
        out = []
        i = bisect.bisect_left(self._digit_keys, digits)
        while i < len(self._digit_keys) and self._digit_keys[i] == digits:
            ref = self._digit_refs[i]
            key = self.table.keys[ref]
            for w, lv in self.table.words_at(ref):
                out.append((w, lv, key))
            i += 1
        return out

    def prefix_by_digits(self, digits, limit):
        if not self.loaded:
            return []
        import bisect
        out = []
        i = bisect.bisect_left(self._digit_keys, digits)
        while i < len(self._digit_keys) and len(out) < limit:
            dk = self._digit_keys[i]
            if not dk.startswith(digits):
                break
            if len(dk) != len(digits):
                ref = self._digit_refs[i]
                ws = self.table.words_at(ref)
                if ws:
                    out.append((ws[0][0], ws[0][1], len(dk), self.table.keys[ref]))
            i += 1
        return out


class EngineV3(EngineV2):
    def __init__(self, dictionary, custom_path=DEFAULT_CUSTOM, patches=None):
        super().__init__(dictionary, patches)
        self.custom_words = []  # 废弃 legacy 线性表(V3 用 CustomTable)
        self.custom = CustomTable()
        self.custom.load(custom_path)

    # ===== 26 键(镜像 Kotlin candidates() 的改动版) =====
    def candidates(self, inp, limit=CAND_LIMIT):
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
        # 自定义词:精确同层同权;前缀补全同罚分(限池防扫描放大)
        c_exacts = self.custom.exact(pinyin)
        c_prefixes = self.custom.prefix(pinyin, 200) if n >= 2 else []
        # hasFullWord 计入自定义词:只有自定义词能整词覆盖时,整句不得抢 LAYER_SENTENCE
        has_full_word = bool(exacts) or bool(prefixes) or bool(c_exacts) or bool(c_prefixes)
        for w, lv in exacts:
            push(w, n, self.layer_score(LAYER_EXACT, lv, w))
        for w, lv, klen in prefixes:
            push(w, klen, self.layer_score(LAYER_EXACT, lv, w, (klen - n) * PEN_MISS))
        for w, lv in c_exacts:
            push(w, n, self.layer_score(LAYER_EXACT, lv, w))
        for w, lv, klen in c_prefixes:
            if lv < CUSTOM_COMPLETION_MIN_LV:  # 低置信长尾词不做预测(打全才出)
                continue
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

        self._user_word_candidates_26(pinyin, n, push)

        if len(merged) < 2:
            self._segmented_fallback(pinyin, push)
        if not merged:
            push(pinyin, n, LAYER_SINGLE - 1)
        ranked = sorted(merged.values(), key=lambda c: -c.score)
        exact_set = {w for w, _ in exacts} | {w for w, _ in c_exacts}
        return self._take_with_exact_guarantee(ranked, limit, exact_set)

    # ===== 26 键整句:主词库+自定义表联合 bestWord(自定义词参与切分成句) =====
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
                cb = self.custom.best_word(inp[j:i])
                if cb is not None and (best is None or cb[1] > best[1]):
                    best = cb
                if best is None and i == n and j > 0:
                    comp = None
                    for w, lv, klen in self.dict.prefix_words(inp[j:i], 30):
                        adj = lv - (klen - (i - j)) * 8
                        if comp is None or adj > comp[1]:
                            comp = (w, adj)
                    best = comp
                if best is None:
                    continue
                gain = best[1] - SEG_PENALTY + min(self.user_freq.get(best[0], 0), engine.USER_CAP)
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

    # ===== T9 候选(镜像 V2 candidates_t9 的改动版) =====
    def candidates_t9(self, digits, limit=40, locked_sylls=None):
        if not digits:
            return []
        merged = {}
        n = len(digits)
        locked = locked_sylls or []
        locked_pinyin = "".join(locked)
        bounds = self._locked_bounds(locked)

        def ok(word, key):
            return not locked or self._locked_compatible(word, key, 0, locked_pinyin, bounds)

        def put(word, matched_len, score, pinyin=""):
            if not word:
                return
            old = merged.get(word)
            if old is None or score > old.score:
                merged[word] = Candidate(word, matched_len, score, pinyin)

        def consider(word, matched_len, base, level, pinyin):
            put(word, matched_len,
                matched_len * MATCH_W + base + level * LEVEL_W + self.len_bonus(word) + self.user_bonus(word),
                pinyin)

        # 0)【单键锁定修复】全锁定+尾项音节前缀 → 复用 26 键预测通道(镜像 V2)
        if locked and len(locked_pinyin) >= n and not self.dict.is_syllable(locked[-1]):
            preds = self.candidates(locked_pinyin, limit)
            return [Candidate(c.word, n, c.score, c.pinyin) for c in preds]

        # 1) 整句联想
        if n >= 4:
            for rank, (whole, cov, spy) in enumerate(self.sentence_t9(digits, locked_sylls=locked) or []):
                layer = LAYER_SENTENCE if cov >= n else LAYER_SENTENCE_PARTIAL
                put(whole, cov, cov * MATCH_W + layer - rank * LEVEL_W, spy)

        # 2) 简拼
        if not locked and n <= MAX_T9_WORD_DIGITS:
            for s in self.expand_initials(digits):
                for w, lv in self.dict.initials_exact(s):
                    consider(w, n, LAYER_ABBR, lv, "")

        # 3) 词层:主词库 + 自定义表 逐前缀精确词(数字码索引直查)。
        #    自定义词循环上限放开到自定义表最长码(biang=14 位;legacy 线性扫描本无长度限制)。
        max_l = min(n, max(MAX_T9_WORD_DIGITS, self.custom.max_digit_len))
        for L in range(2, max_l + 1):
            bonus = EXACT_FULL_BONUS if L == n else 0
            seg = digits[:L]
            # 词层准入(主词库/自定义对称):L<=9 照旧;L==n(全消耗)不限长——
            # 打全整词(第六章 10位/事业单位 11位/biang 14位)直接可排,不再只靠整句碰运气。
            if L > MAX_T9_WORD_DIGITS and L != n:
                continue
            main_hits = self.exact_by_digits(seg)
            for w, lv, key in main_hits:
                if not ok(w, key):
                    continue
                layer = LAYER_SENTENCE if (L == n and self.user_bonus(w) > 0) else LAYER_EXACT
                put(w, L,
                    L * MATCH_W + layer + bonus + lv * LEVEL_W + self.len_bonus(w) + self.user_bonus(w),
                    key)
            # 自定义词层:全消耗时——同码有主词精确词 → 同层公平竞争(EXACT+FULL_BONUS);
            # 无主词精确词 → LAYER_SENTENCE(新词不被整句垃圾压住;showcase 语义保留)
            for w, lv, key in self.custom.exact_by_digits(seg):
                if not ok(w, key):
                    continue
                if L == n and self.user_bonus(w) > 0:
                    layer = LAYER_SENTENCE
                elif L == n and not main_hits:
                    layer = LAYER_SENTENCE
                else:
                    layer = LAYER_EXACT
                put(w, L,
                    L * MATCH_W + layer + bonus + lv * LEVEL_W + self.len_bonus(w) + self.user_bonus(w),
                    key)

        # 4) 全消耗前缀补全:主词库+自定义统一入池,top COMPLETION_TOP
        if 2 <= n <= MAX_T9_WORD_DIGITS:
            comps = []
            for w, lv, klen, key in self.prefix_by_digits(digits, 200):
                if not ok(w, key):
                    continue
                adj = lv * LEVEL_W + self.len_bonus(w) + self.user_bonus(w) - (klen - n) * PEN_MISS
                comps.append((adj, w, key))
            for w, lv, klen, key in self.custom.prefix_by_digits(digits, 200):
                if lv < CUSTOM_COMPLETION_MIN_LV:  # 低置信长尾词不做预测(打全才出)
                    continue
                if not ok(w, key):
                    continue
                adj = lv * LEVEL_W + self.len_bonus(w) + self.user_bonus(w) - (klen - n) * PEN_MISS
                comps.append((adj, w, key))
            comps.sort(key=lambda t: -t[0])
            for adj, w, key in comps[:COMPLETION_TOP]:
                put(w, n, n * MATCH_W + LAYER_EXACT + adj, key)

        # 5) 自造词(不变;legacy 自定义线性层已废弃)
        self._user_word_candidates_t9(digits, n, merged)

        # 5b) 锁定态:首锁定音节单字置入
        if locked:
            first = locked[0]
            for w, lv in self.dict.exact_words(first):
                put(w, len(first), len(first) * MATCH_W + LAYER_SINGLE + lv * LEVEL_W + self.user_bonus(w), first)

        # 6) 兜底(【单键锁定修复】同样尊重锁定过滤,镜像 V2)
        if not merged:
            for L in range(min(n, MAX_T9_WORD_DIGITS), 0, -1):
                for exp in self.expand_full_pinyin(digits[:L]):
                    for w, lv in self.dict.exact_words(exp):
                        if not ok(w, exp):
                            continue
                        consider(w, L, LAYER_SINGLE, lv, exp)
                if merged:
                    break
        if not merged:
            # 【单键锁定修复】半音节续词兜底同样带锁定过滤(镜像 V2)
            self._append_partial_chinese(digits, merged, ok if locked else None)
        ranked = sorted(merged.values(), key=lambda c: -c.score)
        return self._take_with_exact_guarantee(ranked, limit, self._t9_exact_set(digits, locked))

    # ===== 整句词源:主词库+自定义表(同量纲增益) =====
    def top_t9_words(self, seg):
        cached = self.top_words_cache.get(seg)
        if cached is not None:
            return cached
        best = {}
        for w, lv, key in self.exact_by_digits(seg):
            if lv > best.get(w, (-1, ""))[0]:
                best[w] = (lv, key)
        # 自定义词作为普通词参与整句(lv 与主词库同量纲;legacy freq*LEVEL_W 增益废弃)
        for w, lv, key in self.custom.exact_by_digits(seg):
            if lv > best.get(w, (-1, ""))[0]:
                best[w] = (lv, key)
        r = sorted(((w, lv, key) for w, (lv, key) in best.items()), key=lambda t: -t[1])[:SENT_TOPK]
        if len(self.top_words_cache) > 8000:
            self.top_words_cache.clear()
        self.top_words_cache[seg] = r
        return r

    # ===== 整句(镜像 V2 sentence_t9,仅删 legacy 自定义线性跳转;
    #       自定义词已并入 top_t9_words 词源,自动参与所有 span) =====
    def sentence_t9(self, digits, locked_sylls=None):
        raw = len(digits)
        if raw < 4:
            return None
        locked = locked_sylls or []
        locked_pinyin = "".join(locked)
        bounds = self._locked_bounds(locked)
        n = min(raw, MAX_T9_SENTENCE)
        dp = [dict() for _ in range(n + 1)]
        dp[0][""] = (0, -1, "", "")
        for i in range(1, n + 1):
            cand = {}

            def relax(w, base, j, key):
                if locked and not self._locked_compatible(w, key, j, locked_pinyin, bounds):
                    return
                for pw, st in dp[j].items():
                    g = base
                    if pw:
                        c = self.pair_count(pw, w)
                        if c > 0:
                            g += min(c, 2) * BIGRAM_W
                    sc = st[0] + g
                    old = cand.get(w)
                    if old is None or sc > old[0]:
                        cand[w] = (sc, j, pw, key)

            lo = max(0, i - MAX_T9_SEG)
            for j in range(lo, i):
                if not dp[j]:
                    continue
                for w, lv, key in self.top_t9_words(digits[j:i]):
                    relax(w, lv - SENT_PEN, j, key)
                if i == n and j > 0 and not self.top_t9_words(digits[j:i]):
                    comp = None
                    for w, lv, klen, key in self.prefix_by_digits(digits[j:i], 30):
                        adj = lv - (klen - (i - j)) * 8
                        if comp is None or adj > comp[1]:
                            comp = (w, adj, key)
                    if comp:
                        relax(comp[0], comp[1] - SENT_PEN, j, comp[2][:i - j])
            # 自造词跳转(不变)
            for key, words in self.user_words.items():
                kd = "".join(LETTER2DIGIT.get(c, " ") for c in key)
                if " " in kd:
                    continue
                ln = len(kd)
                if i >= ln and dp[i - ln] and digits[i - ln:i] == kd:
                    for word, cnt in words.items():
                        relax(word, (200 + min(cnt, 5)) * LEVEL_W, i - ln, key)
            # 错键容忍(不变)
            if i - 1 >= len(locked_pinyin):
                for pw, st in dp[i - 1].items():
                    sc = st[0] - GAP_PEN
                    old = cand.get(pw)
                    if old is None or sc > old[0]:
                        cand[pw] = (sc, st[1], st[2], st[3])
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
        # 输出保持 V2 位级一致(top-2 末态):单跨度整词状态占据名额时整句可能为 None,
        # 但 L==n 全消耗词层已保证整词直接可排(事业单位/第六章),无需整句兜底;
        # 曾试"遍历全部末态取前2合法"——会放出 V2 原本压制的垃圾整句(民梦/大破),已撤销。
        results = []
        seen = set()
        for w0, _st in sorted(dp[cov].items(), key=lambda kv: -kv[1][0])[:2]:
            w = w0
            parts = []
            keys = []
            i = cov
            broken = False
            while i > 0:
                st = dp[i].get(w)
                if st is None:
                    broken = True
                    break
                if w:
                    parts.append(w)
                    keys.append(st[3])
                i = st[1]
                w = st[2]
            if broken or not parts:
                continue
            gaps = cov - sum(len(k) for k in keys)
            if len(parts) < 2 and gaps <= 0:
                continue
            whole = "".join(reversed(parts))
            if whole in seen:
                continue
            seen.add(whole)
            results.append((whole, cov, "".join(reversed(keys))))
        return results or None

    # ===== 精确保底集:并入自定义精确词(打全必可达) =====
    def _t9_exact_set(self, digits, locked=None):
        locked = locked or []
        locked_pinyin = "".join(locked)
        bounds = self._locked_bounds(locked)
        out = set()
        for w, _, key in self.exact_by_digits(digits):
            if not locked or self._locked_compatible(w, key, 0, locked_pinyin, bounds):
                out.add(w)
        for w, _, key in self.custom.exact_by_digits(digits):
            if not locked or self._locked_compatible(w, key, 0, locked_pinyin, bounds):
                out.add(w)
        if locked:
            out.update(w for w, _ in self.dict.exact_words(locked[0]))
        return out

    # ===== 锁定态过滤视图沿用 V2(candidates_t9 已带 locked 支持) =====


_custom_cache = {}


def load_engine_v3(custom_path=DEFAULT_CUSTOM):
    """引擎每次新建(测试隔离用户学习态),CustomTable 不可变可跨引擎复用。"""
    base = load_engine()
    eng = EngineV3.__new__(EngineV3)
    EngineV2.__init__(eng, base.dict)
    eng.custom_words = []
    cached = _custom_cache.get(custom_path)
    if cached is None:
        cached = CustomTable()
        cached.load(custom_path)
        _custom_cache[custom_path] = cached
    eng.custom = cached
    return eng
