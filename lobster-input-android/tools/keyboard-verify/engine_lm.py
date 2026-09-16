# -*- coding: utf-8 -*-
"""EngineV3 + 字bigram 语言模型:重写 sentence_t9,整句打分叠加字级 bigram 链分。

整句总分 = Σ(词频 lv - SENT_PEN) + 用户bigram + LM_ALPHA × Σ字对 bigram 分。
LM 提供跨词/词内上下文,裁决"搬过来 vs 包裹来"这类同码歧义。
其余通道(候选栏 candidates_t9、词层、模糊等)完全继承 V3,不动。
"""
import os

from engine import LETTER2DIGIT, LEVEL_W, USER_CAP
from engine_v2 import GAP_PEN
from engine_v3 import EngineV3, load_engine_v3, DEFAULT_CUSTOM
import engine as _eng
from char_lm import CharBigramLM, OOV_SCORE

SENT_PEN = _eng.SENT_PEN
BIGRAM_W = _eng.BIGRAM_W
SENT_TOPK = _eng.SENT_TOPK
MAX_T9_SEG = _eng.MAX_T9_SEG
MAX_T9_SENTENCE = _eng.MAX_T9_SENTENCE

# LM 打分(最终模型:**只否决 OOV/极罕见字对**,不奖励常见搭配):
#  经验教训——奖励常见跨词搭配会引入语料偏置(民→事/河北/称→赞"堪称赞美"),把正确的
#  罕见搭配(称→完"堪称完美")挤掉。而"从未在真实文本出现的字对"(裹→来)才是可靠的
#  "不可能搭配"信号。故 LM 唯一职责 = 罚掉 OOV/极罕见边界,见过的搭配一律不干预(交给词频)。
#  这样天然无正向偏置:所有"高频但错"的组合都是见过的 → LM 不碰 → 词频裁决。
# ============ LM 打分(最终:词bigram 条件对数概率(中心化)为主 + 字bigram veto 兜底)============
#  正确的 LM 数学:整句分 += log P(w|pw)(概率,负值)。奖励边界=激励过分段(垃圾汤),错;
#  必须中心化:word_delta = clamp((条件对数概率 - WREF)*WBETA, -WLO, +WHI):
#   常见转移(≈平均)→ ~0 不干预(不奖励垃圾单字对);突出好搭配(堪称→完美,远高于均)→ 小正;
#   罕见/劣搭配 → 小负。词级分辨率修好"堪称完美/人民是"(字级修不了)。
#  词bigram未覆盖的词对 → 回退字级 OOV veto(只罚不奖,否决"想→??"里从未出现的字搭配)。
WREF = -700         # 词条件对数概率参考(约中等转移);高于它=好搭配
WBETA = 0.13        # 词delta斜率
WHI = 55            # 词delta正激励上限(突出好搭配)
WLO = 40            # 词delta负罚上限
LM_REF = -520       # 字veto:高于此不罚
LM_BETA = 0.16      # 字veto斜率
LM_LO = 70          # 字veto单边界最大罚
FUZZY_LV_PEN = 130  # 模糊命中词频折算罚分(字面pass;近乎排除模糊)
FUZZY_BOOST = 60    # 模糊pass对模糊词的探索奖励(让纠正句能被DP找到,再由相干性把关)
COH_MARGIN = 250    # 纠正句相干性需比字面句高出此值才注入(显著更通顺)
COH_LITERAL_MAX = -700 * 3  # 字面句本身够通顺(相干性高于此)则不纠错(避免打对被纠)


class EngineLM(EngineV3):
    def __init__(self, dictionary, custom_path=DEFAULT_CUSTOM, lm_path=None, patches=None):
        super().__init__(dictionary, custom_path, patches)
        self.lm = CharBigramLM()      # 字bigram(兜底veto)
        self.wb = {}                  # 词bigram {w1:{w2:条件对数概率}}(主信号)
        if lm_path:
            self.lm.load(lm_path)
        self._lm_internal_cache = {}

    def set_lm(self, lm):
        self.lm = lm
        self._lm_internal_cache = {}
        return self

    def set_wb(self, wb):
        self.wb = wb
        return self

    def word_delta(self, pw, w):
        """词转移中心化 delta;未覆盖返回 None(交给字veto)。"""
        d = self.wb.get(pw)
        if not d:
            return None
        b = d.get(w)
        if b is None:
            return None
        x = (b - WREF) * WBETA
        if x > WHI:
            return WHI
        if x < -WLO:
            return -WLO
        return x

    def char_veto(self, prev_last, cur_first):
        d = self.lm.table.get(prev_last)
        if d is None:
            return -LM_LO
        wv = d.get(cur_first)
        if wv is None:
            return -LM_LO
        x = (wv - LM_REF) * LM_BETA
        if x >= 0:
            return 0
        return x if x > -LM_LO else -LM_LO

    def boundary_bonus(self, prev_last, cur_first):
        return self.char_veto(prev_last, cur_first)

    # ============ 模糊音整句解码(2b:平翘舌/前后鼻音自动纠错)============
    #  T9 平翘舌/前后鼻音是"删除型":用户打 ci(24) 想要 chi(244)。给词建"约简数字键"索引
    #  (chi→去h→ci→24;bang→去g→ban→226),整句 DP 每段同时查精确+模糊词。模糊词带 FUZZY_PEN
    #  罚分(字面永远优先)+ 携带真实拼音(chi)供组合区在错字上标注。只有 LM 判定通顺时模糊才上位。
    def _fuzzy_variants_py(self, py):
        out = []
        for a, b in (("zh", "z"), ("ch", "c"), ("sh", "s")):
            if py.startswith(a):
                out.append(b + py[len(a):])
        for a, b in (("ang", "an"), ("eng", "en"), ("ing", "in")):
            if py.endswith(a):
                out.append(py[:-len(a)] + b)
        return out

    def build_fuzzy_index(self, max_word_lv=0):
        """约简数字键 -> [(word, real_pinyin, real_lv)]。单字 + 主词库词(2字为主,高频)。"""
        from engine import LETTER2DIGIT as L2D
        idx = {}
        def add(word, py, lv):
            for red in self._fuzzy_variants_py(py):
                rdk = "".join(L2D.get(c, "") for c in red)
                real_dk = "".join(L2D.get(c, "") for c in py)
                if not rdk or not all(c.isdigit() for c in rdk) or rdk == real_dk:
                    continue
                idx.setdefault(rdk, []).append((word, py, lv))
        # 单字(char_readings + 单字频率)
        for ch, readings in self.dict.char_readings.items():
            for r in readings:
                lv = 0
                for w, l in self.dict.exact_words(r):
                    if w == ch:
                        lv = l
                        break
                add(ch, r, lv)
        # 主词库 2-3 字词(有平翘舌/鼻音声韵的才有变体;高频优先)
        for i in range(len(self.dict.full.keys)):
            key = self.dict.full.keys[i]
            if not (4 <= len(key) <= 8):  # 约 2-3 字词的拼音长度
                continue
            ws = self.dict.full.words_at(i)
            if not ws:
                continue
            w, lv = ws[0]
            if 2 <= len(w) <= 3 and lv >= 120:
                add(w, key, lv)
        # 每键按 lv 降序、限量
        for k in idx:
            idx[k] = sorted(set(idx[k]), key=lambda t: -t[2])[:6]
        self.fuzzy_index = idx
        return idx

    def top_t9_words_fuzzy(self, seg):
        """精确词 + 模糊词(带真实拼音,lv 扣 FUZZY_LV_PEN 折算罚分)。返回 (w, lv, key, is_fuzzy)。"""
        out = [(w, lv, key, False) for w, lv, key in self.top_t9_words(seg)]
        fi = getattr(self, "fuzzy_index", None)
        if fi:
            for w, py, lv in fi.get(seg, ()):
                out.append((w, max(1, lv - FUZZY_LV_PEN), py, True))
        return out

    # ============ 2b 独立模糊纠错候选(不碰主DP;搜狗式"您是不是想输入")============
    #  主DP出字面句(候选#1不变)。另跑一条**偏好模糊**的解析得纠正句,用 LM 句子相干性
    #  (相邻字对 char-bigram 分之和)比较字面句 vs 纠正句:仅当纠正句相干性显著更高
    #  (COH_MARGIN)且字面句本身不够通顺时,纠正句作为**带真实拼音标注**的候选注入 top(限1-3)。
    #  这样"你ci饭"(字面垃圾)→注入"你吃饭";"次数"(字面通顺)→纠正不上位。字面永远在候选里。
    def sentence_coherence(self, s):
        if not self.lm.loaded or len(s) < 2:
            return 0
        return sum(self.lm.score(s[k], s[k + 1]) for k in range(len(s) - 1))

    def _sentence_dp(self, digits, prefer_fuzzy):
        """整句 DP;prefer_fuzzy=True 时模糊词不扣罚分(得到"如果全按模糊纠正"的最优句)。"""
        n = len(digits)
        if n < 4:
            return None
        dp = [dict() for _ in range(n + 1)]
        dp[0][""] = (0, -1, "", "")
        has_lm = self.lm.loaded
        for i in range(1, n + 1):
            cand = {}

            def relax(w, base, j, key):
                for pw, st in dp[j].items():
                    g = base
                    if pw:
                        if has_lm:
                            wd = self.word_delta(pw, w)
                            g += wd if wd is not None else self.char_veto(pw[-1], w[0])
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
                # 精确词
                for w, lv, key in self.top_t9_words(digits[j:i]):
                    relax(w, lv - SENT_PEN, j, key)
                # 模糊词:字面pass扣满罚(几乎不参与);模糊pass用真实lv+奖励(主动探索纠正句)
                fi = getattr(self, "fuzzy_index", None)
                if fi:
                    for w, py, lv in fi.get(digits[j:i], ()):
                        if prefer_fuzzy:
                            relax(w, lv + FUZZY_BOOST - SENT_PEN, j, py)
                        else:
                            relax(w, lv - FUZZY_LV_PEN - SENT_PEN, j, py)
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
        parts, keys, i = [], [], cov
        while i > 0:
            st = dp[i].get(w)
            if st is None:
                return None
            if w:
                parts.append(w)
                keys.append(st[3])
            i = st[1]
            w = st[2]
        if not parts:
            return None
        return "".join(reversed(parts)), cov, "".join(reversed(keys))

    def fuzzy_correction(self, digits):
        """返回 (纠正句, 纠正拼音) 若显著比字面句通顺,否则 None。供候选注入+标注。"""
        if not getattr(self, "fuzzy_index", None) or not self.lm.loaded or len(digits) < 4:
            return None
        literal = self._sentence_dp(digits, prefer_fuzzy=False)
        fuzzy = self._sentence_dp(digits, prefer_fuzzy=True)
        if not literal or not fuzzy:
            return None
        if fuzzy[0] == literal[0]:
            return None
        # 覆盖需一致(都覆盖全串),且纠正句相干性显著更高、字面句本身不够通顺
        if literal[1] != fuzzy[1]:
            return None
        coh_lit = self.sentence_coherence(literal[0])
        coh_fuz = self.sentence_coherence(fuzzy[0])
        if coh_fuz - coh_lit >= COH_MARGIN and coh_lit <= COH_LITERAL_MAX:
            return fuzzy[0], fuzzy[2]
        return None

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
        lm = self.lm
        has_lm = lm.loaded
        for i in range(1, n + 1):
            cand = {}

            def relax(w, base, j, key):
                if locked and not self._locked_compatible(w, key, j, locked_pinyin, bounds):
                    return
                for pw, st in dp[j].items():
                    g = base
                    if pw:
                        if has_lm:
                            wd = self.word_delta(pw, w)
                            g += wd if wd is not None else self.char_veto(pw[-1], w[0])
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
            # 自造词跳转
            for key, words in self.user_words.items():
                kd = "".join(LETTER2DIGIT.get(c, " ") for c in key)
                if " " in kd:
                    continue
                ln = len(kd)
                if i >= ln and dp[i - ln] and digits[i - ln:i] == kd:
                    for word, cnt in words.items():
                        relax(word, (200 + min(cnt, 5)) * LEVEL_W, i - ln, key)
            # 错键容忍
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


_lm_shared = None


def load_word_bigram(path):
    wb = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) < 2:
                continue
            toks = p[1].split(" ")
            d = {}
            for i in range(0, len(toks) - 1, 2):
                d[toks[i]] = int(toks[i + 1])
            wb[p[0]] = d
    return wb


# 默认取已入库的线上资产(assets/char_bigram.txt、word_bigram.txt),与三端同源、随仓库可复现。
_ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "app", "src", "main", "assets")
DEFAULT_CHAR_LM = os.environ.get("CHAR_LM", os.path.join(_ASSETS, "char_bigram.txt"))
DEFAULT_WORD_LM = os.environ.get("WORD_LM", os.path.join(_ASSETS, "word_bigram.txt"))


def load_engine_lm(custom_path=DEFAULT_CUSTOM, lm_path=None, char_path=None, word_path=None):
    from engine import load_engine
    from engine_v2 import EngineV2
    from engine_v3 import CustomTable, _custom_cache
    base = load_engine()
    eng = EngineLM.__new__(EngineLM)
    EngineV2.__init__(eng, base.dict)
    eng.custom_words = []
    cached = _custom_cache.get(custom_path)
    if cached is None:
        cached = CustomTable()
        cached.load(custom_path)
        _custom_cache[custom_path] = cached
    eng.custom = cached
    eng.lm = CharBigramLM()
    cp = char_path or lm_path or DEFAULT_CHAR_LM
    if cp and os.path.exists(cp):
        eng.lm.load(cp)
    eng.wb = {}
    wp = word_path or DEFAULT_WORD_LM
    if wp and os.path.exists(wp):
        eng.wb = load_word_bigram(wp)
    eng._lm_internal_cache = {}
    return eng
