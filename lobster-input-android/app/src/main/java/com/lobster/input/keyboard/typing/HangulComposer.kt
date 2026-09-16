package com.lobster.input.keyboard.typing

/**
 * Hangul 2-set(두벌식)组字自动机(与 scratch-keyboard-verify/hangul_composer.py 参照实现逐行对齐)。
 * Unicode:音节 = 0xAC00 + (cho*21 + jung)*28 + jong。
 * 复合中声(ㅗ+ㅏ=ㅘ)、复合终声(ㄹ+ㄱ=ㄺ)、终声借调(닭+이=달기→닭이)、逐 jamo 退格拆解。
 */
class HangulComposer {

    private var cho: Char? = null
    private var jung: Char? = null
    private var jong: Char? = null

    fun isEmpty() = cho == null && jung == null && jong == null

    /** 当前组合中显示的字符(未定稿,恒 ≤1 字符)。 */
    fun current(): String {
        val c = cho; val j = jung
        if (c != null && j != null) {
            val ci = CHO.indexOf(c)
            val ji = JUNG.indexOf(j)
            val gi = jong?.let { JONG.indexOf(it) } ?: 0
            return ((0xAC00 + (ci * 21 + ji) * 28 + gi).toChar()).toString()
        }
        if (c != null) return c.toString()
        if (j != null) return j.toString()
        return ""
    }

    fun reset() { cho = null; jung = null; jong = null }

    /** 输入一个 compatibility jamo,返回需定稿上屏的文本(可空)。 */
    fun feed(jamo: Char): String =
        if (jamo in VOWELS) feedVowel(jamo) else feedConsonant(jamo)

    private fun feedConsonant(c: Char): String {
        if (cho == null && jung == null) { cho = c; return "" }
        if (jung == null) {
            // 只有 cho:辅音+辅音 → 前一个定稿,新辅音开始(双辅音走 shift,不自动合并)
            val out = cho.toString()
            reset(); cho = c
            return out
        }
        if (jong == null) {
            // 【修 孤元音丢辅音】终声必须挂在完整 cho+jung 音节上;孤元音(cho=null)挂终声后
            // current() 渲染不出、辅音被静默吞掉(ㅏ+ㄱ 曾丢 ㄱ)。标准行为:孤元音定稿,辅音另起。
            if (cho != null && c in JONG_SET) { jong = c; return "" }
            // 孤元音 / ㄸㅃㅉ 不能作终声:定稿当前,新起
            val out = current()
            reset(); cho = c
            return out
        }
        val comb = JONG_COMBINE[jong!! to c]
        if (comb != null) { jong = comb; return "" }
        val out = current()
        reset(); cho = c
        return out
    }

    private fun feedVowel(v: Char): String {
        val g = jong
        if (g != null) {
            // 终声借调:复合终声拆最后一个辅音做新 cho,单终声整个移走
            val split = JONG_SPLIT[g]
            if (split != null) {
                jong = split.first
                val out = current()
                reset(); cho = split.second; jung = v
                return out
            }
            jong = null
            val out = current()
            reset(); cho = g; jung = v
            return out
        }
        val j = jung
        if (j != null) {
            val comb = JUNG_COMBINE[j to v]
            if (comb != null) { jung = comb; return "" }
            val out = current()
            reset(); jung = v
            return out
        }
        jung = v
        return ""
    }

    /** 组合态内逐 jamo 拆解;返回 false 表示无组合态(需删文档字符)。 */
    fun backspace(): Boolean {
        val g = jong
        if (g != null) {
            jong = JONG_SPLIT[g]?.first
            return true
        }
        val j = jung
        if (j != null) {
            val split = JUNG_SPLIT[j]
            jung = split?.first
            return true
        }
        if (cho != null) { cho = null; return true }
        return false
    }

    companion object {
        private val CHO = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ".toCharArray()
        private val JUNG = "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ".toCharArray()
        // JONG[0] 为占位(无终声);indexOf 用于 Unicode 组装
        private val JONG = charArrayOf(' ', 'ㄱ', 'ㄲ', 'ㄳ', 'ㄴ', 'ㄵ', 'ㄶ', 'ㄷ', 'ㄹ', 'ㄺ', 'ㄻ', 'ㄼ', 'ㄽ', 'ㄾ', 'ㄿ', 'ㅀ', 'ㅁ', 'ㅂ', 'ㅄ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ')
        private val JONG_SET = JONG.drop(1).toSet()
        private val VOWELS = JUNG.toSet()

        private val JUNG_COMBINE = mapOf(
            ('ㅗ' to 'ㅏ') to 'ㅘ', ('ㅗ' to 'ㅐ') to 'ㅙ', ('ㅗ' to 'ㅣ') to 'ㅚ',
            ('ㅜ' to 'ㅓ') to 'ㅝ', ('ㅜ' to 'ㅔ') to 'ㅞ', ('ㅜ' to 'ㅣ') to 'ㅟ',
            ('ㅡ' to 'ㅣ') to 'ㅢ'
        )
        private val JONG_COMBINE = mapOf(
            ('ㄱ' to 'ㅅ') to 'ㄳ', ('ㄴ' to 'ㅈ') to 'ㄵ', ('ㄴ' to 'ㅎ') to 'ㄶ',
            ('ㄹ' to 'ㄱ') to 'ㄺ', ('ㄹ' to 'ㅁ') to 'ㄻ', ('ㄹ' to 'ㅂ') to 'ㄼ', ('ㄹ' to 'ㅅ') to 'ㄽ',
            ('ㄹ' to 'ㅌ') to 'ㄾ', ('ㄹ' to 'ㅍ') to 'ㄿ', ('ㄹ' to 'ㅎ') to 'ㅀ',
            ('ㅂ' to 'ㅅ') to 'ㅄ'
        )
        private val JUNG_SPLIT = JUNG_COMBINE.entries.associate { it.value to it.key }
        private val JONG_SPLIT = JONG_COMBINE.entries.associate { it.value to it.key }
    }
}
