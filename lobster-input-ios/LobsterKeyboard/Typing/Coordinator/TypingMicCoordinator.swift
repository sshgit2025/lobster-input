import Foundation

/// 键盘内流式麦克风协调器:登录/积分/权限校验、错误提示、与按键互斥。
final class TypingMicCoordinator {

    private unowned let ime: TypingImeContext
    private unowned let sessionHost: TypingSessionHost
    weak var typingView: TypingKeyboardView?

    init(ime: TypingImeContext, sessionHost: TypingSessionHost) {
        self.ime = ime
        self.sessionHost = sessionHost
    }

    func onRecordStart() {
        if ime.isMicRecording() { return }
        guard ime.hasFullAccess else {
            typingView?.stopMicRecordingUI()
            sessionHost.showStatus(MobileStrings.fullAccessBody())
            return
        }
        guard ime.isLoggedIn() else {
            typingView?.stopMicRecordingUI()
            sessionHost.showStatus(MobileStrings.loginRequired())
            ime.requestExitTypingMode()
            return
        }
        ime.ensureInputAvailable { [weak self] in
            guard let self else { return }
            if self.ime.isCreditsBlocked() {
                self.typingView?.stopMicRecordingUI()
                self.sessionHost.showStatus(MobileStrings.creditsExhausted())
                return
            }
            guard self.ime.authToken() != nil else {
                self.typingView?.stopMicRecordingUI()
                self.sessionHost.showStatus(MobileStrings.loginRequired())
                return
            }
            self.sessionHost.clearComposingPreview()
            self.typingView?.setInputBlocked(true)
            self.ime.beginKeyboardMicCapture()
        }
    }

    func onRecordEnd() {
        ime.endKeyboardMicCapture()
        typingView?.setInputBlocked(false)
    }

    func onMicError(_ message: String) {
        typingView?.stopMicRecordingUI()
        typingView?.setInputBlocked(false)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? MobileStrings.keyboardMicFailed()
            : message
        sessionHost.showStatus(text)
    }

    func onMicActiveChanged(_ active: Bool) {
        typingView?.setInputBlocked(active)
        if !active { typingView?.stopMicRecordingUI() }
    }
}
