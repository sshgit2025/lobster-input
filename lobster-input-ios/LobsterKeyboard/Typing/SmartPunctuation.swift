import Foundation

/// 智能标点:成对符号自动配对(输 "(" 自动补 ")" 并把光标放中间)。
/// 中英标点全/半角自适应由布局层按 chineseMode 决定;此处只管配对。
enum SmartPunctuation {

    /// opening → closing。覆盖中英文括号、引号、书名号(直引号开闭同形不配对)。
    private static let pairs: [String: String] = [
        "(": ")", "（": "）",
        "[": "]", "【": "】",
        "{": "}", "「": "」", "『": "』",
        "<": ">", "《": "》",
        "“": "”", "‘": "’"
    ]

    static func closing(for opening: String) -> String? { pairs[opening] }
}
