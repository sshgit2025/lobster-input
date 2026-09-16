import Foundation

/// 键盘布局工厂(工厂模式)。麦克风不在按键区(已移至候选栏左上)。
final class KeyboardLayoutFactory {

    struct LayoutState {
        let chineseMode: Bool
        let nineGrid: Bool
        let symbolPage: Bool
        let numberPage: Bool
        let symbolPageIndex: Int
        let enterLabel: String
        let canUndo: Bool
        var lang: InputLang = .zh
        /// 模式轮换键的下一站短标签(画在循环图标下方,预告下一模式)。
        var nextModeLabel: String = ""
    }

    private unowned let host: TypingKeyboardHost
    init(host: TypingKeyboardHost) { self.host = host }

    func build(_ state: LayoutState) -> [[TypingKeySpec]] {
        if state.numberPage { return numberRows(state) }
        if state.symbolPage { return symbolRows(state) }
        if state.lang == .ru { return russianRows(state) }
        if state.lang == .ko { return koreanRows(state) }
        return state.nineGrid ? nineGridRows(state) : qwertyRows(state)
    }

    private func langKey(_ s: LayoutState, _ w: CGFloat) -> TypingKeySpec {
        let label: String
        switch s.lang {
        case .zh: label = host.localize(.ch)
        case .en: label = host.localize(.en)
        default: label = s.lang.keyLabel
        }
        return TypingKeySpec(type: .lang, main: label, weight: w)
    }

    /// 模式轮换键(问题3:替代"切26"和长按切语种):自绘循环箭头图标 + 下一模式短标签,
    /// 全部打字布局(九宫格/26键/俄/韩)常驻同位,循环 中9→中26→EN→РУ→한。
    private func modeCycleKey(_ s: LayoutState, _ w: CGFloat) -> TypingKeySpec {
        TypingKeySpec(type: .modeCycle, sub: s.nextModeLabel, weight: w)
    }

    private func comma(_ s: LayoutState, _ w: CGFloat) -> TypingKeySpec {
        TypingKeySpec(type: .symChar, main: "，", weight: w, value: s.chineseMode ? "，" : ",")
    }

    private func period(_ s: LayoutState, _ w: CGFloat) -> TypingKeySpec {
        TypingKeySpec(type: .symChar, main: "。", weight: w, value: s.chineseMode ? "。" : ".")
    }

    // MARK: 26 键 QWERTY
    private func qwertyRows(_ s: LayoutState) -> [[TypingKeySpec]] {
        let row1Long = Array("1234567890")
        func row1() -> [TypingKeySpec] {
            Array("qwertyuiop").enumerated().map { i, c in
                TypingKeySpec(type: .letter, main: String(c), longValue: String(row1Long[i]))
            }
        }
        func letters(_ str: String) -> [TypingKeySpec] { str.map { TypingKeySpec(type: .letter, main: String($0)) } }
        var row3: [TypingKeySpec] = [TypingKeySpec(type: .shift, weight: 1.5)]
        row3 += letters("zxcvbnm")
        if s.chineseMode {
            row3.append(TypingKeySpec(type: .syllable, main: host.localize(.syllable), weight: 1.1))
        }
        row3.append(TypingKeySpec(type: .delete, weight: 1.5))
        var row4: [TypingKeySpec] = [
            langKey(s, 1.4),
            TypingKeySpec(type: .symbol, main: host.localize(.symbol), weight: 1.2),
            modeCycleKey(s, 0.95),
            TypingKeySpec(type: .space, main: host.localize(.space), weight: 2.6),
            comma(s, 0.95),
            period(s, 0.95),
        ]
        if s.canUndo {
            row4.append(TypingKeySpec(type: .undo, main: host.localize(.undo), weight: 1.1))
        }
        row4.append(TypingKeySpec(type: .enter, main: s.enterLabel, weight: 1.5))
        let row2 = [TypingKeySpec(type: .gap, weight: 0.5)] + letters("asdfghjkl") + [TypingKeySpec(type: .gap, weight: 0.5)]
        return [row1(), row2, row3, row4]
    }

    // MARK: 俄语 ЙЦУКЕН
    /// 标准移动端 3 行:11/11/9+shift+del(对齐 Gboard/iOS 系统俄语键盘)。
    /// ё=长按 е,ъ=长按 ь(业界惯例:低频字母走长按不占键位)。
    private func russianRows(_ s: LayoutState) -> [[TypingKeySpec]] {
        func letters(_ str: String, longs: [Character: String] = [:]) -> [TypingKeySpec] {
            str.map { TypingKeySpec(type: .letter, main: String($0), longValue: longs[$0]) }
        }
        var row3: [TypingKeySpec] = [TypingKeySpec(type: .shift, weight: 1.3)]
        row3 += letters("ячсмитьбю", longs: ["ь": "ъ"])
        row3.append(TypingKeySpec(type: .delete, weight: 1.3))
        let row4: [TypingKeySpec] = [
            langKey(s, 1.4),
            TypingKeySpec(type: .symbol, main: host.localize(.symbol), weight: 1.2),
            modeCycleKey(s, 0.95),
            TypingKeySpec(type: .space, main: host.localize(.space), weight: 2.7),
            comma(s, 0.95),
            period(s, 0.95),
            TypingKeySpec(type: .enter, main: s.enterLabel, weight: 1.5)
        ]
        return [
            letters("йцукенгшщзх", longs: ["е": "ё"]),
            letters("фывапролджэ"),
            row3, row4
        ]
    }

    // MARK: 韩语 2-set 두벌식
    /// 左辅音右元音(对齐 Gboard/iOS 系统韩语键盘)。双辅音/复合元音走 shift(ㅂ→ㅃ、ㅐ→ㅒ);
    /// 复合元音 ㅘㅝㅢ 等由组字自动机连击合成。
    private func koreanRows(_ s: LayoutState) -> [[TypingKeySpec]] {
        func jamo(_ str: String, shifts: [Character: String] = [:]) -> [TypingKeySpec] {
            str.map { TypingKeySpec(type: .letter, main: String($0), shiftValue: shifts[$0]) }
        }
        let row1Shift: [Character: String] = ["ㅂ": "ㅃ", "ㅈ": "ㅉ", "ㄷ": "ㄸ", "ㄱ": "ㄲ", "ㅅ": "ㅆ", "ㅐ": "ㅒ", "ㅔ": "ㅖ"]
        var row3: [TypingKeySpec] = [TypingKeySpec(type: .shift, weight: 1.3)]
        row3 += jamo("ㅋㅌㅊㅍㅠㅜㅡ")
        row3.append(TypingKeySpec(type: .delete, weight: 1.3))
        let row4: [TypingKeySpec] = [
            langKey(s, 1.4),
            TypingKeySpec(type: .symbol, main: host.localize(.symbol), weight: 1.2),
            modeCycleKey(s, 0.95),
            TypingKeySpec(type: .space, main: host.localize(.space), weight: 2.7),
            comma(s, 0.95),
            period(s, 0.95),
            TypingKeySpec(type: .enter, main: s.enterLabel, weight: 1.5)
        ]
        let row2 = [TypingKeySpec(type: .gap, weight: 0.5)] + jamo("ㅁㄴㅇㄹㅎㅗㅓㅏㅣ") + [TypingKeySpec(type: .gap, weight: 0.5)]
        return [jamo("ㅂㅈㄷㄱㅅㅛㅕㅑㅐㅔ", shifts: row1Shift), row2, row3, row4]
    }

    // MARK: 9 宫格 T9
    private func nineGridRows(_ s: LayoutState) -> [[TypingKeySpec]] {
        func t9(_ main: String, _ d: String) -> TypingKeySpec {
            TypingKeySpec(type: .t9, main: main, sub: d, weight: 1.3, value: d, longValue: d)
        }
        // 1 键位:@#(对齐豆包)——点击在候选栏出固定高频符号候选(SymbolData.key1Symbols),长按出数字 1。
        let key1 = TypingKeySpec(type: .symCands, main: "@#", sub: "1", weight: 1.3, longValue: "1")
        return [
            [comma(s, 1.0), key1, t9("ABC", "2"), t9("DEF", "3"), TypingKeySpec(type: .delete, weight: 1.1)],
            [langKey(s, 1.0), t9("GHI", "4"), t9("JKL", "5"), t9("MNO", "6"), TypingKeySpec(type: .symbol, main: host.localize(.symbol), weight: 1.1)],
            // 123 移左,0 键放最右(对齐豆包/搜狗)
            [TypingKeySpec(type: .num, main: "123", weight: 1.0), t9("PQRS", "7"), t9("TUV", "8"), t9("WXYZ", "9"), TypingKeySpec(type: .symChar, main: "0", weight: 1.0, value: "0")],
            // 模式轮换键(替代「切26」:布局+语种统一循环,全布局常驻,业务闭环)
            [modeCycleKey(s, 1.0), period(s, 1.0), TypingKeySpec(type: .space, main: host.localize(.space), weight: 3.2), TypingKeySpec(type: .enter, main: s.enterLabel, weight: 1.3)]
        ]
    }

    // MARK: 9 宫格数字拨号盘页
    private func numberRows(_ s: LayoutState) -> [[TypingKeySpec]] {
        func n(_ d: String) -> TypingKeySpec { TypingKeySpec(type: .symChar, main: d, value: d) }
        return [
            [n("1"), n("2"), n("3"), TypingKeySpec(type: .delete, weight: 1)],
            [n("4"), n("5"), n("6"), TypingKeySpec(type: .symChar, main: "@", value: "@")],
            [n("7"), n("8"), n("9"), TypingKeySpec(type: .enter, main: s.enterLabel, weight: 1)],
            [TypingKeySpec(type: .alpha, main: s.chineseMode ? host.localize(.pinyin) : host.localize(.abc)), TypingKeySpec(type: .symChar, main: ".", value: "."), n("0"), comma(s, 1)]
        ]
    }

    // MARK: 26 键数字/符号页
    private let zhPunct1 = ["，", "。", "？", "！", "：", "；", "、", "～", "…", "—"]
    private let zhPunct2 = ["（", "）", "【", "】", "《", "》", "“", "”", "‘", "’"]
    private let enPunct1 = ["@", "#", "$", "%", "&", "*", "-", "+", "(", ")"]
    private let enPunct2 = ["_", "=", "/", "\\", "|", "~", "<", ">", "[", "]"]

    private func symbolRows(_ s: LayoutState) -> [[TypingKeySpec]] {
        func chars(_ list: [String]) -> [TypingKeySpec] { list.map { TypingKeySpec(type: .symChar, main: $0, value: $0) } }
        let digits = "1234567890".map { TypingKeySpec(type: .symChar, main: String($0), value: String($0)) }
        let punctRow: [String] = s.chineseMode
            ? (s.symbolPageIndex == 0 ? zhPunct1 : zhPunct2)
            : (s.symbolPageIndex == 0 ? enPunct1 : enPunct2)
        let row3mid = s.chineseMode ? ["·", "「", "」", "—", "%", "&"] : [".", ",", "?", "!", "'", "\""]
        var row3: [TypingKeySpec] = [TypingKeySpec(type: .symPage, main: s.symbolPageIndex == 0 ? "1/2" : "2/2", weight: 1.5)]
        row3 += chars(row3mid)
        row3.append(TypingKeySpec(type: .delete, weight: 1.5))
        let row4: [TypingKeySpec] = [
            TypingKeySpec(type: .alpha, main: s.chineseMode ? host.localize(.pinyin) : host.localize(.abc), weight: 1.8),
            // 分类符号板入口(最近/数学/序号/货币/箭头等全量分类,对齐搜狗「更多符号」)
            TypingKeySpec(type: .symBoard, main: "√π", weight: 1.2),
            comma(s, 1.2),
            TypingKeySpec(type: .space, main: host.localize(.space), weight: 3.0),
            period(s, 1.2),
            TypingKeySpec(type: .enter, main: s.enterLabel, weight: 1.8)
        ]
        return [digits, chars(punctRow), row3, row4]
    }
}
