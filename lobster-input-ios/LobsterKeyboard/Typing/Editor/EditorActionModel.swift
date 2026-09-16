import UIKit

/// Enter 键展示与行为模型(由 textDocumentProxy 解析)。
struct EditorActionModel {
    enum EditorInfoAction {
        case newline, search, send, go, done, next, previous
    }

    let label: String
    let action: EditorInfoAction
    let multiline: Bool
    let isPassword: Bool
    /// 数字/电话/小数类输入框:键盘应自动进入数字键盘页(业界标准)。
    let isNumeric: Bool
    /// 邮箱/URI/ASCII 类英文输入框:键盘应自动切换英文模式(业界标准,仅会话内)。
    let isEnglish: Bool

    static let `default` = EditorActionModel(
        label: MobileStrings.enterNewline(),
        action: .newline,
        multiline: false,
        isPassword: false,
        isNumeric: false,
        isEnglish: false
    )

    static func resolve(from proxy: UITextDocumentProxy) -> EditorActionModel {
        let returnType = proxy.returnKeyType
        let keyboardType = proxy.keyboardType
        let multiline = keyboardType == .default && returnType == .default
        let isPassword = keyboardType == .asciiCapable || keyboardType == .numbersAndPunctuation
        // 数字/电话/小数输入框 → 自动数字键盘(对齐 iOS 原生/搜狗)
        let isNumeric = keyboardType == .numberPad || keyboardType == .phonePad ||
            keyboardType == .decimalPad || keyboardType == .asciiCapableNumberPad
        // 邮箱/URI/ASCII 输入框 → 自动英文模式(对齐 Gboard/搜狗,仅会话内不写偏好)
        let isEnglish = keyboardType == .emailAddress || keyboardType == .URL ||
            keyboardType == .asciiCapable

        let action: EditorInfoAction
        switch returnType {
        case .search: action = .search
        case .send: action = .send
        case .go: action = .go
        case .done: action = .done
        case .next: action = .next
        case .join, .route, .google, .yahoo, .continue: action = .go
        default: action = .newline
        }

        let label: String
        switch action {
        case .search: label = MobileStrings.enterSearch()
        case .send: label = MobileStrings.enterSend()
        case .go: label = MobileStrings.enterGo()
        case .done: label = MobileStrings.enterDone()
        case .next: label = MobileStrings.enterNext()
        case .previous: label = MobileStrings.enterPrevious()
        case .newline: label = MobileStrings.enterNewline()
        }

        return EditorActionModel(label: label, action: action, multiline: multiline, isPassword: isPassword, isNumeric: isNumeric, isEnglish: isEnglish)
    }
}
