import UIKit

/// 键盘无障碍标签与状态播报(集中管理,避免散落)。
enum TypingAccessibilityLabels {

    static func keyLabel(
        for spec: TypingKeySpec,
        shiftActive: Bool,
        capsLock: Bool
    ) -> String {
        switch spec.type {
        case .letter:
            let ch = (!shiftActive && !capsLock) ? spec.main : spec.main.uppercased()
            return MobileStrings.a11yKeyLetter(ch)
        case .t9:
            return MobileStrings.a11yKeyT9(main: spec.main, sub: spec.sub ?? "")
        case .delete:
            return MobileStrings.a11yKeyDelete()
        case .space:
            return MobileStrings.a11yKeySpace()
        case .enter:
            return MobileStrings.a11yKeyEnter()
        case .shift:
            if capsLock { return MobileStrings.a11yKeyCapsLock() }
            if shiftActive { return MobileStrings.a11yKeyShiftOn() }
            return MobileStrings.a11yKeyShift()
        case .lang:
            return MobileStrings.a11yKeyLang()
        case .layout:
            return MobileStrings.a11yKeyLayout()
        case .symbol, .num:
            return MobileStrings.a11yKeySymbols()
        case .alpha:
            return MobileStrings.a11yKeyAlpha()
        case .symPage:
            return MobileStrings.a11yKeySymPage()
        case .symChar:
            return MobileStrings.a11yKeyChar(spec.main)
        // 模式轮换键:读出下一模式(spec.sub);符号板入口读符号页通用描述
        case .modeCycle:
            return MobileStrings.a11yKeyLayout() + (spec.sub.map { " \($0)" } ?? "")
        case .symBoard:
            return MobileStrings.a11yKeySymbols()
        case .syllable:
            return MobileStrings.syllableSepKey()
        case .undo:
            return MobileStrings.undo()
        case .mic:
            return MobileStrings.a11yKeyMic()
        // 9 宫格 1 键(@#):高频符号候选入口,读作符号键
        case .symCands:
            return MobileStrings.a11yKeySymbols()
        case .gap:
            return ""
        }
    }

    static func candidateLabel(_ candidate: PinyinCandidate, index: Int) -> String {
        "\(index + 1). \(candidate.word)"
    }

    static func announceStatus(on view: UIView, message: String) {
        view.accessibilityLabel = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
