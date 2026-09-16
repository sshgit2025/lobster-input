package com.lobster.input.keyboard.pinyin

import android.content.Context

/**
 * 产品内置自定义扩展词库(custom_dict v2,61 万词)。数据访问层,与 [PinyinDictionary] 同构:
 *  - 文件与主词库同格式:`拼音连写key\t词1 lv1 词2 lv2 ...`(key 升序、key 内 lv 降序),
 *    由 tools/keyboard-verify/gen_custom_dict.py 生成,**与主词库零重复**、词频等级同量纲。
 *  - 存储用**字节表**(byte[] + 行偏移索引 + 字节二分,镜像 iOS ByteTable):59 万 key 若用
 *    String 并行数组会撑 ~80MB 热堆,字节表仅 ~25MB(词条文本不解码,命中行才转 String)。
 *  - T9 数字码索引:行号按 key 的数字码字典序排列(IntArray 排列,数字码查询时由 key 字节
 *    即时换算比较,不存储 59 万数字码串)。
 *
 * 加载约定:数据在生成期已保证「全 CJK 2-8 字、拼音可完整切分合法音节、可映射数字码」,
 * 运行时**不做**贪心 allValidSyllables 校验(贪心会误杀 zuoleyinianduo 这类回溯才可切的合法键),
 * 只跳过注释/坏行。由 PinyinEngine 在主词库 READY 后**异步挂载**,挂载前查询按空表返回。
 */
class CustomDictionary {

    @Volatile var isReady: Boolean = false
        private set

    private var bytes: ByteArray = ByteArray(0)
    private var lineStart: IntArray = IntArray(0)
    private var keyLen: IntArray = IntArray(0)
    private var lineEnd: IntArray = IntArray(0)
    /** 行号排列:按 key 的 T9 数字码字典序(同码内按行号即 key 序,稳定)。 */
    private var t9Order: IntArray = IntArray(0)

    var maxDigitLen: Int = 0
        private set

    private val letter2digit = ByteArray(128).also {
        for ((d, letters) in mapOf(
            '2' to "abc", '3' to "def", '4' to "ghi", '5' to "jkl",
            '6' to "mno", '7' to "pqrs", '8' to "tuv", '9' to "wxyz"
        )) for (c in letters) it[c.code] = d.code.toByte()
    }

    fun load(context: Context, assetName: String = "custom_dict.txt") {
        val data = context.assets.open(assetName).use { it.readBytes() }
        val starts = ArrayList<Int>(620_000)
        val klens = ArrayList<Int>(620_000)
        val ends = ArrayList<Int>(620_000)
        var i = 0
        val n = data.size
        while (i < n) {
            val start = i
            var tab = -1
            var j = i
            while (j < n && data[j] != NL) {
                if (data[j] == TAB && tab < 0) tab = j
                j++
            }
            // 跳过注释行与无 TAB 的坏行(数据生成期已保证合法,这里只防御格式损坏)
            if (tab > start && data[start] != HASH) {
                starts.add(start); klens.add(tab - start); ends.add(j)
            }
            i = j + 1
        }
        bytes = data
        lineStart = starts.toIntArray()
        keyLen = klens.toIntArray()
        lineEnd = ends.toIntArray()
        buildT9Order()
        isReady = true
    }

    /** 数字码排列:临时物化数字码串排序(后台线程,峰值 ~30MB 随后 GC),常驻仅 IntArray。 */
    private fun buildT9Order() {
        val count = lineStart.size
        val digitKeys = arrayOfNulls<String>(count)
        var maxLen = 0
        val sb = StringBuilder(24)
        for (idx in 0 until count) {
            sb.setLength(0)
            val s = lineStart[idx]
            val kl = keyLen[idx]
            var valid = true
            for (k in 0 until kl) {
                val b = bytes[s + k].toInt()
                val d = if (b in 0..127) letter2digit[b] else 0
                if (d.toInt() == 0) { valid = false; break }
                sb.append(d.toInt().toChar())
            }
            if (!valid) continue
            digitKeys[idx] = sb.toString()
            if (kl > maxLen) maxLen = kl
        }
        maxDigitLen = maxLen
        val order = (0 until count).filter { digitKeys[it] != null }
            .sortedBy { digitKeys[it]!! }
        t9Order = order.toIntArray()
    }

    // ===== 拼音键查询(字节二分,镜像 iOS ByteTable) =====

    private fun compareKeyAt(index: Int, q: ByteArray): Int {
        val s = lineStart[index]
        val len = keyLen[index]
        val m = minOf(len, q.size)
        for (k in 0 until m) {
            val a = bytes[s + k].toInt() and 0xFF
            val b = q[k].toInt() and 0xFF
            if (a != b) return if (a < b) -1 else 1
        }
        return len.compareTo(q.size)
    }

    private fun lowerBound(q: ByteArray): Int {
        var lo = 0
        var hi = lineStart.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (compareKeyAt(mid, q) < 0) lo = mid + 1 else hi = mid
        }
        return lo
    }

    private fun keyStartsWith(index: Int, q: ByteArray): Boolean {
        if (keyLen[index] < q.size) return false
        val s = lineStart[index]
        for (k in q.indices) if (bytes[s + k] != q[k]) return false
        return true
    }

    private fun keyAt(index: Int): String =
        String(bytes, lineStart[index], keyLen[index], Charsets.UTF_8)

    /** 解析行内候选:`词1 lv1 词2 lv2 ...`(与主词库 SortedTable.wordsAt 同语义)。 */
    private fun wordsAt(index: Int, limit: Int = Int.MAX_VALUE): List<Pair<String, Int>> {
        val out = ArrayList<Pair<String, Int>>()
        var p = lineStart[index] + keyLen[index] + 1
        val end = lineEnd[index]
        while (p < end && out.size < limit) {
            var q = p
            while (q < end && bytes[q] != SP) q++
            if (q >= end) break
            val word = String(bytes, p, q - p, Charsets.UTF_8)
            var r = q + 1
            var lv = 0
            var any = false
            while (r < end && bytes[r] != SP) {
                val c = bytes[r].toInt() - '0'.code
                if (c in 0..9) { lv = lv * 10 + c; any = true }
                r++
            }
            if (word.isNotEmpty() && any) out.add(word to lv)
            p = r + 1
        }
        return out
    }

    /** 整键精确查词(与主词库 exactWords 同语义)。 */
    fun exactWords(key: String): List<Pair<String, Int>> {
        if (!isReady || key.isEmpty()) return emptyList()
        val q = key.toByteArray(Charsets.UTF_8)
        val i = lowerBound(q)
        if (i >= lineStart.size || compareKeyAt(i, q) != 0) return emptyList()
        return wordsAt(i)
    }

    fun bestWord(key: String): Pair<String, Int>? {
        if (!isReady || key.isEmpty()) return null
        val q = key.toByteArray(Charsets.UTF_8)
        val i = lowerBound(q)
        if (i >= lineStart.size || compareKeyAt(i, q) != 0) return null
        return wordsAt(i, 1).firstOrNull()
    }

    /** 前缀补全:每个更长同前缀 key 取首选词,返回 (词, 等级, key长)(与主词库 prefixWords 同语义)。 */
    fun prefixWords(prefix: String, limit: Int): List<Triple<String, Int, Int>> {
        if (!isReady || prefix.isEmpty()) return emptyList()
        val q = prefix.toByteArray(Charsets.UTF_8)
        val out = ArrayList<Triple<String, Int, Int>>()
        var i = lowerBound(q)
        while (i < lineStart.size && out.size < limit) {
            if (!keyStartsWith(i, q)) break
            if (keyLen[i] != q.size) {
                wordsAt(i, 1).firstOrNull()?.let { (w, lv) -> out.add(Triple(w, lv, keyLen[i])) }
            }
            i++
        }
        return out
    }

    // ===== T9 数字码查询(排列二分,数字码由 key 字节即时换算) =====

    /** key(行 index)的数字码 与 查询数字码 逐位比较;prefixOnly 时 key 更长视为相等(前缀命中)。 */
    private fun compareDigitsAt(index: Int, digits: String, prefixOnly: Boolean): Int {
        val s = lineStart[index]
        val len = keyLen[index]
        val m = minOf(len, digits.length)
        for (k in 0 until m) {
            val b = bytes[s + k].toInt()
            val d = (if (b in 0..127) letter2digit[b] else 0).toInt().toChar()
            val q = digits[k]
            if (d != q) return if (d < q) -1 else 1
        }
        if (prefixOnly && len >= digits.length) return 0
        return len.compareTo(digits.length)
    }

    private fun t9LowerBound(digits: String): Int {
        var lo = 0
        var hi = t9Order.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (compareDigitsAt(t9Order[mid], digits, prefixOnly = false) < 0) lo = mid + 1 else hi = mid
        }
        return lo
    }

    /** 数字码精确查词:跨同码拼音合并,返回 (词, 等级, 拼音key)(与主词库 t9ExactWords 同语义)。 */
    fun t9ExactWords(digits: String): List<Triple<String, Int, String>> {
        if (!isReady || digits.isEmpty()) return emptyList()
        val out = ArrayList<Triple<String, Int, String>>()
        var i = t9LowerBound(digits)
        while (i < t9Order.size) {
            val ref = t9Order[i]
            if (compareDigitsAt(ref, digits, prefixOnly = false) != 0) break
            val key = keyAt(ref)
            for ((w, lv) in wordsAt(ref)) out.add(Triple(w, lv, key))
            i++
        }
        return out
    }

    /** 数字码前缀补全:每个更长同前缀码取首选词(与主词库 t9PrefixWords 同语义)。 */
    fun t9PrefixWords(digits: String, limit: Int): List<PinyinDictionary.T9PrefixHit> {
        if (!isReady || digits.isEmpty()) return emptyList()
        val out = ArrayList<PinyinDictionary.T9PrefixHit>()
        var i = t9LowerBound(digits)
        while (i < t9Order.size && out.size < limit) {
            val ref = t9Order[i]
            if (compareDigitsAt(ref, digits, prefixOnly = true) != 0) break
            if (keyLen[ref] != digits.length) {
                wordsAt(ref, 1).firstOrNull()?.let { (w, lv) ->
                    out.add(PinyinDictionary.T9PrefixHit(w, lv, keyLen[ref], keyAt(ref)))
                }
            }
            i++
        }
        return out
    }

    private companion object {
        private const val NL = '\n'.code.toByte()
        private const val TAB = '\t'.code.toByte()
        private const val SP = ' '.code.toByte()
        private const val HASH = '#'.code.toByte()
    }
}
