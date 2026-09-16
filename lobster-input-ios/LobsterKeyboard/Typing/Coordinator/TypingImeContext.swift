import UIKit

/// 打字模式所需的 IME 宿主能力(依赖倒置,避免 Typing 模块直接耦合 KeyboardViewController)。
protocol TypingImeContext: AnyObject {
    var textDocumentProxy: UITextDocumentProxy { get }
    var hasFullAccess: Bool { get }
    func isLoggedIn() -> Bool
    func authToken() -> String?
    func isCreditsBlocked() -> Bool
    func ensureInputAvailable(_ onReady: @escaping () -> Void)
    func performKeyHaptic()
    func requestExitTypingMode()
    func isMicRecording() -> Bool
    func beginKeyboardMicCapture()
    func endKeyboardMicCapture()
    func refreshEditorContext()
}

enum TypingBlockedReason {
    case loginRequired
    case creditsExhausted
    case micPermission
}
