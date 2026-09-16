package com.lobster.input.keyboard.pinyin

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.lobster.input.core.network.ApiConfig

/**
 * 用户个性化词典:选词调频 + bigram 句子联想。
 * 写入采用 debounce(2s) 批量刷盘,避免高频 I/O。
 */
class UserDictionary(private val context: Context) {

    private val freq = HashMap<String, Int>()
    private val bigram = HashMap<String, LinkedHashMap<String, Int>>()
    private val blacklist = HashSet<String>()
    /** 用户自造词:拼音 key → (词 → 选中次数)。digits 由拼音派生,加载时重建。 */
    private val phrases = HashMap<String, LinkedHashMap<String, Int>>()
    private val phraseDigits = HashMap<String, String>()
    private val handler = Handler(Looper.getMainLooper())
    private var dirtyFreq = false
    private var dirtyBigram = false
    private var dirtyBlacklist = false
    private var dirtyPhrases = false
    private val flushRunnable = Runnable { flushNow() }

    fun load() {
        prefs().getString(KEY_FREQ, null)?.let { raw ->
            for (entry in raw.split(';')) {
                val i = entry.lastIndexOf(':')
                if (i <= 0) continue
                val w = entry.substring(0, i)
                val c = entry.substring(i + 1).toIntOrNull() ?: continue
                freq[w] = c
            }
        }
        prefs().getString(KEY_BIGRAM, null)?.let { raw ->
            for (line in raw.split('\n')) {
                val tab = line.indexOf('\t')
                if (tab <= 0) continue
                val a = line.substring(0, tab)
                val map = LinkedHashMap<String, Int>()
                for (pair in line.substring(tab + 1).split(' ')) {
                    val k = pair.lastIndexOf(':')
                    if (k <= 0) continue
                    map[pair.substring(0, k)] = pair.substring(k + 1).toIntOrNull() ?: continue
                }
                if (map.isNotEmpty()) bigram[a] = map
            }
        }
        prefs().getString(KEY_BLACKLIST, null)?.let { raw ->
            for (w in raw.split('\n')) if (w.isNotEmpty()) blacklist.add(w)
        }
        prefs().getString(KEY_PHRASES, null)?.let { raw ->
            // 行格式:pinyin\tword:count word:count ...
            for (line in raw.split('\n')) {
                val tab = line.indexOf('\t')
                if (tab <= 0) continue
                val py = line.substring(0, tab)
                val map = LinkedHashMap<String, Int>()
                for (pair in line.substring(tab + 1).split(' ')) {
                    val k = pair.lastIndexOf(':')
                    if (k <= 0) continue
                    map[pair.substring(0, k)] = pair.substring(k + 1).toIntOrNull() ?: continue
                }
                if (map.isNotEmpty()) {
                    phrases[py] = map
                    toDigits(py)?.let { phraseDigits[py] = it }
                }
            }
        }
    }

    private fun toDigits(pinyin: String): String? {
        val sb = StringBuilder(pinyin.length)
        for (c in pinyin) {
            val d = when (c) {
                'a', 'b', 'c' -> '2'; 'd', 'e', 'f' -> '3'; 'g', 'h', 'i' -> '4'
                'j', 'k', 'l' -> '5'; 'm', 'n', 'o' -> '6'; 'p', 'q', 'r', 's' -> '7'
                't', 'u', 'v' -> '8'; 'w', 'x', 'y', 'z' -> '9'
                else -> return null
            }
            sb.append(d)
        }
        return sb.toString()
    }

    /** 学习自造词(引擎已做音节/长度护栏)。 */
    fun learnPhrase(pinyin: String, digits: String, word: String) {
        val map = phrases.getOrPut(pinyin) { LinkedHashMap() }
        map[word] = (map[word] ?: 0) + 1
        phraseDigits[pinyin] = digits
        blacklist.remove(word)
        if (map.size > MAX_PHRASE_PER_KEY) {
            val keep = map.entries.sortedByDescending { it.value }.take(MAX_PHRASE_PER_KEY)
            map.clear(); for (e in keep) map[e.key] = e.value
        }
        if (phrases.size > MAX_PHRASE_KEYS) {
            phrases.entries.minByOrNull { it.value.values.sum() }?.key?.let {
                if (it != pinyin) { phrases.remove(it); phraseDigits.remove(it) }
            }
        }
        dirtyPhrases = true
        scheduleFlush()
    }

    /** 遍历全部自造词:(拼音, 数字码, 词, 次数)。候选生成用。 */
    inline fun eachPhrase(action: (pinyin: String, digits: String, word: String, count: Int) -> Unit) {
        for ((py, map) in phrasesView()) {
            val d = phraseDigitsView()[py] ?: continue
            for ((w, c) in map) action(py, d, w, c)
        }
    }

    fun phrasesView(): Map<String, Map<String, Int>> = phrases
    fun phraseDigitsView(): Map<String, String> = phraseDigits

    fun bonus(word: String): Int = freq[word] ?: 0

    fun isBlacklisted(word: String): Boolean = blacklist.contains(word)

    /** 长按删词:加入黑名单(候选不再出现)+ 清掉已学调频/联想/自造词。 */
    fun forget(word: String) {
        if (word.isEmpty()) return
        blacklist.add(word)
        if (blacklist.size > MAX_BLACKLIST) {
            val it = blacklist.iterator(); if (it.hasNext()) { it.next(); it.remove() }
        }
        freq.remove(word)
        bigram.remove(word)
        for (m in bigram.values) m.remove(word)
        for (m in phrases.values) m.remove(word)
        phrases.entries.removeAll { it.value.isEmpty() }
        dirtyFreq = true; dirtyBigram = true; dirtyBlacklist = true; dirtyPhrases = true
        scheduleFlush()
    }

    fun learn(word: String) {
        if (word.isEmpty()) return
        freq[word] = (freq[word] ?: 0) + 1
        if (freq.size > MAX_FREQ) {
            val keep = freq.entries.sortedByDescending { it.value }.take(MAX_FREQ * 3 / 4)
            freq.clear(); for (e in keep) freq[e.key] = e.value
        }
        scheduleFlush(freq = true)
    }

    fun learnPair(a: String, b: String) {
        if (a.isEmpty() || b.isEmpty() || a == b) return
        val map = bigram.getOrPut(a) { LinkedHashMap() }
        map[b] = (map[b] ?: 0) + 1
        if (map.size > MAX_NEXT) {
            val keep = map.entries.sortedByDescending { it.value }.take(MAX_NEXT)
            map.clear(); for (e in keep) map[e.key] = e.value
        }
        if (bigram.size > MAX_BIGRAM_KEYS) {
            bigram.entries.minByOrNull { it.value.values.sum() }?.key?.let { if (it != a) bigram.remove(it) }
        }
        scheduleFlush(bigram = true)
    }

    fun nextWords(a: String): List<String> =
        bigram[a]?.entries?.sortedByDescending { it.value }?.map { it.key } ?: emptyList()

    /** 词对共现次数(整句 DP 的 bigram 转移加成用)。 */
    fun pairCount(a: String, b: String): Int = bigram[a]?.get(b) ?: 0

    private fun scheduleFlush(freq: Boolean = false, bigram: Boolean = false) {
        if (freq) dirtyFreq = true
        if (bigram) dirtyBigram = true
        handler.removeCallbacks(flushRunnable)
        handler.postDelayed(flushRunnable, FLUSH_DELAY_MS)
    }

    private fun flushNow() {
        val editor = prefs().edit()
        if (dirtyFreq) {
            val sb = StringBuilder()
            for ((w, c) in freq) {
                if (w.contains(';') || w.contains(':')) continue
                if (sb.isNotEmpty()) sb.append(';')
                sb.append(w).append(':').append(c)
            }
            editor.putString(KEY_FREQ, sb.toString())
            dirtyFreq = false
        }
        if (dirtyBigram) {
            val sb = StringBuilder()
            for ((a, map) in bigram) {
                if (a.contains('\t') || a.contains(' ') || a.contains(':')) continue
                if (sb.isNotEmpty()) sb.append('\n')
                sb.append(a).append('\t')
                var first = true
                for ((b, c) in map) {
                    if (b.contains(' ') || b.contains(':')) continue
                    if (!first) sb.append(' ')
                    sb.append(b).append(':').append(c); first = false
                }
            }
            editor.putString(KEY_BIGRAM, sb.toString())
            dirtyBigram = false
        }
        if (dirtyBlacklist) {
            editor.putString(KEY_BLACKLIST, blacklist.filter { !it.contains('\n') }.joinToString("\n"))
            dirtyBlacklist = false
        }
        if (dirtyPhrases) {
            val sb = StringBuilder()
            for ((py, map) in phrases) {
                if (py.contains('\t') || py.contains(' ') || py.contains('\n')) continue
                if (sb.isNotEmpty()) sb.append('\n')
                sb.append(py).append('\t')
                var first = true
                for ((w, c) in map) {
                    if (w.contains(' ') || w.contains(':')) continue
                    if (!first) sb.append(' ')
                    sb.append(w).append(':').append(c); first = false
                }
            }
            editor.putString(KEY_PHRASES, sb.toString())
            dirtyPhrases = false
        }
        editor.apply()
    }

    private fun prefs() = context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)

    companion object {
        private const val KEY_FREQ = "ime_pinyin_user_freq"
        private const val KEY_BIGRAM = "ime_pinyin_user_bigram"
        private const val KEY_BLACKLIST = "ime_pinyin_user_blacklist"
        private const val KEY_PHRASES = "ime_pinyin_user_phrases"
        private const val MAX_FREQ = 2000
        private const val MAX_BIGRAM_KEYS = 1500
        private const val MAX_NEXT = 16
        private const val MAX_BLACKLIST = 500
        private const val MAX_PHRASE_KEYS = 500
        private const val MAX_PHRASE_PER_KEY = 4
        private const val FLUSH_DELAY_MS = 2000L
    }
}
