package com.lobster.input.keyboard.typing

/**
 * 分类符号板数据(对齐搜狗/百度/Gboard 符号面板课题调研结论):
 * 最近/中文/英文/括号/数学/序号/货币/箭头。数据经 scratch-keyboard-verify/test_symbols.py 验证
 * (类内无重复、关键符号覆盖、LRU 行为),键盘模式与语音模式共用。
 */
object SymbolData {

    /**
     * 9 宫格 1 键(@#)的固定高频符号候选(对齐豆包,顺序固定不做权重;
     * 经 scratch-keyboard-verify/test_key1_symbols.py 验证)。
     * 括号/书名号成套:点前半且光标后无文字 → 成套插入光标居中;有文字只插前半;后半直接上屏。
     */
    val key1Symbols: List<String> = listOf("#", "@", "（", "）", "*", "-", "+", "。", "～", "、", "《", "》", "/")

    /** 分类(最近除外——由 TypingPreferences.recentSymbols 动态提供)。 */
    data class Category(val id: String, val items: List<String>)

    val categories: List<Category> = listOf(
        Category("zh", listOf(
            "，", "。", "？", "！", "、", "；", "：", "“", "”", "‘", "’",
            "（", "）", "【", "】", "《", "》", "〈", "〉", "「", "」", "『", "』",
            "…", "—", "～", "·", "﹏", "＿", "￥"
        )),
        Category("en", listOf(
            ",", ".", "?", "!", ";", ":", "'", "\"", "(", ")", "[", "]",
            "{", "}", "<", ">", "@", "#", "$", "%", "^", "&", "*", "-",
            "_", "+", "=", "/", "\\", "|", "~", "`"
        )),
        Category("bracket", listOf(
            "（", "）", "(", ")", "［", "］", "[", "]", "｛", "｝", "{", "}",
            "〈", "〉", "《", "》", "「", "」", "『", "』", "【", "】", "〔", "〕",
            "«", "»", "‹", "›"
        )),
        Category("math", listOf(
            "+", "-", "×", "÷", "=", "≠", "≈", "<", ">", "≤", "≥", "±",
            "√", "∞", "%", "‰", "°", "π", "∑", "∫", "Δ", "∈", "∪", "∩",
            "∴", "∵", "⊥", "∥", "∠", "½", "¼", "¾", "²", "³"
        )),
        Category("num", listOf(
            "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩",
            "⑴", "⑵", "⑶", "⑷", "⑸", "⑹", "⑺", "⑻", "⑼", "⑽",
            "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ", "Ⅸ", "Ⅹ",
            "㈠", "㈡", "㈢", "㈣", "㈤"
        )),
        Category("currency", listOf(
            "￥", "¥", "$", "€", "£", "¢", "₩", "₽", "₹", "฿", "₫", "₴"
        )),
        Category("arrow", listOf(
            "←", "→", "↑", "↓", "↔", "↕", "↖", "↗", "↘", "↙", "⇐", "⇒",
            "★", "☆", "♥", "♡", "●", "○", "■", "□", "◆", "◇", "▲", "△",
            "※", "§", "№", "℃", "℉", "©", "®", "™"
        ))
    )

    const val RECENT_ID = "recent"

    /** 分类标签(5 语种列,繁体/粤语共用繁体列;自包含避免 MobileStrings 膨胀)。lang: zh/zh-Hant/yue/en/ru/ko。 */
    fun label(id: String, lang: String): String {
        val i = when (lang) { "en" -> 1; "ru" -> 2; "ko" -> 3; "zh-Hant", "yue" -> 4; else -> 0 }
        return when (id) {
            RECENT_ID -> listOf("最近", "Recent", "Недавние", "최근", "最近")[i]
            "zh" -> listOf("中文", "Chinese", "Кит.", "중문", "中文")[i]
            "en" -> listOf("英文", "English", "Англ.", "영문", "英文")[i]
            "bracket" -> listOf("括号", "Brackets", "Скобки", "괄호", "括號")[i]
            "math" -> listOf("数学", "Math", "Матем.", "수학", "數學")[i]
            "num" -> listOf("序号", "Numbering", "Нумерация", "번호", "序號")[i]
            "currency" -> listOf("货币", "Currency", "Валюта", "통화", "貨幣")[i]
            "arrow" -> listOf("箭头", "Arrows", "Стрелки", "화살표", "箭頭")[i]
            else -> id
        }
    }
}
