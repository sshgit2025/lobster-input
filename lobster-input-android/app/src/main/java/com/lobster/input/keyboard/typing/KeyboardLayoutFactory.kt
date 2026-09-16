package com.lobster.input.keyboard.typing

/**
 * 键盘布局工厂(工厂模式)。按当前模式产出 [行[键]],不含状态或绘制。
 */
class KeyboardLayoutFactory(private val host: TypingKeyboardHost) {

    fun build(state: LayoutState): List<List<KeySpec>> = when {
        state.numberPage -> numberRows(state)
        state.symbolPage -> symbolRows(state)
        state.lang == InputLang.RU -> russianRows(state)
        state.lang == InputLang.KO -> koreanRows(state)
        state.nineGrid -> nineGridRows(state)
        else -> qwertyRows(state)
    }

    data class LayoutState(
        val chineseMode: Boolean,
        val nineGrid: Boolean,
        val symbolPage: Boolean,
        val numberPage: Boolean,
        val symbolPageIndex: Int,
        val lang: InputLang = if (chineseMode) InputLang.ZH else InputLang.EN,
        /** 模式轮换键的下一站短标签(画在循环图标下方,预告下一模式)。 */
        val nextModeLabel: String = ""
    )

    private fun langKey(state: LayoutState, weight: Float) =
        KeySpec(KeyType.LANG, when (state.lang) {
            InputLang.ZH -> host.localize(KbStr.CH)
            InputLang.EN -> host.localize(KbStr.EN)
            else -> state.lang.keyLabel
        }, weight = weight)

    /**
     * 模式轮换键(问题3:替代"切26"和长按切语种):自绘循环箭头图标 + 下一模式短标签,
     * 全部打字布局(九宫格/26键/俄/韩)常驻同位,循环 中9→中26→EN→РУ→한。
     */
    private fun modeCycleKey(state: LayoutState, weight: Float) =
        KeySpec(KeyType.MODE_CYCLE, sub = state.nextModeLabel, weight = weight)

    private fun comma(state: LayoutState, weight: Float) =
        KeySpec(KeyType.SYM_CHAR, "，", value = if (state.chineseMode) "，" else ",", weight = weight)

    private fun period(state: LayoutState, weight: Float) =
        KeySpec(KeyType.SYM_CHAR, "。", value = if (state.chineseMode) "。" else ".", weight = weight)

    private fun qwertyRows(state: LayoutState): List<List<KeySpec>> {
        val row1Long = "1234567890"
        fun lettersWithLong(s: String, longs: String?) = s.mapIndexed { i, c ->
            KeySpec(KeyType.LETTER, c.toString(), longValue = longs?.getOrNull(i)?.toString())
        }
        val row3 = ArrayList<KeySpec>().apply {
            add(KeySpec(KeyType.SHIFT, weight = 1.5f))
            addAll(lettersWithLong("zxcvbnm", null))
            // 中文 26 键分词键(')收进 row3(对齐 iOS),把 row4 槽位让给模式轮换键
            if (state.chineseMode) add(KeySpec(KeyType.SYLLABLE, host.localize(KbStr.SYLLABLE), weight = 1.0f))
            add(KeySpec(KeyType.DELETE, weight = 1.5f))
        }
        val row4 = listOf(
            langKey(state, 1.3f),
            KeySpec(KeyType.SYMBOL, "?123", weight = 1.1f),
            modeCycleKey(state, 0.95f),
            KeySpec(KeyType.SPACE, host.localize(KbStr.SPACE), weight = 2.6f),
            comma(state, 0.95f),
            period(state, 0.95f),
            KeySpec(KeyType.ENTER, host.enterKeyLabel(), weight = 1.4f)
        )
        return listOf(
            lettersWithLong("qwertyuiop", row1Long),
            listOf(KeySpec(KeyType.GAP, weight = 0.5f)) + lettersWithLong("asdfghjkl", null) + listOf(KeySpec(KeyType.GAP, weight = 0.5f)),
            row3, row4
        )
    }

    /**
     * 俄语 ЙЦУКЕН(标准移动端 3 行:11/11/9+shift+del,对齐 Gboard/iOS 系统俄语键盘)。
     * ё=长按 е,ъ=长按 ь(业界惯例:低频字母走长按不占键位)。
     */
    private fun russianRows(state: LayoutState): List<List<KeySpec>> {
        fun letters(s: String, longs: Map<Char, String> = emptyMap()) =
            s.map { KeySpec(KeyType.LETTER, it.toString(), longValue = longs[it]) }
        val row3 = ArrayList<KeySpec>().apply {
            add(KeySpec(KeyType.SHIFT, weight = 1.3f))
            addAll(letters("ячсмитьбю", mapOf('ь' to "ъ")))
            add(KeySpec(KeyType.DELETE, weight = 1.3f))
        }
        val row4 = listOf(
            langKey(state, 1.3f),
            KeySpec(KeyType.SYMBOL, "?123", weight = 1.1f),
            modeCycleKey(state, 0.95f),
            KeySpec(KeyType.SPACE, host.localize(KbStr.SPACE), weight = 2.6f),
            comma(state, 0.95f),
            period(state, 0.95f),
            KeySpec(KeyType.ENTER, host.enterKeyLabel(), weight = 1.4f)
        )
        return listOf(
            letters("йцукенгшщзх", mapOf('е' to "ё")),
            letters("фывапролджэ"),
            row3, row4
        )
    }

    /**
     * 韩语 2-set 두벌식(左辅音右元音,对齐 Gboard/iOS 系统韩语键盘)。
     * 双辅音/复合元音走 shift(ㅂ→ㅃ、ㅐ→ㅒ);复合元音 ㅘㅝㅢ 等由组字自动机连击合成。
     */
    private fun koreanRows(state: LayoutState): List<List<KeySpec>> {
        fun jamo(s: String, shifts: Map<Char, String> = emptyMap()) =
            s.map { KeySpec(KeyType.LETTER, it.toString(), shiftValue = shifts[it]) }
        val row1Shift = mapOf('ㅂ' to "ㅃ", 'ㅈ' to "ㅉ", 'ㄷ' to "ㄸ", 'ㄱ' to "ㄲ", 'ㅅ' to "ㅆ", 'ㅐ' to "ㅒ", 'ㅔ' to "ㅖ")
        val row3 = ArrayList<KeySpec>().apply {
            add(KeySpec(KeyType.SHIFT, weight = 1.3f))
            addAll(jamo("ㅋㅌㅊㅍㅠㅜㅡ"))
            add(KeySpec(KeyType.DELETE, weight = 1.3f))
        }
        val row4 = listOf(
            langKey(state, 1.3f),
            KeySpec(KeyType.SYMBOL, "?123", weight = 1.1f),
            modeCycleKey(state, 0.95f),
            KeySpec(KeyType.SPACE, host.localize(KbStr.SPACE), weight = 2.6f),
            comma(state, 0.95f),
            period(state, 0.95f),
            KeySpec(KeyType.ENTER, host.enterKeyLabel(), weight = 1.4f)
        )
        return listOf(
            jamo("ㅂㅈㄷㄱㅅㅛㅕㅑㅐㅔ", row1Shift),
            listOf(KeySpec(KeyType.GAP, weight = 0.5f)) + jamo("ㅁㄴㅇㄹㅎㅗㅓㅏㅣ") + listOf(KeySpec(KeyType.GAP, weight = 0.5f)),
            row3, row4
        )
    }

    private fun nineGridRows(state: LayoutState): List<List<KeySpec>> = listOf(
        // 对齐豆包/搜狗:第1列逗号,分词键=数字1(右上角小数字),字母键显示对应数字 2-9,单独 0 键。
        listOf(
            comma(state, 1.0f),
            // 1 键位:@#(对齐豆包)——点击在候选栏出固定高频符号候选(SymbolData.key1Symbols),长按出数字 1
            KeySpec(KeyType.SYM_CANDS, "@#", sub = "1", longValue = "1", weight = 1.3f),
            KeySpec(KeyType.T9, "ABC", sub = "2", value = "2", longValue = "2", weight = 1.3f),
            KeySpec(KeyType.T9, "DEF", sub = "3", value = "3", longValue = "3", weight = 1.3f),
            KeySpec(KeyType.DELETE, weight = 1.1f)
        ),
        listOf(
            langKey(state, 1.0f),
            KeySpec(KeyType.T9, "GHI", sub = "4", value = "4", longValue = "4", weight = 1.3f),
            KeySpec(KeyType.T9, "JKL", sub = "5", value = "5", longValue = "5", weight = 1.3f),
            KeySpec(KeyType.T9, "MNO", sub = "6", value = "6", longValue = "6", weight = 1.3f),
            KeySpec(KeyType.SYMBOL, host.localize(KbStr.SYMBOL), weight = 1.1f)
        ),
        listOf(
            // 删「切26」布局键(已收进候选栏齿轮工具页);123 移左,0 键放最右(对齐豆包/搜狗)
            KeySpec(KeyType.NUM, "123", weight = 1.0f),
            KeySpec(KeyType.T9, "PQRS", sub = "7", value = "7", longValue = "7", weight = 1.3f),
            KeySpec(KeyType.T9, "TUV", sub = "8", value = "8", longValue = "8", weight = 1.3f),
            KeySpec(KeyType.T9, "WXYZ", sub = "9", value = "9", longValue = "9", weight = 1.3f),
            KeySpec(KeyType.SYM_CHAR, "0", value = "0", weight = 1.0f)
        ),
        listOf(
            // 模式轮换键(替代「切26」:布局+语种统一循环,全布局常驻,业务闭环)
            modeCycleKey(state, 1.0f),
            period(state, 1.0f),
            KeySpec(KeyType.SPACE, host.localize(KbStr.SPACE), weight = 3.2f),
            KeySpec(KeyType.ENTER, host.enterKeyLabel(), weight = 1.3f)
        )
    )

    private fun numberRows(state: LayoutState): List<List<KeySpec>> {
        fun n(d: String) = KeySpec(KeyType.SYM_CHAR, d, value = d)
        return listOf(
            listOf(n("1"), n("2"), n("3"), KeySpec(KeyType.DELETE, weight = 1f)),
            listOf(n("4"), n("5"), n("6"), KeySpec(KeyType.SYM_CHAR, "@", value = "@")),
            listOf(n("7"), n("8"), n("9"), KeySpec(KeyType.ENTER, host.enterKeyLabel(), weight = 1f)),
            listOf(
                KeySpec(KeyType.ALPHA, if (state.chineseMode) host.localize(KbStr.PINYIN) else host.localize(KbStr.ABC)),
                KeySpec(KeyType.SYM_CHAR, ".", value = "."),
                n("0"),
                comma(state, 1f)
            )
        )
    }

    private val zhPunct1 = listOf("，", "。", "？", "！", "：", "；", "、", "～", "…", "—")
    private val zhPunct2 = listOf("（", "）", "【", "】", "《", "》", "“", "”", "‘", "’")
    private val enPunct1 = listOf("@", "#", "$", "%", "&", "*", "-", "+", "(", ")")
    private val enPunct2 = listOf("_", "=", "/", "\\", "|", "~", "<", ">", "[", "]")

    private fun symbolRows(state: LayoutState): List<List<KeySpec>> {
        fun chars(list: List<String>) = list.map { KeySpec(KeyType.SYM_CHAR, it, value = it) }
        val digits = "1234567890".map { KeySpec(KeyType.SYM_CHAR, it.toString(), value = it.toString()) }
        val punctRow = if (state.chineseMode) {
            if (state.symbolPageIndex == 0) zhPunct1 else zhPunct2
        } else {
            if (state.symbolPageIndex == 0) enPunct1 else enPunct2
        }
        val row3 = ArrayList<KeySpec>().apply {
            add(KeySpec(KeyType.SYM_PAGE, if (state.symbolPageIndex == 0) "1/2" else "2/2", weight = 1.5f))
            addAll(chars(if (state.chineseMode) listOf("·", "「", "」", "—", "%", "&") else listOf(".", ",", "?", "!", "'", "\"")))
            add(KeySpec(KeyType.DELETE, weight = 1.5f))
        }
        val row4 = listOf(
            KeySpec(KeyType.ALPHA, if (state.chineseMode) host.localize(KbStr.PINYIN) else host.localize(KbStr.ABC), weight = 1.5f),
            // 分类符号板入口(最近/数学/序号/货币/箭头等全量分类,对齐搜狗「更多符号」)
            KeySpec(KeyType.SYM_BOARD, "√π", weight = 1.0f),
            KeySpec(KeyType.EMOJI, "😊", weight = 1.0f),
            KeySpec(KeyType.CLIP, "📋", weight = 1.0f),
            KeySpec(KeyType.SPACE, host.localize(KbStr.SPACE), weight = 2.7f),
            comma(state, 1.0f),
            KeySpec(KeyType.ENTER, host.enterKeyLabel(), weight = 1.6f)
        )
        return listOf(digits, chars(punctRow), row3, row4)
    }
}
