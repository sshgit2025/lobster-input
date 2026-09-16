package com.lobster.input.keyboard.typing

/**
 * 候选栏标点联想 v2(2026-07-23,上下文感知模型;方案见 docs/keyboard/候选栏标点联想设计方案.md §3)。
 *
 * 中文上屏词/句后,按 lastWord 词法信号 + 光标前句内上下文联合裁决,产出 1~2 个标点候选,
 * 注入联想流头部。设计哲学(证据驱动:语燕输入法开源实现 + 聊天标点用户研究):
 *   - 逗号是默认主力,句号永不占首位(聊天句号有"冷漠/生气"语义)
 *   - ?/! 按句型置顶,第二槽给逗号("你好吗,我很好"式续句)
 *   - 规则小而硬编码:疑问/感叹/连词三张词表 + 句长/逗号数两个上下文统计量
 *
 * 抑制(返回空):beforeText 以句读标点结尾(刚打过标点,含语音上屏)/单字中性组词中途。
 * 英文/俄文/韩文不做(业界调研:Gboard/iOS QuickType/SwiftKey 均无此待遇)。
 *
 * 纯逻辑:与 iOS PunctuationSuggestion.swift / Harmony PunctuationSuggestion.ets /
 * tools/keyboard-verify/test_punct_suggestion.py 模型逐行镜像,改动须四方同步。
 */
object PunctuationSuggestion {

    private val QUESTION_TAILS = listOf("吗", "嘛", "呢")
    private val QUESTION_CONTAINS = listOf(
        "什么", "怎么", "为什么", "谁", "哪里", "哪个", "哪儿", "哪些", "哪天",
        "何时", "多少", "多久", "几点",
        "难道", "岂不", "是否", "能否", "可否", "可不可以", "有没有",
        "行不行", "好不好", "是不是", "对不对"
    )
    private val EXCLAIM_TAILS = listOf("啊", "呀", "啦", "哇", "呐", "噢", "呗", "哟")
    // 情绪词用包含匹配("笑死我了"式后缀);致谢类除"加油"外同(加油站误伤→加油用尾部匹配)
    private val EXCLAIM_CONTAINS = listOf(
        "笑死", "气死", "救命", "绝了", "好家伙", "哈哈", "累死", "馋死",
        "爱死", "吓死", "羡慕死",
        "谢谢", "感谢", "恭喜", "祝贺", "辛苦"
    )
    private val EXCLAIM_WORD_TAILS = listOf("加油")
    private val CONNECTIVES = setOf(
        "但是", "可是", "不过", "然而", "然后", "接着", "而且", "并且", "所以",
        "因此", "因为", "如果", "要是", "既然", "虽然", "尽管", "即使", "哪怕",
        "除非", "由于", "或者", "还有", "另外", "首先", "其次", "比如", "特别是",
        "尤其是", "对了", "话说", "顺便", "总之", "反正", "其实"
    )

    /** 句读标点:光标前文本以这些结尾 → 刚打过标点,抑制(等下一个词)。闭合括号不在内。 */
    private val MID_PUNCTS = setOf('，', '。', '！', '？', '、', '～', '…', '：', '；', ',', '.', '!', '?', ';', ':')
    /** 句末终止符:切句边界。 */
    private val SENTENCE_ENDS = setOf('。', '？', '！', '!', '?', '…', '～', '\n')
    /** 中性长句阈值(聊天分句常见 4~10 字;≥12 或已有逗号说明在写复合句,收尾概率上升)。 */
    private const val CLAUSE_LEN_END = 12

    /** 光标前文本 → 当前句片段(自最近句末符之后,截尾空白)。 */
    private fun clauseOf(beforeText: String): String {
        val t = beforeText.trimEnd()
        var cut = 0
        t.forEachIndexed { i, ch -> if (ch in SENTENCE_ENDS) cut = i + 1 }
        return t.substring(cut)
    }

    fun suggestions(lastWord: String?, beforeText: String): List<String> {
        if (lastWord.isNullOrEmpty()) return emptyList()
        val tail = beforeText.trimEnd()
        if (tail.isNotEmpty() && tail.last() in MID_PUNCTS) return emptyList() // 刚打过标点
        // 1 疑问
        if (QUESTION_TAILS.any { lastWord.endsWith(it) } || QUESTION_CONTAINS.any { lastWord.contains(it) })
            return listOf("？", "，")
        // 2 感叹
        if (EXCLAIM_TAILS.any { lastWord.endsWith(it) } || EXCLAIM_WORD_TAILS.any { lastWord.endsWith(it) }
            || EXCLAIM_CONTAINS.any { lastWord.contains(it) }
            || ("太" in lastWord && lastWord.endsWith("了")))
            return listOf("！", "，")
        // 单字中性 = 组词中途,不出标点(放在语义判定后:吗/啊等单字语气词不受影响)
        if (lastWord.length == 1) return emptyList()
        // 3 连词
        if (lastWord in CONNECTIVES) return listOf("，")
        // 4/5 中性:逗号主力;发展中句子(已有逗号或够长)再给句号第二槽
        val clause = clauseOf(beforeText)
        val commas = clause.count { it == '，' || it == ',' }
        return if (commas >= 1 || clause.length >= CLAUSE_LEN_END) listOf("，", "。") else listOf("，")
    }
}
