import Foundation

/// 候选栏标点联想 v2(2026-07-23,上下文感知模型;方案见 lobster-input-android/docs/keyboard/候选栏标点联想设计方案.md §3)。
///
/// 中文上屏词/句后,按 lastWord 词法信号 + 光标前句内上下文联合裁决,产出 1~2 个标点候选,
/// 注入联想流头部。设计哲学:逗号是默认主力,句号永不占首位;?/! 按句型置顶,第二槽给逗号;
/// 规则小而硬编码(语燕输入法开源实现 + 聊天标点用户研究)。
///
/// 与 Android PunctuationSuggestion.kt / Harmony PunctuationSuggestion.ets /
/// tools/keyboard-verify/test_punct_suggestion.py 模型逐行镜像,改动须四方同步。
enum PunctuationSuggestion {

    private static let questionTails = ["吗", "嘛", "呢"]
    private static let questionContains = [
        "什么", "怎么", "为什么", "谁", "哪里", "哪个", "哪儿", "哪些", "哪天",
        "何时", "多少", "多久", "几点",
        "难道", "岂不", "是否", "能否", "可否", "可不可以", "有没有",
        "行不行", "好不好", "是不是", "对不对"
    ]
    private static let exclaimTails = ["啊", "呀", "啦", "哇", "呐", "噢", "呗", "哟"]
    // 情绪词用包含匹配("笑死我了"式后缀);致谢类除"加油"外同(加油站误伤→加油用尾部匹配)
    private static let exclaimContains = [
        "笑死", "气死", "救命", "绝了", "好家伙", "哈哈", "累死", "馋死",
        "爱死", "吓死", "羡慕死",
        "谢谢", "感谢", "恭喜", "祝贺", "辛苦"
    ]
    private static let exclaimWordTails = ["加油"]
    private static let connectives: Set<String> = [
        "但是", "可是", "不过", "然而", "然后", "接着", "而且", "并且", "所以",
        "因此", "因为", "如果", "要是", "既然", "虽然", "尽管", "即使", "哪怕",
        "除非", "由于", "或者", "还有", "另外", "首先", "其次", "比如", "特别是",
        "尤其是", "对了", "话说", "顺便", "总之", "反正", "其实"
    ]

    /// 句读标点:光标前文本以这些结尾 → 刚打过标点,抑制(等下一个词)。闭合括号不在内。
    private static let midPuncts: Set<Character> = ["，", "。", "！", "？", "、", "～", "…", "：", "；", ",", ".", "!", "?", ";", ":"]
    /// 句末终止符:切句边界。
    private static let sentenceEnds: Set<Character> = ["。", "？", "！", "!", "?", "…", "～", "\n"]
    /// 中性长句阈值(聊天分句常见 4~10 字;≥12 或已有逗号说明在写复合句,收尾概率上升)。
    private static let clauseLenEnd = 12

    /// 光标前文本 → 当前句片段(自最近句末符之后,截尾空白)。
    private static func clauseOf(_ beforeText: String) -> String {
        let t = beforeText.trimmingCharacters(in: .whitespacesAndNewlines)
        var cut = t.startIndex
        for i in t.indices where sentenceEnds.contains(t[i]) {
            cut = t.index(after: i)
        }
        return String(t[cut...])
    }

    static func suggestions(_ lastWord: String?, beforeText: String) -> [String] {
        guard let w = lastWord, !w.isEmpty else { return [] }
        let tail = beforeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = tail.last, midPuncts.contains(last) { return [] } // 刚打过标点
        // 1 疑问
        if questionTails.contains(where: { w.hasSuffix($0) }) || questionContains.contains(where: { w.contains($0) }) {
            return ["？", "，"]
        }
        // 2 感叹
        if exclaimTails.contains(where: { w.hasSuffix($0) })
            || exclaimWordTails.contains(where: { w.hasSuffix($0) })
            || exclaimContains.contains(where: { w.contains($0) })
            || (w.contains("太") && w.hasSuffix("了")) {
            return ["！", "，"]
        }
        // 单字中性 = 组词中途,不出标点(放在语义判定后:吗/啊等单字语气词不受影响)
        if w.count == 1 { return [] }
        // 3 连词
        if connectives.contains(w) { return ["，"] }
        // 4/5 中性:逗号主力;发展中句子(已有逗号或够长)再给句号第二槽
        let clause = clauseOf(beforeText)
        let commas = clause.filter { $0 == "，" || $0 == "," }.count
        return (commas >= 1 || clause.count >= clauseLenEnd) ? ["，", "。"] : ["，"]
    }
}
