package com.lobster.input.keyboard.pinyin

import android.content.Context

/**
 * 拼音词库(数据访问层)。词库来源:成熟开源 rime-ice(雾凇拼音)。
 *
 * 含两张按 key 排序的表(二分查找,内存友好):
 *  - full     全拼连写 → 候选(pinyin_dict.txt)
 *  - initials 首字母简拼 → 候选(initials_dict.txt),支持业界标准简拼(cs→测试、nh→你好)
 * 另含合法音节集合(音节切分、9 宫格还原)。
 */
class PinyinDictionary {

    @Volatile var isReady: Boolean = false
        private set

    /** 一张按 key 升序排列的词表:并行数组 + 二分。 */
    private class SortedTable {
        var keys: Array<String> = emptyArray()
        var vals: Array<String> = emptyArray()

        fun load(context: Context, asset: String) {
            val ks = ArrayList<String>(170_000)
            val vs = ArrayList<String>(170_000)
            context.assets.open(asset).bufferedReader(Charsets.UTF_8).useLines { lines ->
                for (line in lines) {
                    val tab = line.indexOf('\t')
                    if (tab <= 0) continue
                    ks.add(line.substring(0, tab))
                    vs.add(line.substring(tab + 1))
                }
            }
            keys = ks.toTypedArray()
            vals = vs.toTypedArray()
        }

        val size get() = keys.size

        fun indexOfKey(key: String): Int {
            var lo = 0; var hi = keys.size - 1
            while (lo <= hi) {
                val mid = (lo + hi) ushr 1
                val c = keys[mid].compareTo(key)
                when {
                    c < 0 -> lo = mid + 1
                    c > 0 -> hi = mid - 1
                    else -> return mid
                }
            }
            return -1
        }

        fun lowerBound(key: String): Int {
            var lo = 0; var hi = keys.size
            while (lo < hi) {
                val mid = (lo + hi) ushr 1
                if (keys[mid] < key) lo = mid + 1 else hi = mid
            }
            return lo
        }

        fun wordsAt(index: Int): List<Pair<String, Int>> {
            val parts = vals[index].split(' ')
            val out = ArrayList<Pair<String, Int>>(parts.size / 2)
            var i = 0
            while (i + 1 < parts.size) {
                val w = parts[i]
                val lv = parts[i + 1].toIntOrNull() ?: 0
                if (w.isNotEmpty()) out.add(w to lv)
                i += 2
            }
            return out
        }

        fun exact(key: String): List<Pair<String, Int>> {
            val idx = indexOfKey(key)
            return if (idx < 0) emptyList() else wordsAt(idx)
        }

        fun hasPrefix(prefix: String): Boolean {
            val lb = lowerBound(prefix)
            return lb < keys.size && keys[lb].startsWith(prefix)
        }

        /** 前缀匹配:收集以 prefix 开头(长度大于 prefix)的 key 的首选词。 */
        fun prefix(prefix: String, limit: Int): List<Triple<String, Int, Int>> {
            val out = ArrayList<Triple<String, Int, Int>>()
            var pi = lowerBound(prefix)
            while (pi < keys.size && out.size < limit) {
                val k = keys[pi]
                if (!k.startsWith(prefix)) break
                if (k.length != prefix.length) {
                    wordsAt(pi).firstOrNull()?.let { (w, lv) -> out.add(Triple(w, lv, k.length)) }
                }
                pi++
            }
            return out
        }
    }

    private val full = SortedTable()
    private val initials = SortedTable()

    private val syllables = HashSet<String>()
    private val syllablePrefixes = HashSet<String>()
    var maxSyllableLen = 6
        private set

    fun load(context: Context) {
        isReady = false
        full.load(context, "pinyin_dict.txt")
        if (full.size == 0) return
        initials.load(context, "initials_dict.txt")
        loadSyllables(context)
        buildT9Index()
        buildCharReadings()
        isReady = true
    }

    // ---- 字读音表(切分歧义的权威裁决数据) ----
    // 由词典单字条目构建:key 为合法音节的行,其单字词都记为该字的读音(华→hua、纳→na)。
    // 用于把候选词拼音按字对齐切分(华纳+huana→hua|na),取代贪心最长匹配(huan|a)。
    private val charReadings = HashMap<Char, ArrayList<String>>()

    fun readingsOf(c: Char): List<String> = charReadings[c] ?: emptyList()

    private fun buildCharReadings() {
        for (idx in full.keys.indices) {
            val key = full.keys[idx]
            if (!syllables.contains(key)) continue
            for ((w, _) in full.wordsAt(idx)) {
                if (w.length == 1) {
                    val list = charReadings.getOrPut(w[0]) { ArrayList(2) }
                    if (key !in list) list.add(key)
                }
            }
        }
        // 长读音在前:对齐 DFS 先试长音节,减少回溯
        for (list in charReadings.values) list.sortByDescending { it.length }
    }

    private fun loadSyllables(context: Context) {
        context.assets.open("syllables.txt").bufferedReader(Charsets.UTF_8).useLines { lines ->
            for (raw in lines) {
                val s = raw.trim()
                if (s.isEmpty()) continue
                syllables.add(s)
                for (i in 1..s.length) syllablePrefixes.add(s.substring(0, i))
                if (s.length > maxSyllableLen) maxSyllableLen = s.length
            }
        }
    }

    fun isSyllable(s: String) = syllables.contains(s)
    fun isSyllablePrefix(s: String) = syllablePrefixes.contains(s)

    /** 返回 input 从 pos 起的最长合法音节长度,无则 0(候选兜底用,纯查表)。 */
    fun longestSyllableAt(input: String, pos: Int): Int {
        val maxLen = minOf(maxSyllableLen, input.length - pos)
        for (len in maxLen downTo 1) {
            if (syllables.contains(input.substring(pos, pos + len))) return len
        }
        return 0
    }

    // ---- 全拼 ----
    fun exactWords(key: String) = full.exact(key)
    fun prefixWords(prefix: String, limit: Int) = full.prefix(prefix, limit)
    fun bestWord(key: String): Pair<String, Int>? = full.exact(key).firstOrNull()

    // ---- T9 数字码索引(业界标准:词库按数字码直查,根治 DFS 展开截断丢词) ----
    // full 表每个拼音 key 预转数字码后排序;同码不同拼音的行都会命中(shangban/qiangban 同码)。
    private var t9Keys: Array<String> = emptyArray()
    private var t9Refs: IntArray = IntArray(0)

    private fun buildT9Index() {
        val letter2digit = HashMap<Char, Char>().apply {
            "abc".forEach { put(it, '2') }; "def".forEach { put(it, '3') }
            "ghi".forEach { put(it, '4') }; "jkl".forEach { put(it, '5') }
            "mno".forEach { put(it, '6') }; "pqrs".forEach { put(it, '7') }
            "tuv".forEach { put(it, '8') }; "wxyz".forEach { put(it, '9') }
        }
        val rows = ArrayList<Pair<String, Int>>(full.size)
        val sb = StringBuilder(16)
        outer@ for (idx in full.keys.indices) {
            sb.setLength(0)
            for (c in full.keys[idx]) {
                val d = letter2digit[c] ?: continue@outer
                sb.append(d)
            }
            rows.add(sb.toString() to idx)
        }
        rows.sortBy { it.first }
        t9Keys = Array(rows.size) { rows[it].first }
        t9Refs = IntArray(rows.size) { rows[it].second }
    }

    private fun t9LowerBound(key: String): Int {
        var lo = 0; var hi = t9Keys.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (t9Keys[mid] < key) lo = mid + 1 else hi = mid
        }
        return lo
    }

    /** 数字码精确查词:跨同码拼音合并,返回 (词, 等级, 拼音key)。 */
    fun t9ExactWords(digits: String): List<Triple<String, Int, String>> {
        if (digits.isEmpty()) return emptyList()
        val out = ArrayList<Triple<String, Int, String>>()
        var i = t9LowerBound(digits)
        while (i < t9Keys.size && t9Keys[i] == digits) {
            val ref = t9Refs[i]
            val key = full.keys[ref]
            for ((w, lv) in full.wordsAt(ref)) out.add(Triple(w, lv, key))
            i++
        }
        return out
    }

    /** 数字码前缀补全:每个更长同前缀码取首选词,返回 (词, 等级, 码长, 拼音key)。 */
    fun t9PrefixWords(digits: String, limit: Int): List<T9PrefixHit> {
        if (digits.isEmpty()) return emptyList()
        val out = ArrayList<T9PrefixHit>()
        var i = t9LowerBound(digits)
        while (i < t9Keys.size && out.size < limit) {
            val dk = t9Keys[i]
            if (!dk.startsWith(digits)) break
            if (dk.length != digits.length) {
                val ref = t9Refs[i]
                full.wordsAt(ref).firstOrNull()?.let { (w, lv) ->
                    out.add(T9PrefixHit(w, lv, dk.length, full.keys[ref]))
                }
            }
            i++
        }
        return out
    }

    data class T9PrefixHit(val word: String, val level: Int, val keyDigitLen: Int, val pinyinKey: String)

    // ---- 简拼 ----
    fun initialsExact(key: String) = initials.exact(key)
    fun initialsPrefix(prefix: String, limit: Int) = initials.prefix(prefix, limit)
    fun initialsHasPrefix(prefix: String) = initials.hasPrefix(prefix)

    // ---- 音节切分 ----
    fun splitSyllables(input: String): List<String> {
        val out = ArrayList<String>()
        var pos = 0
        val n = input.length
        while (pos < n) {
            if (input[pos] == '\'') { pos++; continue }
            var matched = -1
            val maxLen = minOf(maxSyllableLen, n - pos)
            for (len in maxLen downTo 1) {
                if (syllables.contains(input.substring(pos, pos + len))) { matched = len; break }
            }
            if (matched > 0) { out.add(input.substring(pos, pos + matched)); pos += matched }
            else { out.add(input.substring(pos)); break }
        }
        return out
    }

    fun displaySegmented(input: String): String = splitSyllables(input).joinToString("'")
}
