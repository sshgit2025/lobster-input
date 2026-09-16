import UIKit

/// 打字/语音模式切换与打字面板生命周期协调。
final class TypingModeCoordinator {

    private unowned let ime: TypingImeContext
    private unowned let containerView: UIView
    private unowned let voiceView: UIView

    let preferences = TypingPreferences()
    private let composingBridge = ComposingTextBridge()
    private let undoManager = TypingUndoManager()
    private lazy var sessionHost = TypingSessionHost(
        ime: ime,
        preferences: preferences,
        composingBridge: composingBridge,
        undoManager: undoManager
    )
    private lazy var micCoordinator = TypingMicCoordinator(ime: ime, sessionHost: sessionHost)
    private lazy var engine = PinyinEngine()
    private var typingView: TypingKeyboardView?

    private(set) var isTypingModeActive = false
    var isTypingMicActive = false

    init(ime: TypingImeContext, containerView: UIView, voiceView: UIView) {
        self.ime = ime
        self.containerView = containerView
        self.voiceView = voiceView
    }

    func installIfNeeded() {
        guard typingView == nil else { return }
        let typing = TypingKeyboardView(
            sessionHost: sessionHost,
            micCoordinator: micCoordinator,
            engine: engine
        )
        typing.translatesAutoresizingMaskIntoConstraints = false
        typing.isHidden = true
        containerView.addSubview(typing)
        NSLayoutConstraint.activate([
            typing.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            typing.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            typing.topAnchor.constraint(equalTo: containerView.topAnchor),
            typing.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        typingView = typing
        micCoordinator.typingView = typing
    }

    func enterKeyboardMode() {
        installIfNeeded()
        engine.setFuzzy(preferences.fuzzySettings())
        if ime.isMicRecording() { ime.endKeyboardMicCapture() }
        isTypingModeActive = true
        preferences.lastModeKeyboard = true // 记住:用户切到键盘模式
        if let typing = typingView {
            animateModeSwitch(show: typing, hide: voiceView)
        } else {
            voiceView.isHidden = true
        }
        sessionHost.refreshEditorAction()
        typingView?.resetComposing()
    }

    func exitKeyboardMode() {
        if isTypingMicActive { ime.endKeyboardMicCapture() }
        isTypingModeActive = false
        preferences.lastModeKeyboard = false // 记住:用户切回语音
        if let typing = typingView {
            animateModeSwitch(show: voiceView, hide: typing)
        } else {
            voiceView.isHidden = false
        }
        sessionHost.clearComposingPreview()
    }

    // MARK: - 模式切换过场(纯视觉:入场 alpha 0→1 + 上移 12→0,出场 alpha→0)

    /// 入场 0.2s ease-out,出场 0.14s;completion 一律以「当前期望模式」收尾,
    /// 动画被打断/连点也不会让视图卡在中间态。不涉及输入/焦点逻辑时序。
    private func animateModeSwitch(show: UIView, hide: UIView) {
        // 已处于终态且无动画在途:直接校正,不做无意义的闪动
        if !show.isHidden, hide.isHidden,
           show.layer.animationKeys() == nil, hide.layer.animationKeys() == nil {
            applyTerminalState(to: show)
            applyTerminalState(to: hide)
            return
        }
        show.isHidden = false
        show.alpha = 0
        show.transform = CGAffineTransform(translationX: 0, y: KeyboardMetrics.modeEnterTranslationY)
        hide.transform = .identity
        UIView.animate(
            withDuration: KeyboardMetrics.modeExitDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            hide.alpha = 0
        } completion: { [weak self] _ in
            self?.applyTerminalState(to: hide)
        }
        UIView.animate(
            withDuration: KeyboardMetrics.modeEnterDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            show.alpha = 1
            show.transform = .identity
        } completion: { [weak self] _ in
            self?.applyTerminalState(to: show)
        }
    }

    /// 按当前期望模式恢复视图终态(isHidden/alpha/transform 与原硬切逻辑完全一致)。
    private func applyTerminalState(to view: UIView) {
        let shouldShow = view === voiceView ? !isTypingModeActive : isTypingModeActive
        view.isHidden = !shouldShow
        view.alpha = 1
        view.transform = .identity
    }

    /// 输入框切换:未记住键盘模式时回到语音面板。
    func onInputFieldChanged() {
        sessionHost.refreshEditorAction()
        typingView?.refreshEnterKey()
        if !preferences.lastModeKeyboard && isTypingModeActive {
            exitKeyboardMode()
            return
        }
        typingView?.resetComposing()
    }

    func onViewWillAppear() {
        // 每次拉起都清理上次未完成的 composing/候选(失焦再聚焦不残留)
        typingView?.resetComposing()
        // 记住上次模式:拉起时恢复到用户上次手动选择的模式(初次默认语音)
        if preferences.lastModeKeyboard && !isTypingModeActive {
            enterKeyboardMode()
        } else if isTypingModeActive {
            voiceView.isHidden = true
            typingView?.isHidden = false
        }
    }

    /// 键盘会话结束(视图消失/键盘收起):清除会话级粘性(数字页/自动英文)。
    func onSessionEnd() {
        typingView?.onSessionEnd()
    }

    func setTypingMicActive(_ active: Bool) {
        isTypingMicActive = active
    }

    func finishTypingMic(result: KeyboardRecordingResult) {
        let output = result.result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = result.error, !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            micCoordinator.onMicError(err)
        } else if !output.isEmpty {
            sessionHost.onCommit(output)
        }
        isTypingMicActive = false
        typingView?.stopMicRecordingUI()
        typingView?.setInputBlocked(false)
    }

    func handleMicCoordinatorError(_ message: String) {
        isTypingMicActive = false
        micCoordinator.onMicError(message)
    }

    func stopMicUI() {
        typingView?.stopMicRecordingUI()
        typingView?.setInputBlocked(false)
    }

    func updateMicLevel(_ level: Float) {
        typingView?.updateMicLevel(CGFloat(level))
    }

    func updateMicProgress(_ remainingRatio: CGFloat) {
        typingView?.setMicProgress(remainingRatio)
    }
}
