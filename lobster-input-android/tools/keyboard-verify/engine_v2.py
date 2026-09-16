"""新方案 V2:T9 全消耗前缀补全 + 用户自造词(userWords)。
继承 engine.Engine,只覆写需要改的方法——落地时按此差异改 Kotlin/Swift。
"""
from engine import (
    Engine, Candidate, load_engine, to_digits,
    LEVEL_W, LAYER_SENTENCE, LAYER_EXACT, LAYER_SENTENCE_FULL, LAYER_SENTENCE_PARTIAL,
    PEN_MISS, LAYER_ABBR, LAYER_PREFIX, LAYER_ABBR_PREFIX, LAYER_SINGLE,
    MATCH_W, MAX_T9_WORD_DIGITS, SENT_PEN, SENT_TOPK, BIGRAM_W,
    MAX_T9_SEG, MAX_T9_SENTENCE, SEG_PENALTY, USER_CAP,
)
from engine_base import T9, LETTER2DIGIT

# T9 补全罚分与 26 键一致(8k/缺失位);另给"全消耗精确词"加 EXACT_FULL_BONUS,
# 保证同码精确词(要钱@yaoqian)永远压过补全词(晚上@wanshang 189k-8k=181k < 159k+60k)。
# 无精确词时(shaow=74269 无合法整切)补全词自然顶上(稍微/山西)。
EXACT_FULL_BONUS = 60_000
# 补全预测限量(对齐搜狗/Gboard:预测只置顶少量)。不限量会把 200 个"位置信息/为执行"
# 类补全全部以全消耗层高分入池,淹没逐字组词通道的单字(修"weizhi 打不出 尾")。
COMPLETION_TOP = 12
# 候选池/显示上限:40/60 会把中频单字(尾@rank60)整个截掉,滚动也找不到。
# 业界候选可滚动/展开全量;引擎侧放宽,渲染是轻量文本无压力。
# 2026-07:词库去除 30/key 构建截断后,大音节(yi=137字)全量入库;
# 100 会把锁定单音节的尾部单字再次截掉 → 200/300 保证"锁定音节后单字全量可达"。
CAND_LIMIT = 200
T9_POOL = 300
# 错键容忍:整句 DP 跳过一位"误触"的罚分。必须 > 最大成词净收益(lv≈250 - SENT_PEN 380
# 已为负,任何词都优于跳过),正常/残拼输入永不偏好跳过;连续垃圾段逐位累罚。
GAP_PEN = 600


class EngineV2(Engine):
    """新方案:
    1. 【业界标准】T9 数字码词库索引:full 表每个拼音 key 预转数字码并排序,
       T9 查词直接二分数字码(替代 expandFullPinyin 裸展开+逐一查词)。
       根治 DFS 512 截断丢词(shangban=74264226 曾被 qiang* 占满截断 → 上班永远打不出)。
    2. candidatesT9 重排层级(全消耗>部分消耗)+ 残段前缀补全(修 youmeiy/shaow)。
    3. sentenceT9 末段残段补全(整句也能吃掉尾部声母)。
    4. 用户自造词 userWords:逐词组合选词会话结束时学习,下次整串直接出词。
    """

    def __init__(self, dictionary, patches=None):
        super().__init__(dictionary, patches)
        # 自造词:pinyin -> {word: count};digits 由 pinyin 派生
        self.user_words = {}
        # 【新】T9 数字码索引:digits_key → [full 表行号](排序数组,二分)
        self._build_digit_index()
        # 字读音对齐记忆化(切分歧义裁决:huana→hua|na 而非 huan|a)
        self._align_cache = {}

    # ===== 切分歧义根治(问题:huanameduoqian 被当成 huan|a|me...) =====
    # 业界标准:候选词的拼音按"字→读音表"对齐切分(权威),不再用贪心最长/音节频率猜。
    def align_word_pinyin(self, word, key):
        """把词的拼音 key 按字对齐切成音节列表(华南+huanan→[hua,nan]、西安+xian→[xi,an])。
        对不齐(生僻字/数据缺失)返回 None,调用方回退贪心。"""
        ck = (word, key)
        if ck in self._align_cache:
            return self._align_cache[ck]
        readings = self.dict.char_readings
        result = None

        def dfs(ci, pos, acc):
            nonlocal result
            if result is not None:
                return
            if ci == len(word):
                if pos == len(key):
                    result = list(acc)
                return
            rs = readings.get(word[ci])
            if not rs:
                return
            for r in sorted(rs, key=len, reverse=True):
                if key.startswith(r, pos):
                    acc.append(r)
                    dfs(ci + 1, pos + len(r), acc)
                    acc.pop()
                    if result is not None:
                        return

        dfs(0, 0, [])
        if len(self._align_cache) > 8000:
            self._align_cache.clear()
        self._align_cache[ck] = result
        return result

    @staticmethod
    def respects_locked(aligned, locked_sylls):
        """候选读音的音节边界必须兼容已锁定音节边界(锁 hua 后 换@huan 必须被排除:
        huan 跨越了 hua|... 的边界;华南@huanan=[hua,nan] 则合法)。"""
        if not locked_sylls or aligned is None:
            return True
        total = sum(len(s) for s in aligned)
        bounds = set()
        acc = 0
        for s in aligned:
            acc += len(s)
            bounds.add(acc)
        pos = 0
        for ls in locked_sylls:
            pos += len(ls)
            if pos >= total:
                break
            if pos not in bounds:
                return False
        return True

    def display_split(self, word, key):
        """候选显示拼音:字对齐切分优先(华纳+huana→hua'na),失败回退贪心(_split_known)。"""
        aligned = self.align_word_pinyin(word, key) if word and key else None
        if aligned:
            return "'".join(aligned)
        return self._split_known(key)

    def _locked_compatible(self, word, key, start, locked_pinyin, bounds):
        """候选(word, key)从拼音位置 start 起铺开,是否兼容锁定音节边界。
        规则:①与锁定拼音重叠部分逐字母一致;②若候选在锁定区内结束,必须停在音节边界;
        ③锁定区内部边界必须是候选字读音对齐后的边界(锁 hua 排除 换@huan:4∉{3})。"""
        L = len(locked_pinyin)
        if start >= L:
            return True
        end = start + len(key)
        p = min(end, L)
        if key[:p - start] != locked_pinyin[start:p]:
            return False
        if end < L and end not in bounds:
            return False
        inner = [b for b in bounds if start < b < end]
        if not inner:
            return True
        aligned = self.align_word_pinyin(word, key)
        if aligned is None:
            return True  # 生僻字对不齐:不强杀(宁多勿漏)
        wb = set()
        acc = start
        for s in aligned:
            acc += len(s)
            wb.add(acc)
        return all(b in wb for b in inner)

    def _locked_bounds(self, locked_sylls):
        """锁定音节栈 → 音节边界位置集合。
        【单键锁定修复】尾项若只是音节前缀而非完整音节(单键 3 点选 d/f、残拼锁 zh 类),
        它只约束"读音从这些字母开始",不构成音节边界——候选读音可越过其末端继续铺开
        (锁 d 后 的@de 合法)。旧实现把前缀末端也当边界,d 后要求边界落在 1 → 无词能配,
        兜底又绕过锁定过滤 → 点选无反应。非尾项保持边界(已被后续点选确认)。"""
        bounds = set()
        acc = 0
        last = len(locked_sylls) - 1
        for i, s in enumerate(locked_sylls):
            acc += len(s)
            if i == last and not self.dict.is_syllable(s):
                continue
            bounds.add(acc)
        return bounds

    def _build_digit_index(self):
        rows = []
        for idx, key in enumerate(self.dict.full.keys):
            dk = "".join(LETTER2DIGIT.get(c, ' ') for c in key)
            if ' ' in dk:
                continue
            rows.append((dk, idx))
        rows.sort()
        self._digit_keys = [r[0] for r in rows]
        self._digit_refs = [r[1] for r in rows]

    def exact_by_digits(self, digits):
        """数字码精确查词:返回 [(word, level, pinyin_key)],跨同码拼音合并。"""
        import bisect
        out = []
        i = bisect.bisect_left(self._digit_keys, digits)
        while i < len(self._digit_keys) and self._digit_keys[i] == digits:
            ref = self._digit_refs[i]
            key = self.dict.full.keys[ref]
            for w, lv in self.dict.full.words_at(ref):
                out.append((w, lv, key))
            i += 1
        return out

    def prefix_by_digits(self, digits, limit):
        """数字码前缀补全:返回 [(word, level, key_digit_len, pinyin_key)](每个更长同前缀码取首选词)。"""
        import bisect
        out = []
        i = bisect.bisect_left(self._digit_keys, digits)
        while i < len(self._digit_keys) and len(out) < limit:
            dk = self._digit_keys[i]
            if not dk.startswith(digits):
                break
            if len(dk) != len(digits):
                ref = self._digit_refs[i]
                ws = self.dict.full.words_at(ref)
                if ws:
                    out.append((ws[0][0], ws[0][1], len(dk), self.dict.full.keys[ref]))
            i += 1
        return out

    # ===== 整句词源也走数字码索引(无 DFS 截断);带拼音 key(整句拼音回溯用) =====
    def top_t9_words(self, seg):
        cached = self.top_words_cache.get(seg)
        if cached is not None:
            return cached
        best = {}
        for w, lv, key in self.exact_by_digits(seg):
            if lv > best.get(w, (-1, ""))[0]:
                best[w] = (lv, key)
        r = sorted(((w, lv, key) for w, (lv, key) in best.items()), key=lambda t: -t[1])[:SENT_TOPK]
        if len(self.top_words_cache) > 8000:
            self.top_words_cache.clear()
        self.top_words_cache[seg] = r
        return r

    # ===== 问题4:用户自造词 =====
    def learn_phrase(self, pinyin, word):
        """用户通过逐词选择组合出的新词(如 耗子尾汁)。词典已有整词则跳过(调频已覆盖)。"""
        if not pinyin or not word or not (2 <= len(word) <= 8):
            return
        if any(w == word for w, _ in self.dict.exact_words(pinyin)):
            return
        m = self.user_words.setdefault(pinyin, {})
        m[word] = m.get(word, 0) + 1
        self.t9_cache.clear()

    def forget_phrase(self, word):
        for m in self.user_words.values():
            m.pop(word, None)

    def _user_word_candidates_26(self, pinyin, n, push):
        """26 键:自造词精确 + 前缀预测(与 custom words 同规则)。"""
        for key, words in self.user_words.items():
            for word, cnt in words.items():
                boost = min(cnt, 5) * LEVEL_W
                if key == pinyin:
                    # 【用户选择记忆】自造词吃下整串输入 → 压过整句(镜像 T9 的 LAYER_SENTENCE 基线;
                    # 曾 LAYER_EXACT=4.2M < 整句 5M,学过的词在 26 键仍被整句压住)
                    push(word, n, LAYER_SENTENCE + 200 * LEVEL_W + boost + self.len_bonus(word))
                elif pinyin.startswith(key):
                    push(word, len(key), LAYER_EXACT + 200 * LEVEL_W + boost + self.len_bonus(word))
                elif n >= 2 and key.startswith(pinyin):
                    push(word, len(key),
                         LAYER_EXACT + 200 * LEVEL_W + boost + self.len_bonus(word) - (len(key) - n) * PEN_MISS)

    def _user_word_candidates_t9(self, digits, n, merged):
        for key, words in self.user_words.items():
            kd = "".join(LETTER2DIGIT.get(c, ' ') for c in key)
            if ' ' in kd:
                continue
            for word, cnt in words.items():
                boost = min(cnt, 5) * LEVEL_W
                if digits.startswith(kd):
                    sc = len(kd) * MATCH_W + LAYER_SENTENCE + 200 * LEVEL_W + boost + self.len_bonus(word)
                    old = merged.get(word)
                    if old is None or sc > old.score:
                        merged[word] = Candidate(word, len(kd), sc, key)
                elif n >= 2 and kd.startswith(digits):
                    # 前缀预测与词层同规则:全消耗 + LAYER_EXACT + 缺失位罚分(对齐 custom words)
                    sc = n * MATCH_W + LAYER_EXACT + (200 + min(cnt, 5)) * LEVEL_W \
                        + self.len_bonus(word) - (len(kd) - n) * PEN_MISS
                    old = merged.get(word)
                    if old is None or sc > old.score:
                        merged[word] = Candidate(word, n, sc, key[:n])

    # ===== 26 键:加自造词层(显示上限放宽,单字层可滚动可达) =====
    def candidates(self, inp, limit=CAND_LIMIT):
        pinyin = inp.replace("'", "")
        if not pinyin:
            return []
        n = len(pinyin)
        base = super().candidates(inp, 100000)  # 池不截断,保底逻辑统一在最终取片处理
        merged = {c.word: c for c in base}

        def push(word, matched_len, score):
            if not word:
                return
            old = merged.get(word)
            if old is None or score > old.score:
                merged[word] = Candidate(word, matched_len, score)

        self._user_word_candidates_26(pinyin, n, push)
        ranked = sorted(merged.values(), key=lambda c: -c.score)
        # 【单字全量可达保底】打全拼音的精确候选(exactWords)绝不被联想潮水挤出候选:
        # 26 键没有拼音选择器,候选列表是唯一通道;top limit 外的精确候选按分序追加
        # (有界:最大音节 137 字)。修「输入 a 打不出 锕」类 2222 个生僻字不可达。
        exact = {w for w, _ in self.dict.exact_words(pinyin)}
        return self._take_with_exact_guarantee(ranked, limit, exact)

    @staticmethod
    def _take_with_exact_guarantee(ranked, limit, exact_words):
        out = ranked[:limit]
        if len(ranked) > limit and exact_words:
            out = out + [c for c in ranked[limit:] if c.word in exact_words]
        return out

    # ===== 问题1核心:T9 重排(全消耗>部分消耗)+ 残段前缀补全 =====
    # locked_sylls:拼音选择器锁定音节栈(切分歧义根治)——词层/补全/整句全部按锁定
    # 边界过滤(锁 hua 排除 换@huan),取代旧"锁定拼音串重查+贪心整句"路径。
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

        # 0)【单键锁定修复】锁定串已覆盖全部数字且尾项只是音节前缀(单键 3 锁 d/f、锁 zh 类):
        #    词层(L>=2)/补全(数字空间在共享键上扫不到目标声母)/锁定单字(须完整音节)全部
        #    无产出,旧实现落进绕过锁定的兜底 → "点了没反应"。此形态语义上等价于
        #    "26 键打了 d 这个前缀" → 直接复用 26 键成熟预测通道(的/都/大),
        #    matchedLen=n:选词一次吃净全部数字与锁定栈。
        if locked and len(locked_pinyin) >= n and not self.dict.is_syllable(locked[-1]):
            preds = self.candidates(locked_pinyin, limit)
            return [Candidate(c.word, n, c.score, c.pinyin) for c in preds]

        # 1) 整句联想(带锁定约束+拼音回溯):全消耗置顶,部分覆盖沉底(镜像 26 键原则)。
        #    top-2 路径:次优整句降 1 个词频级参与排序(最优仍第一,原变体不消失)。
        if n >= 4:
            for rank, (whole, cov, spy) in enumerate(self.sentence_t9(digits, locked_sylls=locked) or []):
                layer = LAYER_SENTENCE if cov >= n else LAYER_SENTENCE_PARTIAL
                put(whole, cov, cov * MATCH_W + layer - rank * LEVEL_W, spy)

        # 2) 简拼(全消耗;锁定态跳过——简拼词无完整读音,无法验证锁定边界)
        if not locked and n <= MAX_T9_WORD_DIGITS:
            for s in self.expand_initials(digits):
                for w, lv in self.dict.initials_exact(s):
                    consider(w, n, LAYER_ABBR, lv, "")

        # 3) 词层:逐前缀精确词(数字码索引直查,无 DFS 截断——修 shangban 丢词)。
        #    全消耗(L==n)精确词加 EXACT_FULL_BONUS:同码时精确永远压过补全。
        max_l = min(n, MAX_T9_WORD_DIGITS)
        for L in range(2, max_l + 1):
            bonus = EXACT_FULL_BONUS if L == n else 0
            for w, lv, key in self.exact_by_digits(digits[:L]):
                if not ok(w, key):
                    continue
                # 【用户选择记忆】全消耗且用户选过(调频>0)的词层基线提到整句之上——
                # 对齐 RIME 动态调频/搜狗智能调频:用户显式选择 > 机器整句猜测。
                # 修「选过 什么鬼 下次默认还是 什么会」类问题(词库词形态)。
                layer = LAYER_SENTENCE if (L == n and self.user_bonus(w) > 0) else LAYER_EXACT
                put(w, L,
                    L * MATCH_W + layer + bonus + lv * LEVEL_W + self.len_bonus(w) + self.user_bonus(w),
                    key)

        # 4) 【新】全消耗前缀补全:数字码前缀直查(youmeiy→有没有、shaow→稍微),
        #    matchedLen=n(消耗全部输入)→ 排在部分消耗词之上;罚分 PEN_MISS 与 26 键一致。
        #    【修 尾@weizhi 被淹没】补全是"预测",业界只置顶少量:全量取回后按调整分
        #    只保留 top COMPLETION_TOP 入池,避免几百个补全词把逐字组词通道的单字挤出候选池。
        if 2 <= n <= MAX_T9_WORD_DIGITS:
            comps = []
            for w, lv, klen, key in self.prefix_by_digits(digits, 200):
                if not ok(w, key):
                    continue
                adj = lv * LEVEL_W + self.len_bonus(w) + self.user_bonus(w) - (klen - n) * PEN_MISS
                comps.append((adj, w, key))
            comps.sort(key=lambda t: -t[0])
            for adj, w, key in comps[:COMPLETION_TOP]:
                put(w, n, n * MATCH_W + LAYER_EXACT + adj, key)

        # 5) 自造词 + 内置自定义词(锁定边界同样约束)
        self._user_word_candidates_t9(digits, n, merged)
        for word, py, cw_digits, freq in self.custom_words:
            if not ok(word, py):
                continue
            if digits.startswith(cw_digits):
                sc = len(cw_digits) * MATCH_W + LAYER_SENTENCE + freq * LEVEL_W + self.len_bonus(word)
                put(word, len(cw_digits), sc, py)
            elif n >= 2 and cw_digits.startswith(digits):
                sc = n * MATCH_W + LAYER_ABBR_PREFIX + freq
                put(word, n, sc, py)

        # 5b) 锁定态:首锁定音节单字置入(逐字组词通道:锁 hua 必能点出 花/话/华)
        if locked:
            first = locked[0]
            for w, lv in self.dict.exact_words(first):
                put(w, len(first), len(first) * MATCH_W + LAYER_SINGLE + lv * LEVEL_W + self.user_bonus(w), first)

        # 6) 兜底:最长可成前缀 → 半音节纯汉字续词。
        # 【单键锁定修复】兜底同样尊重锁定过滤——旧实现绕过 ok(),锁 d 后兜底把默认
        # e 字集原样塞回,候选与未锁定完全一致,这就是"点了没反应"的最后一环。
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
            # 【单键锁定修复】半音节续词兜底同样带锁定过滤(77 锁 q 不得回吐 p/r/s 词)
            self._append_partial_chinese(digits, merged, ok if locked else None)
        ranked = sorted(merged.values(), key=lambda c: -c.score)
        # 【单字全量可达保底】整串数字码的精确候选(锁定过滤后)绝不被截出池
        return self._take_with_exact_guarantee(ranked, limit, self._t9_exact_set(digits, locked))

    def _append_partial_chinese(self, digits, merged, ok=None):
        """覆写 engine.py 版本:支持锁定过滤(ok);其余逻辑一致。"""
        segs, covered = self.best_t9_seg_partial(digits)
        covered_pinyin = "".join(segs)

        def put(w, mlen, score, py):
            if not w:
                return
            if ok is not None and not ok(w, py):
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

    # ===== 整句:末段残段补全 + 锁定约束 + 拼音回溯 =====
    # 返回 (句子, 覆盖位数, 拼音key串)。拼音回溯:整句候选不再是"无读音黑箱"——
    # 显示拼音跟随 #1 候选时,话那么多钱→hua'na'me'duo'qian(修 ne 幻觉:旧
    # bestT9SegPartial 按音节频率瞎猜出词典中不存在的 hua|na|ne|duo|qian)。
    def sentence_t9(self, digits, locked_sylls=None):
        raw = len(digits)
        if raw < 4:
            return None
        locked = locked_sylls or []
        locked_pinyin = "".join(locked)
        bounds = self._locked_bounds(locked)
        n = min(raw, MAX_T9_SENTENCE)
        # 锁定边界也是词的合法起点约束:词不能跨越锁定音节边界起步错位
        dp = [dict() for _ in range(n + 1)]
        dp[0][""] = (0, -1, "", "")
        for i in range(1, n + 1):
            cand = {}

            def relax(w, base, j, key):
                # 锁定约束:词铺在拼音区间 [j, j+len(key));与锁定边界/字母冲突则弃
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
                # 【新】末段残段:i==n 且该段无精确词时,前缀补全参与整句(youmeiy 的"有"、
                # woxiangch 的"吃")。取最优补全词,缺失位数微罚(对齐 26 键 *8)。
                if i == n and j > 0 and not self.top_t9_words(digits[j:i]):
                    comp = None
                    for w, lv, klen, key in self.prefix_by_digits(digits[j:i], 30):
                        adj = lv - (klen - (i - j)) * 8
                        if comp is None or adj > comp[1]:
                            comp = (w, adj, key)
                    if comp:
                        relax(comp[0], comp[1] - SENT_PEN, j, comp[2][:i - j])
            # 自造词/自定义词跳转
            for key, words in self.user_words.items():
                kd = "".join(LETTER2DIGIT.get(c, ' ') for c in key)
                if ' ' in kd:
                    continue
                ln = len(kd)
                if i >= ln and dp[i - ln] and digits[i - ln:i] == kd:
                    for word, cnt in words.items():
                        relax(word, (200 + min(cnt, 5)) * LEVEL_W, i - ln, key)
            for word, py, cw_digits, freq in self.custom_words:
                ln = len(cw_digits)
                if i >= ln and dp[i - ln] and digits[i - ln:i] == cw_digits:
                    relax(word, freq * LEVEL_W, i - ln, py)
            # 【错键容忍,对齐 Gboard 插入错误解码】把第 i-1 位当"误触"跳过:状态原样
            # 前移一位、重罚 GAP_PEN(>任何成词收益,正常输入永不偏好跳过)。修「连敲错
            # 几个键后候选/拼音永久冻结,需狂按回退」——垃圾段后的合法输入重新参与解码,
            # matchedLen 含跳过位 → 选词一次性吃掉误触数字。锁定前缀区内禁止跳过
            # (用户显式确认过的读音不可当误触)。
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
        # 【整句 top-2】输出最优+次优两条整句路径(dp 本就保留 SENT_TOPK 状态)。
        # 修「学会 什么鬼 后原整句 什么会 彻底消失」:用户словари/学习翻转 #1 时,
        # 原整句仍作为次优候选可选(对齐搜狗整句变体)。
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
                if w:  # 错键容忍的空态载体(头部垃圾段)不产出词
                    parts.append(w)
                    keys.append(st[3])
                i = st[1]
                w = st[2]
            if broken or not parts:
                continue
            # 跳过位数 = 覆盖位数 - 各词拼音位数之和;有跳过时允许单词句
            # (77+你好:垃圾头+单词也要能出候选并吃掉垃圾),纯净路径仍要求 ≥2 词。
            gaps = cov - sum(len(k) for k in keys)
            if len(parts) < 2 and gaps <= 0:
                continue
            whole = "".join(reversed(parts))
            if whole in seen:
                continue
            seen.add(whole)
            results.append((whole, cov, "".join(reversed(keys))))
        return results or None

    # ===== 候选池放宽(修"尾@weizhi 排 60 被截"):池 300、显示 200,渲染轻量无压力 =====
    def _t9_exact_set(self, digits, locked=None):
        """整串数字码的精确候选词集合(锁定态按边界过滤)——全量可达保底用。"""
        locked = locked or []
        locked_pinyin = "".join(locked)
        bounds = self._locked_bounds(locked)
        out = set()
        for w, _, key in self.exact_by_digits(digits):
            if not locked or self._locked_compatible(w, key, 0, locked_pinyin, bounds):
                out.add(w)
        # 锁定态逐字组词通道:首锁定音节单字同样保底(锁 yi 必能点出 咦)
        if locked:
            out.update(w for w, _ in self.dict.exact_words(locked[0]))
        return out

    def candidates_for_t9(self, digits, limit=CAND_LIMIT):
        key = digits
        cached = self.t9_cache.get(key)
        if cached is None:
            cached = self.candidates_t9(digits, T9_POOL)
            self.t9_cache[key] = cached
        return self._take_with_exact_guarantee(cached, limit, self._t9_exact_set(digits))

    # ===== 锁定态(切分歧义根治重写):不再"锁定拼音串+贪心剩余段重查",而是
    # 在**数字空间全量检索**(与非锁定态同一通道)+ 锁定音节边界过滤。
    # 锁 hua 后:换@huan 被边界过滤掉,话那么多钱@hua... 保留 → 候选与用户意图一致。
    def candidates_for_t9_filtered(self, digits, locked_pinyin, limit=CAND_LIMIT, locked_sylls=None):
        if not locked_pinyin:
            return self.candidates_for_t9(digits, limit)
        # 锁定音节栈:调用方(Controller)直接传;兼容旧签名时按贪心拆(测试用)
        locked = locked_sylls if locked_sylls is not None else self._greedy_sylls(locked_pinyin)
        key = (digits, tuple(locked))
        cached = self.t9_cache.get(key)
        if cached is None:
            cached = self.candidates_t9(digits, T9_POOL, locked_sylls=locked)
            if len(self.t9_cache) > 64:
                self.t9_cache.clear()
            self.t9_cache[key] = cached
        return self._take_with_exact_guarantee(cached, limit, self._t9_exact_set(digits, locked))

    # ===== 拼音选择器选项(镜像 Kotlin t9LeadingOptions,任务1脚本验证用)=====
    # 整段完整音节全部保留、排最前;短前导音节按(频率,段长)补足;
    # 首位数字的合法单字母前缀(d/f 类)垫底——它们正是"单键锁定"的入口。
    def t9_leading_options(self, digits, max_seg=3, limit=8):
        if not digits:
            return []
        full_len = min(max_seg, len(digits))
        seen = set()
        fulls = []
        shorts = []
        for L in range(full_len, 0, -1):
            for exp in self.expand_full_pinyin(digits[:L]):
                if self.dict.is_syllable(exp) and exp not in seen:
                    seen.add(exp)
                    ws = self.dict.exact_words(exp)
                    lv = ws[0][1] if ws else -1
                    if L == full_len:
                        fulls.append((exp, lv))
                    else:
                        shorts.append((exp, L, lv))
        for c in T9.get(digits[0], ""):
            if self.dict.is_syllable_prefix(c) and c not in seen:
                seen.add(c)
                shorts.append((c, 1, -2))
        fulls.sort(key=lambda t: -t[1])
        shorts.sort(key=lambda t: (-t[2], -t[1]))
        return ([f[0] for f in fulls] + [s[0] for s in shorts])[:limit]

    def _greedy_sylls(self, py):
        parts = []
        i = 0
        while i < len(py):
            m = 0
            for L in range(min(self.dict.max_syllable_len, len(py) - i), 0, -1):
                if self.dict.is_syllable(py[i:i + L]):
                    m = L
                    break
            if m == 0:
                break
            parts.append(py[i:i + m])
            i += m
        return parts

    # ===== 显示拼音:跟随 #1 候选 + 字对齐切分(华纳→hua'na 而非 huan'a) =====
    def t9_display_pinyin(self, digits):
        if not digits:
            return digits
        cands = self.candidates_for_t9(digits, 60)
        if cands and cands[0].pinyin:
            return self.display_split(cands[0].word, cands[0].pinyin)
        segs, covered = self.best_t9_seg_partial(digits)
        parts = list(segs)
        for idx in range(covered, len(digits)):
            parts.append(self._default_letter(digits[idx]))
        return "'".join(parts)

    def t9_display_filtered(self, digits, locked_pinyin, locked_sylls=None):
        """锁定态显示:锁定段按用户点选音节显示,剩余段跟随 #1 候选读音。"""
        if not digits:
            return digits
        if not locked_pinyin:
            return self.t9_display_pinyin(digits)
        # 【单键锁定修复】全部数字都被锁定覆盖:组合区忠实显示用户点选(锁 d 显示 d,
        # 而非 #1 补全候选的完整读音 de——用户显式点选优先于机器预测)。
        if len(locked_pinyin) >= len(digits):
            return "'".join(locked_sylls if locked_sylls is not None else self._greedy_sylls(locked_pinyin))
        locked = locked_sylls if locked_sylls is not None else self._greedy_sylls(locked_pinyin)
        cands = self.candidates_for_t9_filtered(digits, locked_pinyin, 1, locked_sylls=locked)
        if cands and cands[0].pinyin and len(cands[0].pinyin) > len(locked_pinyin):
            rest_disp = self.display_split(cands[0].word, cands[0].pinyin)
            return rest_disp
        remain = digits[len(locked_pinyin):] if len(locked_pinyin) < len(digits) else ""
        remain_disp = self.t9_display_pinyin(remain) if remain else ""
        locked_disp = "'".join(locked)
        return "'".join(p for p in (locked_disp, remain_disp) if p)


def load_engine_v2():
    base = load_engine()
    return EngineV2(base.dict)
