package com.lobster.input.keyboard.pinyin

import android.content.Context

/**
 * 整句语言模型(2026-07,九宫格智能整句核心):词级 bigram(主)+ 字级 bigram OOV veto(兜底)。
 *
 * 修复"打对拼音却出弱智句"(因为你搬过来→因为你包裹来):原整句 DP 只按词频打分,无上下文语言模型,
 * "包裹"高频词吃掉同码"搬过来"。本模型给整句 DP 的**跨词边界**打分:
 *  - 词级 bigram(主信号,精确):见过的词转移(堪称→完美 / 搬→过来 / 人民→是)给中心化 delta 奖励;
 *    字级恰好把这些判罕见(称→完 比 称→赞 罕见),故必须词级。数据 word_bigram.txt。
 *  - 字级 bigram OOV veto(兜底,仅罚):词 bigram 未覆盖的词对,用字级边界否决"从未出现的字搭配"
 *    (裹→来 类);只罚不奖,不引语料偏置。数据 char_bigram.txt。
 *
 * 只作用于**跨词边界**(词内已被词频编码);词频先验主导,LM 只在同码歧义时裁决。
 * 参数与 tools/keyboard-verify/engine_lm.py 逐一对齐(全量回归电池 13/13 验证)。
 *
 * 数据格式(与主词库同,UTF-8 文本):每行 `key\tk2 w2 k3 w3 ...`,key/k 为字或词,w 为量化整数。
 * 内存:HashMap 加载(char ~5.8K key,word ~35K key;权重存 Short 省内存),后台异步挂载不阻塞冷启动。
 */
class SentenceLanguageModel {

    // key1 -> (key2 -> 量化权重)。word 用词字符串,char 用单字字符串(统一 String,简化实现)。
    private var wordBi: HashMap<String, HashMap<String, Short>> = HashMap()
    private var charBi: HashMap<String, HashMap<String, Short>> = HashMap()
    @Volatile var isReady = false
        private set

    fun load(context: Context, charAsset: String = "char_bigram.txt", wordAsset: String = "word_bigram.txt") {
        charBi = parse(context, charAsset, 6_000)
        wordBi = parse(context, wordAsset, 40_000)
        isReady = true
    }

    private fun parse(context: Context, asset: String, cap: Int): HashMap<String, HashMap<String, Short>> {
        val map = HashMap<String, HashMap<String, Short>>(cap)
        context.assets.open(asset).bufferedReader(Charsets.UTF_8).useLines { lines ->
            for (line in lines) {
                val tab = line.indexOf('\t')
                if (tab <= 0) continue
                val k1 = line.substring(0, tab)
                val body = line.substring(tab + 1)
                val toks = body.split(' ')
                val inner = HashMap<String, Short>(toks.size / 2 + 1)
                var i = 0
                while (i + 1 < toks.size) {
                    val k2 = toks[i]
                    val w = toks[i + 1].toIntOrNull()
                    if (k2.isNotEmpty() && w != null) inner[k2] = w.coerceIn(-32768, 32767).toShort()
                    i += 2
                }
                if (inner.isNotEmpty()) map[k1] = inner
            }
        }
        return map
    }

    /**
     * 跨词边界打分:前词 pw → 当前词 w。词 bigram 命中用中心化 delta(可正可负),
     * 未命中回退字级 OOV veto(仅罚)。整句 DP 每次词转移调用一次。
     */
    fun boundaryScore(pw: String, w: String): Int {
        if (!isReady || pw.isEmpty() || w.isEmpty()) return 0
        val wd = wordDelta(pw, w)
        if (wd != null) return wd
        return charVeto(pw[pw.length - 1], w[0])
    }

    /** 词转移中心化 delta;未覆盖返回 null(交给字 veto)。 */
    private fun wordDelta(pw: String, w: String): Int? {
        val d = wordBi[pw] ?: return null
        val b = d[w] ?: return null
        val x = ((b - WREF) * WBETA).toInt()
        return when {
            x > WHI -> WHI
            x < -WLO -> -WLO
            else -> x
        }
    }

    /** 字级边界:只罚不奖,按罕见度分级(未见=满罚,罕见=轻罚,常见=0)。 */
    private fun charVeto(prevLast: Char, curFirst: Char): Int {
        val d = charBi[prevLast.toString()] ?: return -LM_LO
        val wv = d[curFirst.toString()] ?: return -LM_LO
        val x = ((wv - LM_REF) * LM_BETA).toInt()
        if (x >= 0) return 0
        return if (x > -LM_LO) x else -LM_LO
    }

    companion object {
        // 与 tools/keyboard-verify/engine_lm.py 逐一对齐(勿单独改动,须同步 Python 参照并重跑回归)
        private const val WREF = -700          // 词条件对数概率参考(约中等转移)
        private const val WBETA = 0.13         // 词 delta 斜率
        private const val WHI = 55             // 词 delta 正激励上限(突出好搭配)
        private const val WLO = 40             // 词 delta 负罚上限
        private const val LM_REF = -520        // 字 veto:高于此不罚
        private const val LM_BETA = 0.16       // 字 veto 斜率
        private const val LM_LO = 70           // 字 veto 单边界最大罚
    }
}
