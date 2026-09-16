package com.lobster.input.keyboard.typing

/**
 * 智能标点:成对符号自动配对(输 "(" 自动补 ")" 并把光标放中间)。
 * 中英标点的全/半角自适应由布局层按 chineseMode 决定(见 KeyboardLayoutFactory),此处只管配对。
 */
object SmartPunctuation {

    /** opening → closing。覆盖中英文括号、引号、书名号。 */
    private val pairs = linkedMapOf(
        "(" to ")", "（" to "）",
        "[" to "]", "【" to "】",
        "{" to "}", "「" to "」", "『" to "』",
        "<" to ">", "《" to "》",
        "“" to "”", "‘" to "’"
    )

    fun closingFor(opening: String): String? = pairs[opening]

    fun isPairOpening(s: String): Boolean = pairs.containsKey(s)
}
