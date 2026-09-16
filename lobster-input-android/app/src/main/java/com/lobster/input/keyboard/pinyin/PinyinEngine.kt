package com.lobster.input.keyboard.pinyin

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.lobster.input.keyboard.pinyin.HotwordDictionaryBridge.importInto
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * 一个拼音候选词。matchedLen = 该候选消耗的输入字符数。isEmoji:emoji 联想候选(选中不写词典)。
 * isSymbol:9 宫格 1 键的高频符号候选(选中按智能配对上屏,不写词典、不改联想链)。
 * isPunct:候选栏标点联想(2026-07-23),选中直接上屏(不配对)、不学习、不改联想链;
 * 与 isSymbol 严格隔离——不参与候选栏两侧收起契约、不触发 SmartPunctuation 配对。
 */
data class Candidate(val word: String, val matchedLen: Int, val score: Int, val isEmoji: Boolean = false, val pinyin: String = "", val isSymbol: Boolean = false, val isPunct: Boolean = false)

/**
 * 拼音引擎(算法层)。组合 [PinyinDictionary] 与 [UserDictionary]。
 * 加载完成后通过 [PinyinLoadListener] 通知 UI(主线程)。
 */
class PinyinEngine(private val appContext: Context) {

    private val dict = PinyinDictionary()
    private val customDict = CustomDictionary()
    private val sentenceLm = SentenceLanguageModel()
    private val userDict = UserDictionary(appContext)
    @Volatile private var fuzzy = PinyinFuzzy.Settings()
    private val loading = AtomicBoolean(false)
    private val loadState = AtomicReference(PinyinLoadState.IDLE)
    private val listeners = CopyOnWriteArrayList<PinyinLoadListener>()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun isReady(): Boolean = dict.isReady

    fun loadState(): PinyinLoadState = loadState.get()

    fun addLoadListener(listener: PinyinLoadListener) {
        listeners.add(listener)
        listener.onLoadStateChanged(loadState.get(), null)
    }

    fun removeLoadListener(listener: PinyinLoadListener) {
        listeners.remove(listener)
    }

    fun loadAsync() {
        if (!loading.compareAndSet(false, true)) return
        notifyState(PinyinLoadState.LOADING, null)
        Thread {
            val result = runCatching {
                dict.load(appContext)
                userDict.load()
                importInto(userDict, appContext)
            }
            loading.set(false)
            if (result.isSuccess && dict.isReady) {
                notifyState(PinyinLoadState.READY, null)
                // 海量内置自定义词库(custom_dict v2,61 万词)READY 后异步挂载:
                // 不阻塞键盘可用,挂载前查询按空表返回;挂载完成后在主线程失效 T9 缓存
                // (缓存与引擎查询同在主线程使用,避免跨线程清缓存竞态)。
                runCatching { customDict.load(appContext) }
                // 整句语言模型(词/字 bigram)READY 后异步挂载:修"打对拼音出弱智句";
                // 挂载前 boundaryScore 返回 0(退化为原词频整句),挂载完失效 T9 缓存。
                runCatching { sentenceLm.load(appContext) }
                mainHandler.post { t9CacheKey = null; topWordsCache.clear() }
            } else {
                notifyState(PinyinLoadState.FAILED, result.exceptionOrNull()?.message)
            }
        }.apply { isDaemon = true; name = "pinyin-dict-loader" }.also { it.start() }
    }

    private fun notifyState(state: PinyinLoadState, detail: String?) {
        loadState.set(state)
        mainHandler.post {
            for (l in listeners) l.onLoadStateChanged(state, detail)
        }
    }

    fun displaySegmented(input: String): String = dict.displaySegmented(input)
    fun learn(word: String) = userDict.learn(word)
    fun setFuzzy(settings: PinyinFuzzy.Settings) { fuzzy = settings }
    fun forget(word: String) = userDict.forget(word)

    private fun userBonus(word: String): Int = minOf(userDict.bonus(word), USER_CAP) * USER_WEIGHT
    private fun lenBonus(word: String): Int = (minOf(word.length, 5) - 1) * LEN_W
    private fun layerScore(layer: Int, level: Int, word: String, penalty: Int = 0): Int =
        layer + level * LEVEL_W + lenBonus(word) - penalty + userBonus(word)

    fun associations(prev: String, limit: Int = 12): List<Candidate> {
        // 用户自学习优先(个性化),内置 bigram 兜底(冷启动不为空),去重保序。
        val merged = LinkedHashSet<String>()
        merged.addAll(userDict.nextWords(prev))
        merged.addAll(BuiltinPrediction.nextWords(prev))
        return merged.take(limit).mapIndexed { i, w -> Candidate(w, 0, ASSOC_BASE - i) }
    }

    fun learnSequence(prev: String?, word: String) {
        userDict.learn(word)
        if (!prev.isNullOrEmpty()) userDict.learnPair(prev, word)
        // 学习立刻生效:清 T9 结果缓存(bigram 影响整句),下次同串重算
        t9CacheKey = null
    }

    /**
     * 用户自造词学习(问题4:耗子尾汁类)。用户对同一拼音串逐词/逐字组合选完后,
     * 由控制层把「整串拼音 + 组合出的词」学进用户词典;下次输入同拼音(26 键或 T9)直接出整词。
     * 词库已有整词则跳过(调频已覆盖);拼音必须可完整切分(护栏,与自定义词同规则)。
     */
    fun learnPhrase(pinyin: String, word: String) {
        if (pinyin.isEmpty() || word.length !in 2..8) return
        if (!allValidSyllables(pinyin)) return
        if (dict.exactWords(pinyin).any { it.first == word }) return
        val digits = pinyin.map { letter2digit[it] ?: return }.joinToString("")
        userDict.learnPhrase(pinyin, digits, word)
        t9CacheKey = null
    }

    /**
     * 26 键候选(业界对齐排序,已本地脚本电池验证:完整拼音错误率 26/30→1/30)。
     * 总原则:**消耗全部已输入字母的候选 > 忽略尾部字母的候选**。
     *  - 词层 = 整词精确 + 前缀补全(每缺失字母罚 PEN_MISS):youmeiy→有没有、dianhu→电话。
     *  - 整句只有消耗全部输入且无整词可覆盖时才置顶(修 nihao→"你哈哦" 压过 你好);
     *    部分覆盖(如 youmeiy 的"有没")沉到所有全消耗层之下。
     *  - 同词去重保最高分(避免 有没有 以不同 matchedLen 重复出现)。
     */
    fun candidates(input: String, limit: Int = CAND_LIMIT): List<Candidate> {
        if (!dict.isReady) return emptyList()
        val pinyin = input.filter { it != '\'' }
        if (pinyin.isEmpty()) return emptyList()
        val n = pinyin.length

        val merged = HashMap<String, Candidate>()
        fun push(word: String, matchedLen: Int, score: Int) {
            if (word.isEmpty()) return
            val old = merged[word]
            if (old == null || score > old.score) merged[word] = Candidate(word, matchedLen, score)
        }

        // 词层:整词精确 + 前缀补全。高频补全(电话)可胜低频精确词(电弧),缺得越多罚越重。
        val exacts = dict.exactWords(pinyin)
        val prefixes = dict.prefixWords(pinyin, 400)
        // 自定义词(custom_dict v2):精确与主词库同层同权;前缀补全同罚分。
        val cExacts = customDict.exactWords(pinyin)
        val cPrefixes = if (n >= 2) customDict.prefixWords(pinyin, 200) else emptyList()
        // hasFullWord 计入自定义词:只有自定义词能整词覆盖时,整句不得抢 LAYER_SENTENCE 置顶。
        val hasFullWord = exacts.isNotEmpty() || prefixes.isNotEmpty() || cExacts.isNotEmpty() || cPrefixes.isNotEmpty()
        for ((w, lv) in exacts) push(w, n, layerScore(LAYER_EXACT, lv, w))
        for ((w, lv, klen) in prefixes) push(w, klen, layerScore(LAYER_EXACT, lv, w, (klen - n) * PEN_MISS))
        for ((w, lv) in cExacts) push(w, n, layerScore(LAYER_EXACT, lv, w))
        for ((w, lv, klen) in cPrefixes) {
            // 低置信长尾词(lv<110)不做预测(打全才出):防弱补全把部分消耗高频词挤出前排
            if (lv < CUSTOM_COMPLETION_MIN_LV) continue
            push(w, klen, layerScore(LAYER_EXACT, lv, w, (klen - n) * PEN_MISS))
        }

        sentenceCandidate(pinyin)?.let {
            val layer = when {
                it.matchedLen >= n && !hasFullWord -> LAYER_SENTENCE       // 长句无整词:整句置顶
                it.matchedLen >= n -> LAYER_SENTENCE_FULL                  // 有整词:整句居次
                else -> LAYER_SENTENCE_PARTIAL                             // 忽略尾字母:沉底于全消耗层
            }
            push(it.word, it.matchedLen, layer + maxOf(it.score, 0))
        }

        for ((w, lv) in dict.initialsExact(pinyin)) push(w, n, layerScore(LAYER_ABBR, lv, w))
        for ((w, lv, klen) in dict.initialsPrefix(pinyin, 60)) {
            push(w, klen, layerScore(LAYER_ABBR_PREFIX, lv, w, (klen - n) * 15))
        }
        val firstSyl = dict.splitSyllables(pinyin).firstOrNull()
        if (firstSyl != null && firstSyl != pinyin && dict.isSyllable(firstSyl)) {
            for ((w, lv) in dict.exactWords(firstSyl)) if (w.length == 1) {
                push(w, firstSyl.length, layerScore(LAYER_SINGLE, lv, w))
            }
        }
        // 模糊音/纠错隔离:即便其内部出现异常也绝不影响已生成的基础候选(防"候选突然全空")。
        runCatching { fuzzyCandidates(pinyin) { w, lv -> push(w, n, layerScore(LAYER_FUZZY, lv, w)) } }
        runCatching { if (merged.size < 3) correctionCandidates(pinyin) { w, lv -> push(w, n, layerScore(LAYER_CORRECTION, lv, w)) } }
        // 用户自造词(耗子尾汁类,逐词组合学得):同自定义词规则,PHRASE_FREQ 保证学过必出。
        // 【用户选择记忆】自造词吃下整串输入 → 压过整句(LAYER_SENTENCE 基线,镜像 T9;
        // 曾 LAYER_EXACT=4.2M < 整句 5M,学过的组合在 26 键仍被整句压住)。
        userDict.eachPhrase { ppy, _, word, cnt ->
            val boost = minOf(cnt, 5) * LEVEL_W
            when {
                ppy == pinyin -> push(word, n, LAYER_SENTENCE + PHRASE_FREQ * LEVEL_W + boost + lenBonus(word))
                pinyin.startsWith(ppy) -> push(word, ppy.length, LAYER_EXACT + PHRASE_FREQ * LEVEL_W + boost + lenBonus(word))
                n >= 2 && ppy.startsWith(pinyin) ->
                    push(word, ppy.length, LAYER_EXACT + PHRASE_FREQ * LEVEL_W + boost + lenBonus(word) - (ppy.length - n) * PEN_MISS)
            }
        }
        // 分段兜底 + 字面兜底(已本地脚本验证):保证候选栏永不空白。
        if (merged.size < 2) runCatching { segmentedFallback(pinyin) { w, len, sc -> push(w, len, sc) } }
        if (merged.isEmpty()) push(pinyin, n, LAYER_SINGLE - 1) // 字面兜底:输入串自身可上屏,分数垫底
        val ranked = merged.values.filter { !userDict.isBlacklisted(it.word) }.sortedByDescending { it.score }
        // 【单字全量可达保底】打全拼音的精确候选绝不被联想潮水挤出(26 键无拼音选择器,
        // 候选列表是唯一通道;修「输入 a 打不出 锕」类生僻字不可达,本地脚本全音节扫描验证)。
        // 保底集并入自定义精确词:自定义词打全同样必可达。
        val exactSet = exacts.mapTo(HashSet()) { it.first }
        cExacts.mapTo(exactSet) { it.first }
        return takeWithExactGuarantee(ranked, limit, exactSet)
    }

    /** 取前 limit 个,但整串精确候选(打全拼音/数字码的字词)绝不被截出——单字全量可达保底。 */
    private fun takeWithExactGuarantee(ranked: List<Candidate>, limit: Int, exactWords: Set<String>): List<Candidate> {
        if (ranked.size <= limit) return ranked
        val out = ArrayList<Candidate>(limit + 32)
        out.addAll(ranked.subList(0, limit))
        if (exactWords.isNotEmpty()) {
            for (i in limit until ranked.size) {
                val c = ranked[i]
                if (c.word in exactWords) out.add(c)
            }
        }
        return out
    }

    /** 整串数字码的精确候选词集合(锁定态按边界过滤)——全量可达保底用。 */
    private fun t9ExactSet(digits: String, lockedSylls: List<String>): Set<String> {
        val out = HashSet<String>()
        val lockedPinyin = lockedSylls.joinToString("")
        val bounds = if (lockedSylls.isEmpty()) emptySet() else lockedBounds(lockedSylls)
        for ((w, _, key) in dict.t9ExactWords(digits)) {
            if (lockedSylls.isEmpty() || lockedCompatible(w, key, 0, lockedPinyin, bounds)) out.add(w)
        }
        // 保底集并入自定义精确词:自定义词打全数字码同样必可达
        for ((w, _, key) in customDict.t9ExactWords(digits)) {
            if (lockedSylls.isEmpty() || lockedCompatible(w, key, 0, lockedPinyin, bounds)) out.add(w)
        }
        // 锁定态逐字组词通道:首锁定音节单字同样保底(锁 yi 必能点出 咦)
        if (lockedSylls.isNotEmpty()) {
            for ((w, _) in dict.exactWords(lockedSylls[0])) out.add(w)
        }
        return out
    }

    /** 模糊音候选(26 键全拼):整串能完整切成合法音节时,按开关派生等价音节组合查词。 */
    private inline fun fuzzyCandidates(pinyin: String, push: (String, Int) -> Unit) {
        if (!fuzzy.anyFuzzy) return
        val syls = dict.splitSyllables(pinyin)
        if (syls.isEmpty() || syls.joinToString("") != pinyin) return
        if (syls.any { !dict.isSyllable(it) }) return
        var combos = listOf("")
        for (syl in syls) {
            val vars = PinyinFuzzy.variants(syl, fuzzy)
            val next = ArrayList<String>(combos.size * vars.size)
            for (c in combos) for (v in vars) { next.add(c + v); if (next.size >= FUZZY_COMBO_CAP) break }
            combos = next
            if (combos.size >= FUZZY_COMBO_CAP) break
        }
        for (key in combos) {
            if (key == pinyin) continue
            for ((w, lv) in dict.exactWords(key)) push(w, lv)
        }
    }

    /**
     * 分段兜底(对齐搜狗:任何输入都有候选)。从头沿"最长合法音节前缀"逐段出单字;
     * 遇到起不了合法音节的位置,把剩余原样作为字母候选(选中即上屏字母)。只取前 2 段,不递归全展开。
     */
    private inline fun segmentedFallback(pinyin: String, push: (String, Int, Int) -> Unit) {
        var pos = 0
        var seg = 0
        while (pos < pinyin.length && seg < 2) {
            val len = dict.longestSyllableAt(pinyin, pos)
            if (len == 0) { push(pinyin.substring(pos), pinyin.length, LAYER_SINGLE - 2); return }
            val syl = pinyin.substring(pos, pos + len)
            for ((w, lv) in dict.exactWords(syl)) if (w.length == 1) {
                push(w, pos + len, layerScore(LAYER_SINGLE, lv, w))
            }
            pos += len; seg++
        }
    }

    /** 容错纠错(26 键全拼):整串无法切分时,对最后一段做编辑距离≤1 还原。 */
    private inline fun correctionCandidates(pinyin: String, push: (String, Int) -> Unit) {
        if (!fuzzy.correction || pinyin.length < 2) return
        val syls = dict.splitSyllables(pinyin)
        val last = syls.lastOrNull() ?: return
        if (dict.isSyllable(last)) return
        val prefix = pinyin.substring(0, pinyin.length - last.length)
        for (fixed in PinyinFuzzy.corrections(last) { dict.isSyllable(it) }) {
            for ((w, lv) in dict.exactWords(prefix + fixed)) push(w, lv)
        }
    }

    /**
     * 整句候选(26 键)。每词惩罚 SEG_PENALTY(与 T9 侧 sentenceFromPinyin 同款)逼最少词数,
     * 修碎拼垃圾("你哈哦"曾压过"你好");末段允许前缀补全,尾部残音节也能进整句
     * (youmeiy→有没+有、woxiangchif→我想+吃饭),matchedLen==n 表示消耗了全部输入。
     */
    private fun sentenceCandidate(input: String): Candidate? {
        val n = input.length
        if (n < 2) return null
        val dp = IntArray(n + 1) { Int.MIN_VALUE }
        val from = IntArray(n + 1) { -1 }
        val word = arrayOfNulls<String>(n + 1)
        dp[0] = 0
        for (i in 1..n) {
            val lo = maxOf(0, i - dict.maxSyllableLen * 4)
            for (j in lo until i) {
                if (dp[j] == Int.MIN_VALUE) continue
                var best = dict.bestWord(input.substring(j, i))
                // 自定义词参与切分成句(取两表更高词频者)
                customDict.bestWord(input.substring(j, i))?.let { cb ->
                    if (best == null || cb.second > best!!.second) best = cb
                }
                if (best == null && i == n && j > 0) {
                    // 尾段残音节:取最优前缀补全词(按缺失字母数微罚)参与整句
                    var comp: Pair<String, Int>? = null
                    for ((w, lv, klen) in dict.prefixWords(input.substring(j, i), 30)) {
                        val adj = lv - (klen - (i - j)) * 8
                        if (comp == null || adj > comp.second) comp = w to adj
                    }
                    best = comp
                }
                if (best == null) continue
                val gain = best.second - SEG_PENALTY + minOf(userDict.bonus(best.first), USER_CAP)
                if (dp[j] + gain > dp[i]) { dp[i] = dp[j] + gain; from[i] = j; word[i] = best.first }
            }
        }
        var end = n
        while (end > 0 && dp[end] == Int.MIN_VALUE) end--
        if (end < 2 || from[end] < 0) return null
        val parts = ArrayList<String>()
        var cur = end
        while (cur > 0 && from[cur] >= 0) { parts.add(word[cur]!!); cur = from[cur] }
        if (cur != 0 || parts.size < 2) return null
        return Candidate(parts.asReversed().joinToString(""), end, dp[end])
    }

    private val t9 = mapOf(
        '2' to "abc", '3' to "def", '4' to "ghi", '5' to "jkl",
        '6' to "mno", '7' to "pqrs", '8' to "tuv", '9' to "wxyz"
    )

    // ===== 切分歧义根治(修 huanameduoqian 被当成 huan|a|me...) =====
    // 业界标准:候选词拼音按"字→读音表"对齐切分(权威),不再用贪心最长/音节频率猜。
    private val alignCache = HashMap<String, List<String>?>()

    /**
     * 把词的拼音 key 按字对齐切成音节(华纳+huana→[hua,na]、西安+xian→[xi,an])。
     * 对不齐(生僻字/数据缺失)返回 null,调用方回退贪心切分。
     */
    fun alignWordPinyin(word: String, key: String): List<String>? {
        if (word.isEmpty() || key.isEmpty()) return null
        val ck = "$word\u0001$key"
        alignCache[ck]?.let { return it }
        if (alignCache.containsKey(ck)) return null
        var result: List<String>? = null
        val acc = ArrayList<String>(word.length)
        fun dfs(ci: Int, pos: Int) {
            if (result != null) return
            if (ci == word.length) {
                if (pos == key.length) result = ArrayList(acc)
                return
            }
            for (r in dict.readingsOf(word[ci])) {
                if (key.startsWith(r, pos)) {
                    acc.add(r)
                    dfs(ci + 1, pos + r.length)
                    acc.removeAt(acc.size - 1)
                    if (result != null) return
                }
            }
        }
        dfs(0, 0)
        if (alignCache.size > 8000) alignCache.clear()
        alignCache[ck] = result
        return result
    }

    /**
     * 锁定音节栈 → 边界位置集合(累积长度)。
     * 【单键锁定修复】尾项若只是音节前缀而非完整音节(单键 3 点选 d/f、残拼锁 zh 类),
     * 它只约束"读音从这些字母开始",不构成音节边界——候选读音可越过其末端继续铺开
     * (锁 d 后 的@de 合法)。旧实现把前缀末端也当边界 → 无词能配,兜底又绕过锁定过滤,
     * 表现为"点了没反应"。非尾项保持边界(已被后续点选确认)。
     */
    private fun lockedBounds(locked: List<String>): Set<Int> {
        val bounds = HashSet<Int>()
        var acc = 0
        for ((i, s) in locked.withIndex()) {
            acc += s.length
            if (i == locked.lastIndex && !dict.isSyllable(s)) continue
            bounds.add(acc)
        }
        return bounds
    }

    /**
     * 候选(word,key)从拼音位置 start 铺开,是否兼容锁定音节边界:
     * ①与锁定拼音重叠部分逐字母一致;②候选在锁定区内结束必须停在音节边界;
     * ③锁定区内部边界必须是候选字读音对齐后的边界(锁 hua 排除 换@huan)。
     */
    private fun lockedCompatible(word: String, key: String, start: Int, lockedPinyin: String, bounds: Set<Int>): Boolean {
        val lockLen = lockedPinyin.length
        if (start >= lockLen) return true
        val end = start + key.length
        val p = minOf(end, lockLen)
        if (!key.regionMatches(0, lockedPinyin, start, p - start)) return false
        if (end < lockLen && end !in bounds) return false
        val inner = bounds.filter { it in (start + 1) until end }
        if (inner.isEmpty()) return true
        val aligned = alignWordPinyin(word, key) ?: return true // 生僻字对不齐:不强杀(宁多勿漏)
        val wb = HashSet<Int>()
        var acc = start
        for (s in aligned) { acc += s.length; wb.add(acc) }
        return inner.all { it in wb }
    }

    /** 候选显示拼音:字对齐切分优先(华纳+huana→hua'na),失败回退贪心。 */
    fun displaySplit(word: String, key: String): String =
        alignWordPinyin(word, key)?.joinToString("'") ?: splitKnownPinyin(key)

    /**
     * T9 候选(业界对齐,数字码索引直查,已本地脚本电池验证)。
     * 总原则与 26 键一致:**消耗全部输入的候选 > 忽略尾部输入的候选**。
     *  - 词层 = 逐前缀精确词(数字码直查,根治 DFS 512 截断丢词:shangban 曾永远打不出"上班")
     *    + 全消耗前缀补全(youmeiy→有没有、shaow→稍微,每缺失位罚 PEN_MISS)。
     *  - 全消耗精确词加 EXACT_FULL_BONUS:同码时精确词(要钱)永远压过补全词(晚上@wanshang)。
     *  - 整句全覆盖时置顶,部分覆盖沉底(镜像 26 键分层)。
     */
    // lockedSylls:拼音选择器锁定音节栈(切分歧义根治)——词层/补全/整句全部按锁定
    // 边界过滤(锁 hua 排除 换@huan),取代旧"锁定拼音串重查+贪心剩余段"路径。
    fun candidatesT9(digits: String, limit: Int = CAND_LIMIT, lockedSylls: List<String> = emptyList()): List<Candidate> {
        if (!dict.isReady || digits.isEmpty()) return emptyList()
        val merged = HashMap<String, Candidate>()
        val lockedPinyin = lockedSylls.joinToString("")
        val bounds = if (lockedSylls.isEmpty()) emptySet() else lockedBounds(lockedSylls)
        fun ok(word: String, key: String) =
            lockedSylls.isEmpty() || lockedCompatible(word, key, 0, lockedPinyin, bounds)
        fun put(word: String, matchedLen: Int, score: Int, pinyin: String = "") {
            if (word.isEmpty()) return
            val old = merged[word]
            if (old == null || score > old.score) merged[word] = Candidate(word, matchedLen, score, pinyin = pinyin)
        }
        fun consider(word: String, matchedLen: Int, base: Int, level: Int, pinyin: String) =
            put(word, matchedLen, matchedLen * MATCH_W + base + level * LEVEL_W + lenBonus(word) + userBonus(word), pinyin)

        val n = digits.length
        // 【单键锁定修复】锁定串已覆盖全部数字且尾项只是音节前缀(单键 3 锁 d/f、锁 zh 类):
        // 词层(L>=2)/补全(数字空间在共享键上扫不到目标声母)/锁定单字(须完整音节)全部无产出,
        // 旧实现落进绕过锁定的兜底 → "点了没反应"。此形态语义上等价于"26 键打了 d 这个前缀"
        // → 直接复用 26 键成熟预测通道(的/都/大),matchedLen=n:选词一次吃净全部数字与锁定栈。
        // 方案经 scratch-keyboard-verify/test_t9_prefix_lock.py 全量验证。
        if (lockedSylls.isNotEmpty() && lockedPinyin.length >= n && !dict.isSyllable(lockedSylls.last())) {
            return candidates(lockedPinyin, limit).map { Candidate(it.word, n, it.score, pinyin = it.pinyin) }
        }
        if (n >= 4) {
            // 整句联想(带锁定约束+拼音回溯):全覆盖置顶;部分覆盖沉底(镜像 26 键原则)。
            // top-2 路径:次优整句降 1 个词频级参与排序(用户学习翻转 #1 后原整句变体不消失)。
            sentenceT9(digits, lockedSylls).forEachIndexed { rank, (whole, cov, spy) ->
                val layer = if (cov >= n) LAYER_SENTENCE else LAYER_SENTENCE_PARTIAL
                put(whole, cov, cov * MATCH_W + layer - rank * LEVEL_W, spy)
            }
        }
        // 简拼(锁定态跳过:简拼词无完整读音,无法验证锁定边界)
        if (lockedSylls.isEmpty() && n <= MAX_T9_WORD_DIGITS) {
            for (s in expandInitials(digits)) {
                for ((w, lv) in dict.initialsExact(s)) consider(w, n, LAYER_ABBR, lv, "")
            }
        }
        // 词层:逐前缀精确词(数字码索引直查,同码拼音全命中、无展开截断)。
        // 全消耗(L==n)加 EXACT_FULL_BONUS:同码时精确词永远压过下面的补全词。
        // 词层准入(主词库/自定义对称):L<=9 照旧;L==n(全消耗)不限长——打全整词
        // (第六章 10位/事业单位 11位/biang 14位)直接可排,不再只靠整句碰运气。
        val maxL = minOf(n, maxOf(MAX_T9_WORD_DIGITS, customDict.maxDigitLen))
        for (L in 2..maxL) {
            if (L > MAX_T9_WORD_DIGITS && L != n) continue
            val bonus = if (L == n) EXACT_FULL_BONUS else 0
            val seg = digits.substring(0, L)
            val mainHits = dict.t9ExactWords(seg)
            for ((w, lv, key) in mainHits) {
                if (!ok(w, key)) continue
                // 【用户选择记忆】全消耗且用户选过(调频>0)的词层基线提到整句之上——
                // 对齐 RIME 动态调频/搜狗智能调频:用户显式选择 > 机器整句猜测(修 什么鬼/什么会 类)。
                val layer = if (L == n && userBonus(w) > 0) LAYER_SENTENCE else LAYER_EXACT
                put(w, L, L * MATCH_W + layer + bonus + lv * LEVEL_W + lenBonus(w) + userBonus(w), key)
            }
            // 自定义词层(custom_dict v2):全消耗时——同码有主词库精确词 → 同层公平按词频竞争
            // (防 61 万词劫持常用短码,九宫格正向核心保护);无主词精确词 → LAYER_SENTENCE
            // (破防了/什么鬼 类新词不被整句垃圾压住;biang showcase 语义保留)。
            for ((w, lv, key) in customDict.t9ExactWords(seg)) {
                if (!ok(w, key)) continue
                val layer = when {
                    L == n && userBonus(w) > 0 -> LAYER_SENTENCE
                    L == n && mainHits.isEmpty() -> LAYER_SENTENCE
                    else -> LAYER_EXACT
                }
                put(w, L, L * MATCH_W + layer + bonus + lv * LEVEL_W + lenBonus(w) + userBonus(w), key)
            }
        }
        // 全消耗前缀补全(修"必须打全数字才出词"):数字码前缀直查,matchedLen=n 排在部分消耗词之上,
        // 缺失位数罚 PEN_MISS(与 26 键同值)。youmeiy(9686349)→有没有、shaow(74269)→稍微。
        // 补全是"预测",业界只置顶少量(修 尾@weizhi 被淹没):按调整分只取 top COMPLETION_TOP 入池,
        // 避免几百个"位置信息"类补全词把逐字组词通道的单字(尾)挤出候选池。
        if (n in 2..MAX_T9_WORD_DIGITS) {
            val comps = ArrayList<Triple<Int, String, String>>()
            for ((w, lv, klen, key) in dict.t9PrefixWords(digits, 200)) {
                if (!ok(w, key)) continue
                val adj = lv * LEVEL_W + lenBonus(w) + userBonus(w) - (klen - n) * PEN_MISS
                comps.add(Triple(adj, w, key))
            }
            // 自定义词补全并入统一 top-K 池(同罚分同量纲);低置信长尾词(lv<110)不做预测。
            for ((w, lv, klen, key) in customDict.t9PrefixWords(digits, 200)) {
                if (lv < CUSTOM_COMPLETION_MIN_LV) continue
                if (!ok(w, key)) continue
                val adj = lv * LEVEL_W + lenBonus(w) + userBonus(w) - (klen - n) * PEN_MISS
                comps.add(Triple(adj, w, key))
            }
            comps.sortByDescending { it.first }
            for ((adj, w, key) in comps.take(COMPLETION_TOP)) {
                put(w, n, n * MATCH_W + LAYER_EXACT + adj, key)
            }
        }
        // 用户自造词(耗子尾汁类,逐词组合学得):整词精确压过垃圾整句;前缀预测同词层罚分规则。
        userDict.eachPhrase { pinyin, pdigits, word, cnt ->
            if (ok(word, pinyin)) {
                val boost = minOf(cnt, 5) * LEVEL_W
                when {
                    digits.startsWith(pdigits) -> {
                        put(word, pdigits.length, pdigits.length * MATCH_W + LAYER_SENTENCE + PHRASE_FREQ * LEVEL_W + boost + lenBonus(word), pinyin)
                    }
                    n >= 2 && pdigits.startsWith(digits) -> {
                        val sc = n * MATCH_W + LAYER_EXACT + (PHRASE_FREQ + minOf(cnt, 5)) * LEVEL_W + lenBonus(word) - (pdigits.length - n) * PEN_MISS
                        put(word, n, sc, pinyin.take(n))
                    }
                }
            }
        }
        // 锁定态:首锁定音节单字置入(逐字组词通道:锁 hua 必能点出 花/话/华)
        if (lockedSylls.isNotEmpty()) {
            val first = lockedSylls[0]
            for ((w, lv) in dict.exactWords(first)) {
                put(w, first.length, first.length * MATCH_W + LAYER_SINGLE + lv * LEVEL_W + userBonus(w), first)
            }
        }
        // 永不空候选兜底:先取最长可成前缀的字/词
        if (merged.isEmpty()) {
            for (L in minOf(n, MAX_T9_WORD_DIGITS) downTo 1) {
                for ((w, lv, key) in dict.t9ExactWords(digits.substring(0, L))) consider(w, L, LAYER_SINGLE, lv, key)
                if (merged.isNotEmpty()) break
            }
        }
        // 仍空(尾段半音节,如单个「9」):用「已切前缀+尾段字母」查词 → **纯汉字**续词(我/一/仪),绝不放裸字母
        // 【单键锁定修复】兜底同样尊重锁定过滤(77 锁 q 不得回吐 p/r/s 词)
        if (merged.isEmpty()) appendPartialChinese(digits, merged, if (lockedSylls.isEmpty()) null else { w, k -> ok(w, k) })
        val ranked = merged.values.filter { !userDict.isBlacklisted(it.word) }.sortedByDescending { it.score }
        // 【单字全量可达保底】整串数字码的精确候选(锁定过滤后)绝不被截出池
        return takeWithExactGuarantee(ranked, limit, t9ExactSet(digits, lockedSylls))
    }

    /**
     * 尾段半音节的纯汉字续词:已切前缀词 +「前缀+尾段首数字字母」前缀词。绝不产出可上屏的裸字母。
     * ok 非空时(锁定态)按锁定读音过滤(【单键锁定修复】)。
     */
    private fun appendPartialChinese(digits: String, merged: HashMap<String, Candidate>, ok: ((String, String) -> Boolean)? = null) {
        val (segs, covered) = bestT9SegPartial(digits)
        val coveredPinyin = segs.joinToString("")
        fun put(w: String, mlen: Int, score: Int, py: String) {
            if (w.isEmpty()) return
            if (ok != null && !ok(w, py)) return
            val old = merged[w]; if (old == null || score > old.score) merged[w] = Candidate(w, mlen, score, pinyin = py)
        }
        if (coveredPinyin.isNotEmpty()) {
            for ((w, lv) in dict.exactWords(coveredPinyin)) put(w, covered, LAYER_EXACT + lv * LEVEL_W + lenBonus(w) + userBonus(w), coveredPinyin)
        }
        if (covered < digits.length) {
            for (letter in t9[digits[covered]] ?: "") {
                val pre = coveredPinyin + letter
                for ((w, lv) in dict.exactWords(pre)) put(w, digits.length, LAYER_ABBR + lv * LEVEL_W, pre)
                for ((w, lv, klen) in dict.prefixWords(pre, 30)) put(w, digits.length, LAYER_PREFIX + lv * LEVEL_W - (klen - pre.length) * 15, pre)
            }
        }
    }

    /**
     * 9 宫格「前导音节自选」(图1 mi/ni/o/m,已本地脚本验证)。
     * 只展开**前导 1..3 位数字**(不是整串!)得到可能的合法音节 + 单字母前缀,去重排序。
     * 只碰前导段 → 天然避开 expandFullPinyin 对长串的指数级爆炸(旧实现卡死根因)。
     */
    /**
     * 拼音选择器选项:**整段完整音节全部保留、排最前**(7426 的 qian/qiao/shao/pian/piao/shan
     * 一个不能少——修「qiao 打不出来」:低频长音节此前被 limit 按频率截断,用户无从细化),
     * 短前导音节按(频率,段长)补足。选择器可滑动,limit 放宽即可。已本地脚本花式验证 + 0.5ms。
     */
    fun t9LeadingOptions(digits: String, maxSeg: Int = 3, limit: Int = 8): List<String> {
        if (!dict.isReady || digits.isEmpty()) return emptyList()
        val fullLen = minOf(maxSeg, digits.length)
        val seen = LinkedHashSet<String>()
        val fulls = ArrayList<Pair<String, Int>>()  // 整段音节(len==fullLen)
        val shorts = ArrayList<Triple<String, Int, Int>>()
        for (L in fullLen downTo 1) {
            for (exp in expandFullPinyin(digits.substring(0, L))) {
                if (dict.isSyllable(exp) && seen.add(exp)) {
                    val lv = dict.exactWords(exp).firstOrNull()?.second ?: -1
                    if (L == fullLen) fulls.add(exp to lv) else shorts.add(Triple(exp, L, lv))
                }
            }
        }
        for (c in t9[digits[0]] ?: "") {
            val s = c.toString()
            if (dict.isSyllablePrefix(s) && seen.add(s)) shorts.add(Triple(s, 1, -2))
        }
        fulls.sortByDescending { it.second }
        shorts.sortWith(compareByDescending<Triple<String, Int, Int>> { it.third }.thenByDescending { it.second })
        return (fulls.map { it.first } + shorts.map { it.first }).take(limit)
    }

    /**
     * 锁定段+待定段候选(完整专业九宫格,已本地脚本验证)。
     * lockedPinyin=已确认拼音前缀(如 "ni"),pending=未确认数字。只展开待定段**前 maxSyllableLen 位**,
     * 与锁定前缀拼接查词 → 永不整串展开,彻底避免卡死。
     */
    fun candidatesT9Locked(lockedPinyin: String, pending: String, limit: Int = CAND_LIMIT): List<Candidate> {
        if (!dict.isReady) return emptyList()
        // 待定段能完整切分 → 用成熟 26 键 candidates() 从「锁定拼音+最优待定拼音」生成(与显示一一对应)
        if (pending.isEmpty()) return candidates(lockedPinyin, limit)
        bestT9Seg(pending)?.let { return candidates(lockedPinyin + it.joinToString(""), limit) }
        val merged = HashMap<String, Candidate>()
        fun put(w: String, mlen: Int, score: Int) {
            val old = merged[w]; if (old == null || score > old.score) merged[w] = Candidate(w, mlen, score)
        }
        if (pending.isEmpty()) {
            for ((w, lv) in dict.exactWords(lockedPinyin)) put(w, lockedPinyin.length, LAYER_EXACT + lv * LEVEL_W + lenBonus(w) + userBonus(w))
            for ((w, lv, klen) in dict.prefixWords(lockedPinyin, 100)) put(w, lockedPinyin.length, LAYER_PREFIX + lv * LEVEL_W - (klen - lockedPinyin.length) * 15)
        } else {
            val win = pending.substring(0, minOf(pending.length, dict.maxSyllableLen))
            for (exp in expandFullPinyin(win)) {
                if (!dict.isSyllablePrefix(exp)) continue
                val key = lockedPinyin + exp
                for ((w, lv) in dict.exactWords(key)) put(w, key.length, LAYER_EXACT + lv * LEVEL_W + lenBonus(w) + userBonus(w))
                for ((w, lv, klen) in dict.prefixWords(key, 100)) put(w, key.length, LAYER_PREFIX + lv * LEVEL_W - (klen - key.length) * 15)
            }
        }
        // 锁定态也保证非空
        if (merged.isEmpty()) for (c in lockedPinyin.ifEmpty { pending }) { put(c.toString(), 1, 0); break }
        return merged.values.filter { !userDict.isBlacklisted(it.word) }.sortedByDescending { it.score }.take(limit)
    }

    private val letter2digit: Map<Char, Char> = buildMap {
        for ((d, letters) in t9) for (c in letters) put(c, d)
    }

    /** 音节字母串 → T9 数字串(逐音节删除时把锁定音节退回待定数字)。 */
    fun syllableToDigits(syl: String): String = buildString { for (c in syl) append(letter2digit[c] ?: c) }

    /** 拼音键是否可完整切成合法音节(护栏1:不合法则显示/联动会怪,拒绝入库)。 */
    private fun allValidSyllables(pinyin: String): Boolean {
        if (pinyin.isEmpty()) return false
        var i = 0
        while (i < pinyin.length) {
            var matched = 0
            for (L in minOf(dict.maxSyllableLen, pinyin.length - i) downTo 1) {
                if (dict.isSyllable(pinyin.substring(i, i + L))) { matched = L; break }
            }
            if (matched == 0) return false
            i += matched
        }
        return true
    }

    /**
     * T9 最优拼音切分(DP,已本地脚本验证):23744→[ce,shi]、64426→[ni,hao]。
     * 每音节惩罚 SEG_PENALTY(>最大词频)逼最少音节、优先长音节成词,避免碎切成 a'e'o 乱码。
     * 返回 null 表示无法完整切分(半截输入),交由调用方走部分匹配。
     */
    /** DP 切分,返回 (音节列表, 已完整切分的最长前缀长度)。covered==n 表示整串可切。 */
    private fun bestT9SegPartial(digits: String): Pair<List<String>, Int> {
        if (!dict.isReady || digits.isEmpty()) return emptyList<String>() to 0
        val n = digits.length
        val dp = IntArray(n + 1) { Int.MIN_VALUE }
        val backLen = IntArray(n + 1)
        val backSyl = arrayOfNulls<String>(n + 1)
        dp[0] = 0
        for (i in 1..n) {
            val maxL = minOf(dict.maxSyllableLen, i)
            for (L in 1..maxL) {
                if (dp[i - L] == Int.MIN_VALUE) continue
                var bestSyl: String? = null; var bestLv = -1
                for (exp in expandFullPinyin(digits.substring(i - L, i))) {
                    if (!dict.isSyllable(exp)) continue
                    val lv = dict.exactWords(exp).firstOrNull()?.second ?: 0
                    if (lv > bestLv) { bestLv = lv; bestSyl = exp }
                }
                if (bestSyl == null) continue
                val score = dp[i - L] + bestLv - SEG_PENALTY
                if (score > dp[i]) { dp[i] = score; backLen[i] = L; backSyl[i] = bestSyl }
            }
        }
        var covered = 0
        for (i in n downTo 0) if (dp[i] != Int.MIN_VALUE) { covered = i; break }
        val parts = ArrayList<String>()
        var i = covered
        while (i > 0) { parts.add(backSyl[i]!!); i -= backLen[i] }
        return parts.asReversed() to covered
    }

    /** T9 最优拼音切分(整串可切时返回,否则 null)。 */
    fun bestT9Seg(digits: String): List<String>? {
        val (segs, covered) = bestT9SegPartial(digits)
        return if (covered == digits.length && covered > 0) segs else null
    }

    /** 某数字的默认拼音字母(残段显示用):取第一个合法音节前缀字母。 */
    private fun defaultLetter(d: Char): Char {
        for (c in t9[d] ?: "") if (dict.isSyllablePrefix(c.toString())) return c
        return t9[d]?.firstOrNull() ?: d
    }

    /** 把已知合法拼音贪心最长切分成音节,用 ' 分隔(wanshan→wan'shan、ceshi→ce'shi)。 */
    private fun splitKnownPinyin(py: String): String {
        if (py.isEmpty()) return py
        val parts = ArrayList<String>()
        var i = 0
        while (i < py.length) {
            var matched = 0
            for (L in minOf(dict.maxSyllableLen, py.length - i) downTo 1) {
                if (dict.isSyllable(py.substring(i, i + L))) { matched = L; break }
            }
            if (matched == 0) { parts.add(py.substring(i)); break }
            parts.add(py.substring(i, i + matched)); i += matched
        }
        return parts.joinToString("'")
    }

    // 小缓存:同一(数字串,锁定栈)的显示与候选复用同一次计算,避免重复;学习后整体失效。
    private var t9CacheKey: String? = null
    private var t9CacheVal: List<Candidate> = emptyList()
    private fun t9Compute(digits: String, lockedSylls: List<String> = emptyList()): List<Candidate> {
        val key = if (lockedSylls.isEmpty()) digits else digits + "\u0001" + lockedSylls.joinToString("'")
        if (key == t9CacheKey) return t9CacheVal
        val r = candidatesT9(digits, T9_POOL, lockedSylls)
        t9CacheKey = key; t9CacheVal = r
        return r
    }

    /**
     * T9 候选(多展开算法,准确出多音节整词如 完善/要钱)。与显示拼音一一对应:显示跟随 #1 候选读音。
     */
    fun candidatesForT9(digits: String, limit: Int = CAND_LIMIT): List<Candidate> =
        if (!dict.isReady) emptyList()
        else takeWithExactGuarantee(t9Compute(digits), limit, t9ExactSet(digits, emptyList()))

    /**
     * 拼音选择器过滤:用户在左侧竖排锁定了读音前缀(如 "wan")后,只保留读音以该前缀开头的候选。
     * 复用多展开缓存(准确、不丢词);过滤为空则回退不过滤(安全)。
     */
    /**
     * 整句(作用于拼音串,与 sentenceT9 同款 segPenalty 抗碎切)。用于锁定态:尊重锁定读音又不碎成单字。
     * 修"锁定后候选碎成 进提按提按起 乱码"——26 键 sentenceCandidate 无每词惩罚会碎切。
     */
    private fun sentenceFromPinyin(pinyin: String): Candidate? {
        val n = pinyin.length
        if (n < 2) return null
        val dp = IntArray(n + 1) { Int.MIN_VALUE }
        val from = IntArray(n + 1) { -1 }
        val word = arrayOfNulls<String>(n + 1)
        dp[0] = 0
        for (i in 1..n) {
            val lo = maxOf(0, i - dict.maxSyllableLen * 4)
            for (j in lo until i) {
                if (dp[j] == Int.MIN_VALUE) continue
                val best = dict.bestWord(pinyin.substring(j, i)) ?: continue
                val gain = best.second - SEG_PENALTY
                if (dp[j] + gain > dp[i]) { dp[i] = dp[j] + gain; from[i] = j; word[i] = best.first }
            }
        }
        var end = n
        while (end > 0 && dp[end] == Int.MIN_VALUE) end--
        if (end < 2 || from[end] < 0) return null
        val parts = ArrayList<String>()
        var cur = end
        while (cur > 0 && from[cur] >= 0) { parts.add(word[cur]!!); cur = from[cur] }
        if (cur != 0 || parts.size < 2) return null
        return Candidate(parts.asReversed().joinToString(""), end, end * MATCH_W + LAYER_SENTENCE, pinyin = pinyin.substring(0, end))
    }

    /**
     * 锁定态候选(切分歧义根治重写):不再"锁定拼音串+贪心剩余段重查",而是在**数字空间
     * 全量检索**(与非锁定态同一通道 candidatesT9)+ 锁定音节边界过滤。
     * 锁 hua 后:换@huan 被边界过滤掉,话那么多钱@hua... 保留 → 候选与用户点选意图一致。
     * lockedSylls 为空列表时兼容旧调用(按 lockedPinyin 贪心拆,仅作降级)。
     */
    fun candidatesForT9Filtered(digits: String, lockedPinyin: String, limit: Int = CAND_LIMIT, lockedSylls: List<String>? = null): List<Candidate> {
        if (!dict.isReady) return emptyList()
        if (lockedPinyin.isEmpty()) return candidatesForT9(digits, limit)
        val locked = lockedSylls ?: greedySylls(lockedPinyin)
        val r = takeWithExactGuarantee(t9Compute(digits, locked), limit, t9ExactSet(digits, locked))
        // 极端情况(锁定边界过滤后全空):回退 26 键通道保证候选非空
        if (r.isEmpty()) return candidates(lockedPinyin, limit)
        return r
    }

    /** 贪心切音节(仅作旧调用降级;正常路径 Controller 直接传锁定栈)。 */
    private fun greedySylls(py: String): List<String> {
        val parts = ArrayList<String>()
        var i = 0
        while (i < py.length) {
            var m = 0
            for (L in minOf(dict.maxSyllableLen, py.length - i) downTo 1) {
                if (dict.isSyllable(py.substring(i, i + L))) { m = L; break }
            }
            if (m == 0) break
            parts.add(py.substring(i, i + m)); i += m
        }
        return parts
    }

    /** 识别拼音显示(带锁定):跟随过滤后 #1 候选读音(字对齐切分);无则锁定音节 + 剩余段部分显示。 */
    fun t9DisplayFiltered(digits: String, lockedPinyin: String, lockedSylls: List<String>? = null): String {
        if (!dict.isReady || digits.isEmpty()) return digits
        if (lockedPinyin.isEmpty()) return t9DisplayPinyin(digits)
        val locked = lockedSylls ?: greedySylls(lockedPinyin)
        // 【单键锁定修复】全部数字都被锁定覆盖:组合区忠实显示用户点选(锁 d 显示 d,
        // 而非 #1 补全候选的完整读音 de——用户显式点选优先于机器预测)。
        if (lockedPinyin.length >= digits.length) return locked.joinToString("'")
        candidatesForT9Filtered(digits, lockedPinyin, 1, locked).firstOrNull()
            ?.takeIf { it.pinyin.isNotEmpty() }
            ?.let { return displaySplit(it.word, it.pinyin) }
        val remain = if (lockedPinyin.length < digits.length) digits.substring(lockedPinyin.length) else ""
        val remainDisp = if (remain.isEmpty()) "" else t9DisplayPinyin(remain)
        return listOf(locked.joinToString("'"), remainDisp).filter { it.isNotEmpty() }.joinToString("'")
    }

    /**
     * T9 识别拼音显示串:跟随 #1 候选的读音,按**字对齐**切分(华纳→hua'na 而非 huan'a,
     * 话那么多钱→hua'na'me'duo'qian),保证与首候选严格对应且无幻觉音节。
     * 无候选拼音(简拼)时回退:已切前缀 + 尾段残位默认字母(ce'shi'w),绝不显示原始数字。
     */
    fun t9DisplayPinyin(digits: String): String {
        if (!dict.isReady || digits.isEmpty()) return digits
        t9Compute(digits).firstOrNull()?.takeIf { it.pinyin.isNotEmpty() }
            ?.let { return displaySplit(it.word, it.pinyin) }
        val (segs, covered) = bestT9SegPartial(digits)
        val parts = ArrayList(segs)
        for (idx in covered until digits.length) parts.add(defaultLetter(digits[idx]).toString())
        return parts.joinToString("'")
    }

    /** 是否合法拼音音节(拼音选择器高亮判定用)。 */
    fun isSyllable(s: String) = dict.isSyllable(s)

    /** 数字段最优切分的第一个音节(拼音选择器高亮用;锁定态 #1 候选无 pinyin 时的兜底)。 */
    fun t9FirstSyllable(digits: String): String {
        if (!dict.isReady || digits.isEmpty()) return ""
        bestT9SegPartial(digits).first.firstOrNull()?.let { return it }
        return defaultLetter(digits[0]).toString()
    }

    /**
     * 整句联想:**top-K 状态 DP**(每位置保留 K 条不同末词路径,段内取 top-K 词)+ 用户 bigram 转移加成
     * (learnPair 越用越准,已验证:你好呀/买点东西/再吃个火锅/可以啊小哥哥 学习后修复)+ 自定义词跳转 +
     * 最远可达前缀。SENT_PEN=380 为电池扫描最优(独立于显示切分的 SEG_PENALTY)。
     * 本地脚本验证:电池 25 句无学习 14 全对(81%),学习后 19 全对(92%);热态单步 1.3ms。
     */
    /** 整句 DP 状态:score + 前驱位置 + 前驱词 + 本词拼音 key(拼音回溯用)。 */
    private data class SentSt(val score: Int, val from: Int, val prevWord: String, val key: String)

    // 返回 (句子, 覆盖位数, 拼音key串)。拼音回溯:整句候选不再是"无读音黑箱"——显示拼音
    // 跟随 #1 候选时,话那么多钱→hua'na'me'duo'qian(修 ne 幻觉:旧 bestT9SegPartial 按
    // 音节频率瞎猜出词典中不存在的组合)。lockedSylls:锁定音节边界约束(锁 hua 排除跨界词)。
    private fun sentenceT9(digits: String, lockedSylls: List<String> = emptyList()): List<Triple<String, Int, String>> {
        val raw = digits.length
        if (raw < 4) return emptyList()
        val lockedPinyin = lockedSylls.joinToString("")
        val bounds = if (lockedSylls.isEmpty()) emptySet() else lockedBounds(lockedSylls)
        val n = minOf(raw, MAX_T9_SENTENCE)
        // dp[i]: 末词 -> SentSt
        val dp = Array(n + 1) { HashMap<String, SentSt>() }
        dp[0][""] = SentSt(0, -1, "", "")
        val cand = HashMap<String, SentSt>()
        for (i in 1..n) {
            cand.clear()
            fun relax(w: String, base: Int, j: Int, key: String) {
                // 锁定约束:词铺在拼音区间 [j, j+key.length);与锁定边界/字母冲突则弃
                if (lockedSylls.isNotEmpty() && !lockedCompatible(w, key, j, lockedPinyin, bounds)) return
                for ((pw, st) in dp[j]) {
                    var g = base
                    if (pw.isNotEmpty()) {
                        // 整句语言模型:跨词边界打分(词bigram 中心化 delta / 字bigram OOV veto)。
                        // 修"打对拼音出弱智句"(因为你搬过来→因为你包裹来);挂载前返回 0(退化原行为)。
                        g += sentenceLm.boundaryScore(pw, w)
                        val c = userDict.pairCount(pw, w)
                        if (c > 0) g += minOf(c, 2) * BIGRAM_W
                    }
                    val sc = st.score + g
                    val old = cand[w]
                    if (old == null || sc > old.score) cand[w] = SentSt(sc, j, pw, key)
                }
            }
            val lo = maxOf(0, i - MAX_T9_SEG)
            for (j in lo until i) {
                if (dp[j].isEmpty()) continue
                val segWords = topT9Words(digits.substring(j, i))
                for ((w, lv, key) in segWords) relax(w, lv - SENT_PEN, j, key)
                // 末段残段(i==n 且无精确词):前缀补全参与整句(youmeiy 的尾"y"→有、
                // woxiangchih 的尾"h"→吃喝),缺失位微罚(对齐 26 键 sentenceCandidate *8)。
                if (i == n && j > 0 && segWords.isEmpty()) {
                    var comp: Triple<String, Int, String>? = null
                    for ((w, lv, klen, key) in dict.t9PrefixWords(digits.substring(j, i), 30)) {
                        val adj = lv - (klen - (i - j)) * 8
                        if (comp == null || adj > comp.second) comp = Triple(w, adj, key)
                    }
                    comp?.let { relax(it.first, it.second - SENT_PEN, j, it.third.take(i - j)) }
                }
            }
            // 用户自造词跳转:学过的组合词(耗子尾汁)整句直达
            userDict.eachPhrase { ppy, pdigits, word, cnt ->
                val len = pdigits.length
                if (i >= len && dp[i - len].isNotEmpty() && digits.regionMatches(i - len, pdigits, 0, len)) {
                    relax(word, (PHRASE_FREQ + minOf(cnt, 5)) * LEVEL_W, i - len, ppy)
                }
            }
            // (custom_dict v2)自定义词已并入 topT9Words 词源以同量纲增益参与所有 span——
            // 废弃旧"freq*LEVEL_W 千倍跳转增益"(单词条 showcase 设计,海量词会摧毁整句评分体系)。
            // 【错键容忍,对齐 Gboard 插入错误解码】把第 i-1 位当"误触"跳过:状态原样前移
            // 一位、重罚 GAP_PEN(>任何成词净收益,正常/残拼输入永不偏好跳过)。修「连敲错
            // 几个键后候选/拼音永久冻结,需狂按回退」——垃圾段后的合法输入重新参与解码,
            // matchedLen 含跳过位 → 选词一次性吃掉误触数字。锁定前缀区内禁止跳过。
            if (i - 1 >= lockedPinyin.length) {
                for ((pw, st) in dp[i - 1]) {
                    val sc = st.score - GAP_PEN
                    val old = cand[pw]
                    if (old == null || sc > old.score) cand[pw] = SentSt(sc, st.from, st.prevWord, st.key)
                }
            }
            if (cand.isNotEmpty()) {
                cand.entries.sortedByDescending { it.value.score }.take(SENT_TOPK).forEach { dp[i][it.key] = it.value }
            }
        }
        var cov = 0
        for (i in n downTo 2) if (dp[i].isNotEmpty()) { cov = i; break }
        if (cov < 2) return emptyList()
        // 【整句 top-2】输出最优+次优两条路径(dp 本就保留 SENT_TOPK 状态):
        // 用户学习翻转 #1 后(什么鬼),原整句(什么会)仍作为次优候选可选(对齐搜狗整句变体)。
        val results = ArrayList<Triple<String, Int, String>>(2)
        val seen = HashSet<String>()
        outer@ for ((endWord, _) in dp[cov].entries.sortedByDescending { it.value.score }.take(2)) {
            var w = endWord
            val parts = ArrayList<String>()
            val keys = ArrayList<String>()
            var i = cov
            while (i > 0) {
                val st = dp[i][w] ?: continue@outer
                if (w.isNotEmpty()) { parts.add(w); keys.add(st.key) } // 空态载体(头部垃圾)不产出词
                i = st.from; w = st.prevWord
            }
            if (parts.isEmpty()) continue
            // 跳过位数 = 覆盖位数 - 各词拼音位数之和;有跳过时允许单词句
            // (77+你好:垃圾头+单词也要能出候选并吃掉垃圾),纯净路径仍要求 ≥2 词。
            val gaps = cov - keys.sumOf { it.length }
            if (parts.size < 2 && gaps <= 0) continue
            val whole = parts.asReversed().joinToString("")
            if (!seen.add(whole)) continue
            results.add(Triple(whole, cov, keys.asReversed().joinToString("")))
        }
        return results
    }

    // 段内 top-K 词(记忆化,带拼音 key 供整句回溯):top-1 会剪掉 买点/再 等同码次频词,
    // K=3 让 bigram 学习有路径可选。数字码索引直查:同码拼音全命中,长段无 DFS 截断。
    private val topWordsCache = HashMap<String, List<Triple<String, Int, String>>>()
    private fun topT9Words(seg: String): List<Triple<String, Int, String>> {
        topWordsCache[seg]?.let { return it }
        val best = HashMap<String, Pair<Int, String>>()
        for ((w, lv, key) in dict.t9ExactWords(seg)) {
            if (lv > (best[w]?.first ?: -1)) best[w] = lv to key
        }
        // 自定义词作为普通词参与整句(lv 与主词库同量纲)
        for ((w, lv, key) in customDict.t9ExactWords(seg)) {
            if (lv > (best[w]?.first ?: -1)) best[w] = lv to key
        }
        val r = best.entries.sortedByDescending { it.value.first }.take(SENT_TOPK)
            .map { Triple(it.key, it.value.first, it.value.second) }
        if (topWordsCache.size > 8000) topWordsCache.clear()
        topWordsCache[seg] = r
        return r
    }

    private fun expandInitials(digits: String): List<String> {
        val out = ArrayList<String>()
        val sb = CharArray(digits.length)
        fun dfs(pos: Int) {
            if (out.size >= 120) return
            if (pos == digits.length) { out.add(String(sb)); return }
            val letters = t9[digits[pos]] ?: return
            for (c in letters) {
                sb[pos] = c
                if (dict.initialsHasPrefix(String(sb, 0, pos + 1))) dfs(pos + 1)
            }
        }
        dfs(0)
        return out
    }

    // expandFullPinyin 记忆化:短音节段跨按键/段内高频重复,缓存后长句整句/切分/候选单步<1ms。
    private val expandCache = HashMap<String, List<String>>()
    private fun expandFullPinyin(digits: String): List<String> {
        expandCache[digits]?.let { return it }
        val r = expandFullPinyinRaw(digits)
        if (expandCache.size > 4000) expandCache.clear()
        expandCache[digits] = r
        return r
    }

    private fun expandFullPinyinRaw(digits: String): List<String> {
        val out = ArrayList<String>()
        val sb = CharArray(digits.length)
        fun dfs(pos: Int, sylStart: Int) {
            if (out.size >= 512) return
            if (pos == digits.length) { out.add(String(sb)); return }
            val letters = t9[digits[pos]] ?: return
            for (c in letters) {
                sb[pos] = c
                val curSyl = String(sb, sylStart, pos - sylStart + 1)
                if (dict.isSyllablePrefix(curSyl)) {
                    dfs(pos + 1, sylStart)
                    if (dict.isSyllable(curSyl)) dfs(pos + 1, pos + 1)
                }
            }
        }
        dfs(0, 0)
        return out
    }

    companion object {
        private const val LEVEL_W = 1_000
        private const val LEN_W = 400
        private const val LAYER_SENTENCE = 5_000_000
        private const val LAYER_EXACT = 4_000_000
        private const val LAYER_SENTENCE_FULL = 3_900_000    // 整句(全消耗但已有整词):居次
        private const val LAYER_SENTENCE_PARTIAL = 1_800_000 // 整句(忽略尾字母):沉底于全消耗层
        private const val PEN_MISS = 8_000                   // 前缀补全每缺失字母罚分(≈8 个词频级)
        private const val EXACT_FULL_BONUS = 60_000          // T9 全消耗精确词加成:同码时精确(要钱)必压补全(晚上)
        private const val COMPLETION_TOP = 12                // T9 补全预测入池上限(业界:预测只置顶少量,防淹没单字)
        // 自定义词参与"补全预测"的最低词频等级:预测必须高置信(jieba 标定真实常用≥110 或精选热词 142);
        // 长尾词(base残余/ext默认55)只在"打全"时可达——防弱补全把部分消耗高频词(我想@woxiangch)挤出前排。
        private const val CUSTOM_COMPLETION_MIN_LV = 110
        // 2026-07 修「yi 打不出咦」:词库去除 30/key 构建截断后大音节(yi=137字)全量入库,
        // 100/120 会把锁定单音节的尾部单字再次截掉 → 200/300 + takeWithExactGuarantee 保证全量可达。
        const val CAND_LIMIT = 200                           // 候选显示上限(40/60 会把中频单字如 尾@weizhi 截掉)
        private const val T9_POOL = 300                      // T9 结果缓存池大小
        private const val PHRASE_FREQ = 200                  // 用户自造词基准词频级(高于最高静态词频,学过必出)
        private const val LAYER_FUZZY = 3_500_000
        private const val LAYER_ABBR = 3_000_000
        private const val LAYER_PREFIX = 2_000_000
        private const val LAYER_CORRECTION = 1_500_000
        private const val LAYER_ABBR_PREFIX = 1_000_000
        private const val LAYER_SINGLE = 0
        private const val FUZZY_COMBO_CAP = 24
        private const val USER_WEIGHT = 20_000
        private const val USER_CAP = 20
        private const val MATCH_W = 1_000_000
        private const val MAX_T9_WORD_DIGITS = 9
        private const val ASSOC_BASE = 10_000_000
        private const val MAX_T9_SEG = 13 // 8→13:让 逛一逛(12位)/吃火锅(9位) 等词库长短语参与整句(脚本验证)
        private const val MAX_T9_SENTENCE = 64 // 整句联想最大数字位数(≈21字);记忆化后单步<1ms
        private const val SEG_PENALTY = 300
        private const val SENT_PEN = 380  // 整句每词惩罚(电池扫描最优,独立于显示切分)
        private const val GAP_PEN = 600   // 错键容忍:跳过一位"误触"的罚分(>最大成词净收益)
        private const val SENT_TOPK = 3   // 状态 DP 每位置/每段保留路径数
        private const val BIGRAM_W = 200  // 用户 bigram 每次共现加成(封顶2次=400)
    }
}
