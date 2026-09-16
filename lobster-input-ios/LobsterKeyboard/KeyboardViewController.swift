import UIKit
import os.log

private let keyboardLog = Logger(subsystem: "ssh2026.lobster-input-ios", category: "KeyboardExtension")

final class KeyboardViewController: UIInputViewController {

    private enum Operation {
        case transcribe
        case rewrite

        var apiValue: String {
            switch self {
            case .transcribe: return "transcribe"
            case .rewrite: return "rewrite"
            }
        }

        var isRewrite: Bool {
            if case .rewrite = self { return true }
            return false
        }

        var handoffOperation: KeyboardHandoffOperation {
            switch self {
            case .transcribe: return .transcribe
            case .rewrite: return .rewrite
            }
        }
    }

    private enum RewriteTarget {
        case none
        case selectedText
        case lastInserted
    }

    private var voiceKeyboardView: VoiceKeyboardView!
    private lazy var typingCoordinator = TypingModeCoordinator(ime: self, containerView: view, voiceView: voiceKeyboardView)
    private let defaults = UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard

    private var maxRecordingDurationSec = 60
    private let voiceRecordingCoordinator = KeyboardVoiceRecordingCoordinator()

    private var pendingOperation: Operation = .transcribe
    private var pendingRewriteOriginal = ""
    private var pendingRewriteTarget: RewriteTarget = .none
    private var lastInsertedText = ""
    private var voiceRestoreText = ""
    private var operationTextHistory: [String] = []
    private var isProcessing = false
    private var accountStatusLoading = false
    private var liveCreditsRemaining: Int?
    private var blockedReason: KeyboardBlockedReason?
    private var fastModeEnabled = false
    private var realtimeRecognitionEnabled = false
    private var realtimePreviewText = ""
    // 实时识别打字机平滑层:realtimeTargetText 记录最新完整目标(去重用),
    // realtimePreviewText 始终等于屏幕上已揭示的前缀。平滑只影响预览,不参与最终提交。
    private var realtimeTargetText = ""
    private lazy var realtimeTypewriter = TypewriterReveal { [weak self] shown in
        self?.applyRealtimePreview(shown)
    }
    private var rightHandLayout = true
    private var recordingRemainingSec = 60
    private var personas: [KeyboardPersona] = []
    private var personasLoading = false
    private var personasRefreshing = false
    private var pendingPersonaActionID: String?

    private struct TemporaryTextState: Codable {
        var history: [String]
        var lastInsertedText: String
        var voiceRestoreText: String
    }

    private enum DefaultsKey {
        static let token = "auth_token"
        static let fastMode = "ime_fast_mode_enabled"
        static let handLayout = "ime_right_hand_layout"
        static let maxDuration = "recording_max_duration_sec"
        static let history = "recording_history"
        static let textState = "keyboard_temporary_text_state"
    }

    override func loadView() {
        let keyboardView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        keyboardView.allowsSelfSizing = true
        inputView = keyboardView
        view = keyboardView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        voiceKeyboardView = VoiceKeyboardView(frame: .zero)
        voiceKeyboardView.translatesAutoresizingMaskIntoConstraints = false
        voiceKeyboardView.delegate = self
        voiceKeyboardView.wireInputModeListTarget(self, action: #selector(handleInputModeList(from:with:)))
        view.addSubview(voiceKeyboardView)

        NSLayoutConstraint.activate([
            voiceKeyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            voiceKeyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            voiceKeyboardView.topAnchor.constraint(equalTo: view.topAnchor),
            voiceKeyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 懒加载:不在此急切安装打字键盘/加载 ~15MB 词库;
        // 仅当用户首次切到打字模式(enterKeyboardMode → installIfNeeded)才创建,
        // 纯语音用户零词库内存占用,降低 appex 内存压力。
        voiceRecordingCoordinator.delegate = self
        voiceRecordingCoordinator.configure()
        loadLocalPreferences()
        loadTemporaryTextHistory()
    }

    deinit {
        voiceRecordingCoordinator.teardown()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        typingCoordinator.onViewWillAppear()
        loadLocalPreferences()
        KeyboardVoiceSessionBridge.invalidateStaleSessionIfNeeded()
        voiceRecordingCoordinator.resumeWhenKeyboardActive()
        voiceRecordingCoordinator.refreshSessionBadge()
        voiceRecordingCoordinator.consumeResultIfNeeded()
        refreshKeyboardState()
        refreshAccountStateForPanel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        consumeKeyboardRecordingResultIfNeeded()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        typingCoordinator.onInputFieldChanged()
        refreshKeyboardState()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        typingCoordinator.onInputFieldChanged()
        refreshKeyboardState()
    }

    private func loadLocalPreferences() {
        fastModeEnabled = defaults.object(forKey: DefaultsKey.fastMode) as? Bool ?? false
        rightHandLayout = defaults.object(forKey: DefaultsKey.handLayout) as? Bool ?? true
        let storedDuration = defaults.integer(forKey: DefaultsKey.maxDuration)
        if storedDuration > 0 {
            maxRecordingDurationSec = storedDuration
            recordingRemainingSec = storedDuration
        } else {
            maxRecordingDurationSec = 60
            recordingRemainingSec = 60
        }
        voiceKeyboardView.setFastMode(fastModeEnabled)
        realtimeRecognitionEnabled = KeyboardRealtimeRecognitionStore.isEnabled
        voiceKeyboardView.setRealtimeRecognitionEnabled(realtimeRecognitionEnabled)
        voiceKeyboardView.setHandLayout(rightHand: rightHandLayout)
    }

    private func getToken() -> String? {
        guard hasFullAccess else { return nil }
        // token 已迁移到共享 Keychain（与主 App 共用同一 access group）。
        return KeychainTokenStore.get()
    }

    func isLoggedIn() -> Bool {
        getToken() != nil
    }

    private func refreshKeyboardState() {
        voiceKeyboardView.setNeedsSwitchKey(needsInputModeSwitchKey)
        if !hasFullAccess {
            voiceKeyboardView.setRequiresFullAccess()
            return
        }
        if voiceRecordingCoordinator.isPendingVoiceActivation {
            if voiceRecordingCoordinator.isRealtimeModeActive {
                voiceKeyboardView.setRealtimeConnecting()
            } else {
                voiceKeyboardView.setWakingSession(isRewrite: pendingOperation.isRewrite)
            }
            return
        }
        if isActivelyRecording {
            return
        }
        if isProcessing {
            voiceKeyboardView.setProcessing(isRewrite: pendingOperation.isRewrite)
            return
        }
        if let blockedReason, !isActivelyRecording, !isProcessing {
            voiceKeyboardView.showUnavailable(creditsExhausted: blockedReason == .creditsExhausted)
            return
        }
        if accountStatusLoading {
            voiceKeyboardView.setAccountChecking()
            return
        }
        voiceKeyboardView.setLoggedIn(
            isLoggedIn(),
            canRewrite: canRewrite,
            canUndo: !operationTextHistory.isEmpty,
            canRestore: !voiceRestoreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        voiceRecordingCoordinator.refreshSessionBadge()
    }

    private func refreshAccountStateForPanel() {
        guard hasFullAccess else {
            blockedReason = nil
            refreshKeyboardState()
            return
        }
        guard let token = getToken() else {
            liveCreditsRemaining = nil
            showUnavailable(.loginRequired)
            return
        }
        verifyAccountState(token: token, onReady: nil, allowFallback: true)
    }

    private func ensureInputAvailableForAction(_ onReady: @escaping () -> Void) {
        guard hasFullAccess else {
            voiceKeyboardView.setRequiresFullAccess()
            return
        }
        guard let token = getToken() else {
            liveCreditsRemaining = nil
            showUnavailable(.loginRequired)
            return
        }
        if liveCreditsRemaining == nil || liveCreditsRemaining == 0 {
            verifyAccountState(token: token, onReady: onReady, allowFallback: liveCreditsRemaining == nil)
            return
        }
        clearUnavailableState()
        onReady()
    }

    private func verifyAccountState(token: String, onReady: (() -> Void)?, allowFallback: Bool) {
        if accountStatusLoading { return }
        accountStatusLoading = true
        refreshKeyboardState()

        Task {
            do {
                let plan = try await KeyboardAPIClient.getPlan(token: token)
                await MainActor.run {
                    rememberLiveCredits(plan.creditsRemaining)
                    if plan.creditsRemaining > 0 {
                        clearUnavailableState()
                        onReady?()
                    } else {
                        showUnavailable(.creditsExhausted)
                    }
                }
            } catch let error as KeyboardInputUnavailableError {
                await MainActor.run {
                    if error.reason == .loginRequired { clearAuthSession() }
                    showUnavailable(error.reason, message: error.localizedDescription)
                }
            } catch {
                await MainActor.run {
                    if allowFallback, onReady != nil {
                        clearUnavailableState()
                        onReady?()
                    } else if onReady != nil {
                        voiceKeyboardView.showError(
                            error.localizedDescription,
                            canRewrite: canRewrite,
                            canUndo: !operationTextHistory.isEmpty,
                            canRestore: !voiceRestoreText.isEmpty
                        )
                    }
                }
            }

            await MainActor.run {
                accountStatusLoading = false
                refreshKeyboardState()
            }
        }
    }

    private func rememberLiveCredits(_ remaining: Int?) {
        guard let remaining else { return }
        liveCreditsRemaining = remaining
        blockedReason = remaining <= 0 ? .creditsExhausted : nil
        defaults.set(remaining, forKey: "credits_remaining")
    }

    private func showUnavailable(_ reason: KeyboardBlockedReason, message: String? = nil) {
        blockedReason = reason
        if let message {
            voiceKeyboardView.showError(message, canRewrite: false, canUndo: false, canRestore: false)
        } else {
            voiceKeyboardView.showUnavailable(creditsExhausted: reason == .creditsExhausted)
        }
    }

    private func clearUnavailableState() {
        blockedReason = nil
        refreshKeyboardState()
    }

    private func clearAuthSession() {
        // token 存于共享 Keychain，需同步清除。
        KeychainTokenStore.delete()
        // 兼容清理可能残留的旧明文 token。
        defaults.removeObject(forKey: DefaultsKey.token)
        defaults.removeObject(forKey: "user_email")
        defaults.removeObject(forKey: "user_tier")
    }

    // MARK: - Recording (main-app background voice session)

    private var isActivelyRecording: Bool {
        voiceRecordingCoordinator.isActivelyRecording
    }

    private func handoffTargetForPendingRewrite() -> KeyboardHandoffTarget {
        switch pendingRewriteTarget {
        case .none: return .none
        case .selectedText: return .selectedText
        case .lastInserted: return .lastInserted
        }
    }

    private func startRecordingAfterPermission(operation: Operation) {
        guard !isProcessing else { return }
        if voiceRecordingCoordinator.isPendingVoiceActivation {
            voiceRecordingCoordinator.resumeWhenKeyboardActive()
            return
        }
        guard !isActivelyRecording else { return }
        guard hasFullAccess else {
            voiceKeyboardView.setRequiresFullAccess()
            return
        }
        guard getToken() != nil else {
            showUnavailable(.loginRequired)
            return
        }

        if operation == .transcribe {
            pendingRewriteOriginal = ""
            pendingRewriteTarget = .none
        }
        pendingOperation = operation

        let handoffTarget = handoffTargetForPendingRewrite()
        let replacementText = pendingRewriteOriginal.nonEmpty
        voiceRecordingCoordinator.startRecording(
            operation: operation.handoffOperation,
            target: handoffTarget,
            selectedText: handoffTarget == .selectedText ? replacementText : nil,
            replacementText: replacementText,
            context: recentContextForServer(),
            fastMode: operation == .transcribe && fastModeEnabled,
            maxDurationSec: maxRecordingDurationSec
        )
    }

    private func stopRecording() {
        guard isActivelyRecording else { return }
        isProcessing = true
        voiceRecordingCoordinator.stopRecording()
    }

    private func beginRealtimeRecording() {
        guard realtimeRecognitionEnabled, !isProcessing, !isActivelyRecording else { return }
        if voiceRecordingCoordinator.isPendingVoiceActivation {
            voiceRecordingCoordinator.resumeWhenKeyboardActive()
            return
        }
        ensureInputAvailableForAction { [weak self] in
            guard let self else { return }
            self.pendingOperation = .transcribe
            self.pendingRewriteOriginal = ""
            self.pendingRewriteTarget = .none
            self.clearRealtimePreview()
            self.voiceKeyboardView.setRealtimeConnecting()
            self.voiceRecordingCoordinator.startRecording(
                operation: .transcribe,
                target: .none,
                selectedText: nil,
                replacementText: nil,
                context: self.recentContextForServer(),
                fastMode: self.fastModeEnabled,
                realtimeMode: true,
                maxDurationSec: self.maxRecordingDurationSec
            )
        }
    }

    private func endRealtimeRecording() {
        guard realtimeRecognitionEnabled else { return }
        if voiceRecordingCoordinator.isPendingVoiceActivation {
            voiceRecordingCoordinator.cancelPendingActivation()
            return
        }
        guard isActivelyRecording, voiceRecordingCoordinator.isRealtimeModeActive else {
            // 松手时会话已非录音态(主App被杀/中断/激活失败):stop 命令不会发出,LLM 不会被调用。
            // 落盘记录现场,并清掉已 flush 的预览,避免"识别原文留屏且未加工"的静默失败。
            FileLog.w("VoiceRT", "release ignored: activeRecording=\(isActivelyRecording) realtimeActive=\(voiceRecordingCoordinator.isRealtimeModeActive) previewLen=\(realtimePreviewText.count)")
            return
        }
        isProcessing = true
        // 停止录音:立即把预览补齐到完整目标,避免停在"揭示一半"的残缺文本;
        // 最终仍由 commitRealtimeFinalText 用后端权威整句替换,业务结果不受影响。
        realtimeTypewriter.flush()
        voiceKeyboardView.setRealtimeProcessing()
        voiceRecordingCoordinator.stopRecording()
    }

    private func replaceRealtimePreview(_ text: String) {
        guard realtimeRecognitionEnabled || typingCoordinator.isTypingMicActive, pendingOperation == .transcribe else { return }
        guard voiceRecordingCoordinator.isRealtimeModeActive else { return }
        guard case .recording = voiceRecordingCoordinator.phase else { return }
        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return }
        guard preview != realtimeTargetText else { return }
        realtimeTargetText = preview
        realtimeTypewriter.setTarget(preview)
    }

    /// 把打字机"已揭示前缀"增量渲染到光标前预览区:只删除分叉后缀、补齐新增前缀,
    /// 保持 realtimePreviewText 与屏幕严格一致(clear / commit 依赖它逐字回删)。
    private func applyRealtimePreview(_ shown: String) {
        let current = realtimePreviewText
        if shown == current { return }
        let currentChars = Array(current)
        let shownChars = Array(shown)
        var common = 0
        let maxCommon = min(currentChars.count, shownChars.count)
        while common < maxCommon && currentChars[common] == shownChars[common] { common += 1 }
        let deleteCount = currentChars.count - common
        if deleteCount > 0 {
            for _ in 0..<deleteCount { textDocumentProxy.deleteBackward() }
        }
        if shownChars.count > common {
            textDocumentProxy.insertText(String(shownChars[common..<shownChars.count]))
        }
        realtimePreviewText = shown
    }

    private func clearRealtimePreview() {
        realtimeTypewriter.reset()
        realtimeTargetText = ""
        guard !realtimePreviewText.isEmpty else { return }
        deleteTextBeforeCursor(realtimePreviewText)
        realtimePreviewText = ""
    }

    private func handle(_ response: KeyboardAudioResponse, operation: Operation) {
        rememberLiveCredits(response.creditsRemaining)
        if let duration = response.configUpdate?.maxDurationSec, duration > 0 {
            maxRecordingDurationSec = duration
            defaults.set(duration, forKey: DefaultsKey.maxDuration)
        }

        let output = outputText(from: response).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            let message = operation == .rewrite ? MobileStrings.emptyRewrite() : MobileStrings.emptyTranscribe()
            voiceKeyboardView.showError(message, canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty)
            pendingRewriteOriginal = ""
            pendingRewriteTarget = .none
            return
        }

        if operation == .transcribe, handleLocalVoiceCommand(output) {
            pendingRewriteOriginal = ""
            pendingRewriteTarget = .none
            refreshKeyboardState()
            return
        }

        applyProcessedText(
            output: output,
            target: operation == .rewrite ? pendingRewriteTarget : .none,
            replacedOverride: operation == .rewrite ? pendingRewriteOriginal.nonEmpty : nil,
            cacheForRestore: true
        )
        pendingRewriteOriginal = ""
        pendingRewriteTarget = .none
        voiceKeyboardView.showInserted(
            canRewrite: canRewrite,
            canUndo: !operationTextHistory.isEmpty,
            canRestore: !voiceRestoreText.isEmpty,
            rewritten: operation == .rewrite
        )
    }

    private func outputText(from response: KeyboardAudioResponse) -> String {
        switch response.actionType {
        case .paste:
            return response.result
        case .clarify:
            return response.clarifyQuestion ?? response.result
        case .showMarkdown, .tip:
            return response.result
        }
    }

    private func outputText(from response: KeyboardQuickActionResponse) -> String {
        response.result
    }

    // MARK: - Text Operations

    private func beginRewrite() {
        guard !isProcessing, !isActivelyRecording else { return }
        ensureInputAvailableForAction { [weak self] in
            guard let self else { return }
            let selectedText = self.currentSelectionText()
            if !selectedText.isEmpty {
                self.pendingRewriteOriginal = selectedText
                self.pendingRewriteTarget = .selectedText
            } else if !self.lastInsertedText.isEmpty {
                self.pendingRewriteOriginal = self.lastInsertedText
                self.pendingRewriteTarget = .lastInserted
            } else {
                self.pendingRewriteOriginal = ""
                self.pendingRewriteTarget = .none
            }
            self.startRecordingAfterPermission(operation: .rewrite)
        }
    }

    private func performQuickAction(_ action: KeyboardQuickAction) {
        guard !isProcessing, !isActivelyRecording else { return }
        ensureInputAvailableForAction { [weak self] in
            self?.requestQuickAction(action)
        }
    }

    private func requestQuickAction(_ action: KeyboardQuickAction) {
        guard let token = getToken() else {
            showUnavailable(.loginRequired)
            return
        }

        let selectedText = currentSelectionText()
        let target: RewriteTarget
        let sourceText: String
        if !selectedText.isEmpty {
            target = .selectedText
            sourceText = selectedText
        } else if !lastInsertedText.isEmpty {
            target = .lastInserted
            sourceText = lastInsertedText
        } else {
            voiceKeyboardView.showError(
                MobileStrings.noRewriteTarget(),
                canRewrite: canRewrite,
                canUndo: !operationTextHistory.isEmpty,
                canRestore: !voiceRestoreText.isEmpty
            )
            return
        }

        isProcessing = true
        voiceKeyboardView.setQuickProcessing()
        let historyID = addHistory(operation: "ios_quick_\(action.rawValue)", selectedText: sourceText)

        Task {
            do {
                let response = try await KeyboardAPIClient.quickAction(
                    token: token,
                    action: action,
                    text: sourceText,
                    sourceOperation: pendingOperation.apiValue
                )
                await MainActor.run {
                    rememberLiveCredits(response.creditsRemaining)
                    let output = outputText(from: response).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !output.isEmpty else {
                        voiceKeyboardView.showError(MobileStrings.emptyRewrite(), canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty)
                        updateHistory(id: historyID, status: "failed", error: MobileStrings.emptyRewrite())
                        return
                    }
                    applyProcessedText(output: output, target: target, replacedOverride: sourceText, cacheForRestore: false)
                    updateHistory(
                        id: historyID,
                        status: "success",
                        transcript: response.transcript ?? response.inputText,
                        result: output,
                        actionType: response.actionType.rawValue,
                        error: nil
                    )
                    voiceKeyboardView.showInserted(canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty, rewritten: true)
                }
            } catch let error as KeyboardInputUnavailableError {
                await MainActor.run {
                    updateHistory(id: historyID, status: "failed", error: error.localizedDescription)
                    if error.reason == .loginRequired { clearAuthSession() }
                    showUnavailable(error.reason, message: error.localizedDescription)
                }
            } catch {
                await MainActor.run {
                    updateHistory(id: historyID, status: "failed", error: error.localizedDescription)
                    voiceKeyboardView.showError(error.localizedDescription, canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty)
                }
            }

            await MainActor.run {
                self.isProcessing = false
                self.refreshKeyboardState()
            }
        }
    }

    private func applyProcessedText(
        output: String,
        target: RewriteTarget,
        replacedOverride: String? = nil,
        cacheForRestore: Bool
    ) {
        let replacedText = replacedOverride ?? {
            switch target {
            case .lastInserted: return lastInsertedText
            case .selectedText: return currentSelectionText()
            case .none: return ""
            }
        }()

        if target == .lastInserted, !lastInsertedText.isEmpty {
            deleteTextBeforeCursor(lastInsertedText)
        }

        textDocumentProxy.insertText(output)
        lastInsertedText = output
        recordTextState(replacedText)
        recordTextState(output)
        if cacheForRestore {
            voiceRestoreText = output
            persistTemporaryTextHistory()
        }
    }

    private func handleBackspace() {
        let selectedText = currentSelectionText()
        if !selectedText.isEmpty {
            textDocumentProxy.insertText("")
            if lastInsertedText == selectedText {
                lastInsertedText = ""
            } else if let range = lastInsertedText.range(of: selectedText) {
                lastInsertedText.removeSubrange(range)
            }
        } else {
            textDocumentProxy.deleteBackward()
            if !lastInsertedText.isEmpty {
                lastInsertedText.removeLast()
            }
        }
        persistTemporaryTextHistory()
        refreshKeyboardState()
    }

    private func handleClearInputText() {
        guard !isProcessing, !isActivelyRecording else { return }

        if let selectedText = textDocumentProxy.selectedText, !selectedText.isEmpty {
            textDocumentProxy.insertText("")
        }
        moveCursorToEndOfDocument()
        deleteTextBeforeCursorUntilEmpty()

        clearTemporaryTextHistory()
        refreshKeyboardState()
        voiceKeyboardView.showTransientStatus(MobileStrings.inputCleared())
    }

    private func handleNewline() {
        guard hasFullAccess else {
            voiceKeyboardView.setRequiresFullAccess()
            return
        }
        textDocumentProxy.insertText("\n")
        lastInsertedText += "\n"
        recordTextState("\n")
        if !isActivelyRecording && !isProcessing {
            voiceKeyboardView.showInserted(
                canRewrite: canRewrite,
                canUndo: !operationTextHistory.isEmpty,
                canRestore: !voiceRestoreText.isEmpty
            )
        }
    }

    private func handleUndo() {
        guard !operationTextHistory.isEmpty else {
            refreshKeyboardState()
            return
        }
        let currentText = operationTextHistory.removeLast()
        deleteTextBeforeCursor(currentText)
        let previousText = operationTextHistory.last ?? ""
        if !previousText.isEmpty {
            textDocumentProxy.insertText(previousText)
            lastInsertedText = previousText
        } else {
            lastInsertedText = ""
        }
        persistTemporaryTextHistory()
        refreshKeyboardState()
    }

    private func handleRestoreVoiceText() {
        let text = voiceRestoreText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isActivelyRecording, !isProcessing else { return }
        let selectedText = currentSelectionText()
        let target: RewriteTarget
        let replaced: String
        if !selectedText.isEmpty {
            target = .selectedText
            replaced = selectedText
        } else if !lastInsertedText.isEmpty {
            target = .lastInserted
            replaced = lastInsertedText
        } else {
            target = .none
            replaced = ""
        }
        applyProcessedText(output: text, target: target, replacedOverride: replaced, cacheForRestore: false)
        voiceKeyboardView.showInserted(canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty, rewritten: true)
        persistTemporaryTextHistory()
    }

    private func deleteTextBeforeCursor(_ text: String) {
        for _ in text {
            textDocumentProxy.deleteBackward()
        }
    }

    private func moveCursorToEndOfDocument() {
        var passes = 0
        while let after = textDocumentProxy.documentContextAfterInput, !after.isEmpty, passes < 64 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: after.count)
            passes += 1
        }
    }

    private func deleteTextBeforeCursorUntilEmpty() {
        var contextPasses = 0
        while let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty, contextPasses < 128 {
            deleteTextBeforeCursor(before)
            contextPasses += 1
        }

        var fallbackDeletes = 0
        while textDocumentProxy.hasText && fallbackDeletes < 4096 {
            textDocumentProxy.deleteBackward()
            fallbackDeletes += 1
        }
    }

    private func commitTextWithHistory(_ text: String) {
        guard !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
        lastInsertedText = text
        recordTextState(text)
        refreshKeyboardState()
    }

    private func recordTextState(_ text: String) {
        guard !text.isEmpty else { return }
        if operationTextHistory.last == text { return }
        operationTextHistory.append(text)
        if operationTextHistory.count > 20 {
            operationTextHistory.removeFirst(operationTextHistory.count - 20)
        }
        persistTemporaryTextHistory()
    }

    private func clearTemporaryTextHistory() {
        operationTextHistory.removeAll()
        lastInsertedText = ""
        voiceRestoreText = ""
        pendingRewriteOriginal = ""
        pendingRewriteTarget = .none
        persistTemporaryTextHistory()
    }

    private func consumeKeyboardRecordingResultIfNeeded() {
        voiceRecordingCoordinator.consumeResultIfNeeded()
    }

    private func applyKeyboardRecordingResult(_ result: KeyboardRecordingResult) {
        isProcessing = false
        if typingCoordinator.isTypingMicActive {
            finishTypingMic(result: result)
            return
        }
        if let error = result.error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearRealtimePreview()
            voiceKeyboardView.showError(
                error,
                canRewrite: canRewrite,
                canUndo: !operationTextHistory.isEmpty,
                canRestore: !voiceRestoreText.isEmpty
            )
            refreshKeyboardState()
            return
        }
        let output = result.result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            clearRealtimePreview()
            voiceKeyboardView.showError(
                result.operation == .rewrite ? MobileStrings.emptyRewrite() : MobileStrings.emptyTranscribe(),
                canRewrite: canRewrite,
                canUndo: !operationTextHistory.isEmpty,
                canRestore: !voiceRestoreText.isEmpty
            )
            refreshKeyboardState()
            return
        }

        if result.operation == .transcribe, !realtimePreviewText.isEmpty {
            commitRealtimeFinalText(output)
        } else {
            applyKeyboardHandoffText(output, result: result)
        }
        voiceRestoreText = output
        persistTemporaryTextHistory()
        voiceKeyboardView.showInserted(
            canRewrite: canRewrite,
            canUndo: !operationTextHistory.isEmpty,
            canRestore: !voiceRestoreText.isEmpty,
            rewritten: result.operation == .rewrite
        )
        voiceKeyboardView.showTransientStatus(MobileStrings.inserted())
        refreshKeyboardState()
    }

    private func applyKeyboardHandoffText(_ output: String, result: KeyboardRecordingResult) {
        let replacement = (result.replacementText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.target {
        case .selectedText:
            if !currentSelectionText().isEmpty {
                textDocumentProxy.insertText(output)
            } else {
                replaceTextBeforeCursorIfPossible(replacement, with: output)
            }
        case .lastInserted:
            replaceTextBeforeCursorIfPossible(replacement, with: output)
        case .none:
            textDocumentProxy.insertText(output)
        }
        lastInsertedText = output
        recordTextState(replacement)
        recordTextState(output)
    }

    private func replaceTextBeforeCursorIfPossible(_ replacement: String, with output: String) {
        if !replacement.isEmpty,
           let before = textDocumentProxy.documentContextBeforeInput,
           before.hasSuffix(replacement) {
            deleteTextBeforeCursor(replacement)
        }
        textDocumentProxy.insertText(output)
    }

    private func commitRealtimeFinalText(_ output: String) {
        // 提交权威整句前先停掉打字机,避免残留 tick 在已删除的预览上继续编辑。
        realtimeTypewriter.reset()
        realtimeTargetText = ""
        if !realtimePreviewText.isEmpty {
            deleteTextBeforeCursor(realtimePreviewText)
            realtimePreviewText = ""
        }
        textDocumentProxy.insertText(output)
        lastInsertedText = output
        recordTextState(output)
    }

    private var canRewrite: Bool {
        !currentSelectionText().isEmpty || !lastInsertedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func currentSelectionText() -> String {
        (textDocumentProxy.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recentContextForServer() -> String? {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let selected = textDocumentProxy.selectedText ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        let merged = "\(before)\(selected)\(after)".trimmingCharacters(in: .whitespacesAndNewlines)
        var snippets: [String] = []
        if !lastInsertedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snippets.append(lastInsertedText)
        }
        if !merged.isEmpty, !snippets.contains(merged) {
            snippets.append(merged)
        }
        guard !snippets.isEmpty else { return nil }
        let limited = snippets.prefix(3)
        guard let data = try? JSONEncoder().encode(Array(limited)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private enum VoiceCommand {
        case newline
        case backspace
        case undoLast
    }

    private func handleLocalVoiceCommand(_ output: String) -> Bool {
        switch voiceCommand(output) {
        case .newline:
            handleNewline()
            return true
        case .backspace:
            handleBackspace()
            return true
        case .undoLast:
            handleUndo()
            return true
        case .none:
            return false
        }
    }

    private func voiceCommand(_ output: String) -> VoiceCommand? {
        let spoken = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compact = spoken.replacingOccurrences(
            of: #"[\s\p{P}，。！？、；：“”‘’（）【】《》]+"#,
            with: "",
            options: .regularExpression
        )

        if ["换行", "另起一行", "新的一行", "下一行", "newline", "newlines", "nextline", "줄바꿈", "새줄"].contains(compact)
            || ["new line", "next line", "new paragraph", "новая строка"].contains(spoken) {
            return .newline
        }
        if ["退格", "删除", "删一个字", "删除一个字", "backspace", "delete", "deletechar", "deletecharacter", "삭제"].contains(compact)
            || ["delete last character", "delete character", "удалить", "назад"].contains(spoken) {
            return .backspace
        }
        if ["撤回", "撤销", "撤回刚才", "撤销刚才", "删除刚才", "删掉刚才", "清除刚才", "清空刚才", "undo", "clear", "clearthat", "deletethat", "removethat", "취소", "지워"].contains(compact)
            || ["clear that", "delete that", "remove that", "undo that", "отменить"].contains(spoken) {
            return .undoLast
        }
        return nil
    }

    // MARK: - Persona Panel

    private func loadPersonasForPanel(showLoading: Bool = false) {
        guard let token = getToken() else {
            voiceKeyboardView.showError(MobileStrings.loginRequired(), canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty)
            return
        }
        personasLoading = showLoading && personas.isEmpty
        personasRefreshing = !personasLoading
        renderPersonas()

        Task {
            do {
                let loaded = try await KeyboardAPIClient.getPersonas(token: token)
                await MainActor.run {
                    personas = sanitizePanelPersonas(loaded)
                    personasLoading = false
                    personasRefreshing = false
                    renderPersonas()
                }
            } catch {
                await MainActor.run {
                    personasLoading = false
                    personasRefreshing = false
                    voiceKeyboardView.showError(error.localizedDescription, canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty)
                    renderPersonas()
                }
            }
        }
    }

    private func activatePersona(_ persona: KeyboardPersona) {
        guard let token = getToken() else { return }
        pendingPersonaActionID = persona.id
        renderPersonas()
        Task {
            do {
                let activated = sanitizePanelPersona(try await KeyboardAPIClient.activatePersona(token: token, id: persona.id))
                await MainActor.run {
                    personas = personas.map { current in
                        var copy = current
                        copy.isActive = current.id == activated.id
                        if current.id == activated.id { copy.prompts = activated.prompts }
                        return copy
                    }
                    pendingPersonaActionID = nil
                    renderPersonas()
                    loadPersonasForPanel(showLoading: false)
                }
            } catch {
                await MainActor.run {
                    pendingPersonaActionID = nil
                    voiceKeyboardView.showError(error.localizedDescription, canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty)
                    renderPersonas()
                }
            }
        }
    }

    private func deactivatePersonas() {
        guard let token = getToken() else { return }
        pendingPersonaActionID = personas.first(where: { $0.isActive })?.id
        renderPersonas()
        Task {
            do {
                try await KeyboardAPIClient.deactivatePersonas(token: token)
                await MainActor.run {
                    personas = personas.map { persona in
                        var copy = persona
                        copy.isActive = false
                        if !copy.isBuiltin {
                            copy.prompts.transcribeEnabled = false
                            copy.prompts.rewriteEnabled = false
                            copy.prompts.intentHint = nil
                            copy.prompts.intentEnabled = false
                        }
                        return copy
                    }
                    pendingPersonaActionID = nil
                    renderPersonas()
                    loadPersonasForPanel(showLoading: false)
                }
            } catch {
                await MainActor.run {
                    pendingPersonaActionID = nil
                    voiceKeyboardView.showError(error.localizedDescription, canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty)
                    renderPersonas()
                }
            }
        }
    }

    private func togglePersonaModule(_ persona: KeyboardPersona, module: KeyboardPersonaModule) {
        guard let token = getToken() else { return }
        var prompts = persona.prompts
        prompts.intentHint = nil
        prompts.intentEnabled = false
        switch module {
        case .transcribe:
            prompts.transcribeEnabled = !prompts.transcribeEnabled && !(prompts.transcribePrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .rewrite:
            prompts.rewriteEnabled = !prompts.rewriteEnabled && !(prompts.rewritePrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        pendingPersonaActionID = persona.id
        renderPersonas()
        Task {
            do {
                let updated = sanitizePanelPersona(try await KeyboardAPIClient.updatePersonaModules(token: token, id: persona.id, prompts: prompts))
                await MainActor.run {
                    replacePersona(updated)
                    pendingPersonaActionID = nil
                    renderPersonas()
                    loadPersonasForPanel(showLoading: false)
                }
            } catch {
                await MainActor.run {
                    pendingPersonaActionID = nil
                    voiceKeyboardView.showError(error.localizedDescription, canRewrite: canRewrite, canUndo: !operationTextHistory.isEmpty, canRestore: !voiceRestoreText.isEmpty)
                    renderPersonas()
                }
            }
        }
    }

    private func replacePersona(_ updated: KeyboardPersona) {
        let sanitized = sanitizePanelPersona(updated)
        personas = personas.map { persona in
            persona.id == sanitized.id ? sanitized : persona
        }
    }

    private func sanitizePanelPersonas(_ list: [KeyboardPersona]) -> [KeyboardPersona] {
        list.map(sanitizePanelPersona)
    }

    private func sanitizePanelPersona(_ persona: KeyboardPersona) -> KeyboardPersona {
        var copy = persona
        copy.prompts.intentHint = nil
        copy.prompts.intentEnabled = false
        return copy
    }

    private func renderPersonas() {
        voiceKeyboardView.setPersonas(
            personas,
            loading: personasLoading,
            refreshing: personasRefreshing,
            pendingID: pendingPersonaActionID
        )
    }

    // MARK: - Shared History

    private func addHistory(operation: String, selectedText: String?) -> String {
        let id = UUID().uuidString
        var items = loadHistory()
        var item: [String: Any] = [
            "id": id,
            "operation": operation,
            "status": "processing",
            "retryable": true,
            "createdAt": Date().timeIntervalSinceReferenceDate,
        ]
        if let selectedText {
            item["selectedText"] = selectedText
        }
        items.insert(item, at: 0)
        if items.count > 100 {
            items = Array(items.prefix(100))
        }
        saveHistory(items)
        return id
    }

    private func updateHistory(
        id: String,
        status: String,
        transcript: String? = nil,
        result: String? = nil,
        actionType: String? = nil,
        error: String? = nil
    ) {
        var items = loadHistory()
        guard let idx = items.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
        items[idx]["status"] = status
        if let transcript { items[idx]["transcript"] = transcript }
        if let result { items[idx]["result"] = result }
        if let actionType { items[idx]["actionType"] = actionType }
        if let error { items[idx]["errorMessage"] = error }
        saveHistory(items)
    }

    private func loadHistory() -> [[String: Any]] {
        guard
            let data = defaults.data(forKey: DefaultsKey.history),
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return decoded
    }

    private func saveHistory(_ items: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return }
        defaults.set(data, forKey: DefaultsKey.history)
    }

    private func loadTemporaryTextHistory() {
        guard
            let data = defaults.data(forKey: DefaultsKey.textState),
            let state = try? JSONDecoder().decode(TemporaryTextState.self, from: data)
        else { return }
        operationTextHistory = Array(state.history.suffix(20))
        lastInsertedText = state.lastInsertedText
        voiceRestoreText = state.voiceRestoreText
    }

    private func persistTemporaryTextHistory() {
        let state = TemporaryTextState(
            history: Array(operationTextHistory.suffix(20)),
            lastInsertedText: lastInsertedText,
            voiceRestoreText: voiceRestoreText
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: DefaultsKey.textState)
    }
}

extension KeyboardViewController: VoiceKeyboardViewDelegate {

    func voiceKeyboardDidTapRecord() {
        if isActivelyRecording {
            stopRecording()
            return
        }
        if realtimeRecognitionEnabled { return }
        if voiceRecordingCoordinator.isPendingVoiceActivation {
            voiceRecordingCoordinator.resumeWhenKeyboardActive()
            return
        }
        ensureInputAvailableForAction { [weak self] in
            self?.pendingRewriteOriginal = ""
            self?.pendingRewriteTarget = .none
            self?.startRecordingAfterPermission(operation: .transcribe)
        }
    }

    func voiceKeyboardDidBeginRealtimeRecord() {
        beginRealtimeRecording()
    }

    func voiceKeyboardDidEndRealtimeRecord() {
        endRealtimeRecording()
    }

    func voiceKeyboardDidTapRewrite() { beginRewrite() }
    func voiceKeyboardDidTapUndo() { handleUndo() }
    func voiceKeyboardDidTapRestore() { handleRestoreVoiceText() }
    func voiceKeyboardDidTapQuickAction(_ action: KeyboardQuickAction) { performQuickAction(action) }
    func voiceKeyboardDidTapClearInput() { handleClearInputText() }
    func voiceKeyboardDidTapBackspace() { handleBackspace() }
    func voiceKeyboardDidTapNewline() { handleNewline() }
    func voiceKeyboardDidTapSymbol(_ symbol: String) { commitTextWithHistory(symbol) }

    func voiceKeyboardDidChangeFastMode(_ enabled: Bool) {
        fastModeEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.fastMode)
    }

    func voiceKeyboardDidChangeHandLayout(rightHand: Bool) {
        rightHandLayout = rightHand
        defaults.set(rightHand, forKey: DefaultsKey.handLayout)
    }

    func voiceKeyboardDidTapNextKeyboard() {
        advanceToNextInputMode()
    }

    func voiceKeyboardDidTapKeyboard() {
        if isActivelyRecording { voiceRecordingCoordinator.stopRecording() }
        typingCoordinator.enterKeyboardMode()
    }

    func voiceKeyboardDidTapDismiss() {
        dismissKeyboard()
    }

    func voiceKeyboardDidTapOpenApp() {
        KeyboardHostAppLauncher.openActivateVoiceSession(
            extensionContext: extensionContext,
            responder: view
        )
    }

    func voiceKeyboardDidRefreshPersonas() {
        loadPersonasForPanel(showLoading: personas.isEmpty)
    }

    func voiceKeyboardDidActivatePersona(_ persona: KeyboardPersona) {
        activatePersona(persona)
    }

    func voiceKeyboardDidDeactivatePersonas() {
        deactivatePersonas()
    }

    func voiceKeyboardDidTogglePersonaModule(_ persona: KeyboardPersona, module: KeyboardPersonaModule) {
        togglePersonaModule(persona, module: module)
    }
}

extension KeyboardViewController: KeyboardVoiceRecordingCoordinatorDelegate {

    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didUpdate phase: KeyboardVoiceRecordingPhase) {
        switch phase {
        case .idle:
            isProcessing = false
            refreshKeyboardState()
        case .wakingSession, .arming:
            if voiceRecordingCoordinator.isRealtimeModeActive {
                voiceKeyboardView.setRealtimeConnecting()
            } else {
                voiceKeyboardView.setWakingSession(isRewrite: pendingOperation.isRewrite)
            }
        case .recording(let remaining):
            recordingRemainingSec = remaining
            if typingCoordinator.isTypingMicActive {
                let total = max(maxRecordingDurationSec, 1)
                typingCoordinator.updateMicProgress(CGFloat(remaining) / CGFloat(total))
            }
            if voiceRecordingCoordinator.isRealtimeModeActive {
                voiceKeyboardView.setRealtimeRecording(remainingSeconds: remaining)
            } else {
                voiceKeyboardView.setRecording(isRewrite: pendingOperation.isRewrite, remainingSeconds: remaining)
            }
        case .processing:
            isProcessing = true
            if voiceRecordingCoordinator.isRealtimeModeActive {
                voiceKeyboardView.setRealtimeProcessing()
            } else {
                voiceKeyboardView.setProcessing(isRewrite: pendingOperation.isRewrite)
            }
        }
    }

    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didUpdate badge: KeyboardVoiceSessionBadge) {
        switch voiceRecordingCoordinator.phase {
        case .idle, .wakingSession, .arming:
            voiceKeyboardView.setSessionBadge(badge)
        case .recording, .processing:
            break
        }
    }

    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didUpdateAudioLevel level: Float) {
        voiceKeyboardView.updateAudioLevel(level)
        if typingCoordinator.isTypingMicActive { typingCoordinator.updateMicLevel(level) }
    }

    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didUpdateLiveText text: String) {
        replaceRealtimePreview(text)
    }

    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, showError message: String) {
        isProcessing = false
        if typingCoordinator.isTypingMicActive {
            typingCoordinator.handleMicCoordinatorError(message)
            clearRealtimePreview()
            return
        }
        clearRealtimePreview()
        voiceKeyboardView.showError(
            message,
            canRewrite: canRewrite,
            canUndo: !operationTextHistory.isEmpty,
            canRestore: !voiceRestoreText.isEmpty
        )
        refreshKeyboardState()
    }

    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didFinishWith result: KeyboardRecordingResult) {
        applyKeyboardRecordingResult(result)
    }

    func voiceCoordinatorNeedsOpenApp(_ coordinator: KeyboardVoiceRecordingCoordinator, url: URL) {
        KeyboardHostAppLauncher.openActivateVoiceSession(
            extensionContext: extensionContext,
            responder: view
        )
    }
}

// MARK: - 打字键盘模式

extension KeyboardViewController: TypingImeContext {

    func authToken() -> String? { getToken() }

    func isCreditsBlocked() -> Bool {
        if let liveCreditsRemaining { return liveCreditsRemaining <= 0 }
        return blockedReason == .creditsExhausted
    }

    func ensureInputAvailable(_ onReady: @escaping () -> Void) {
        ensureInputAvailableForAction(onReady)
    }

    func performKeyHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func requestExitTypingMode() {
        typingCoordinator.exitKeyboardMode()
        refreshKeyboardState()
    }

    func isMicRecording() -> Bool {
        typingCoordinator.isTypingMicActive && isActivelyRecording
    }

    func beginKeyboardMicCapture() {
        guard !isProcessing, !isActivelyRecording else {
            typingCoordinator.handleMicCoordinatorError(MobileStrings.recordingUnavailable())
            return
        }
        if voiceRecordingCoordinator.isPendingVoiceActivation {
            voiceRecordingCoordinator.resumeWhenKeyboardActive()
            return
        }
        typingCoordinator.setTypingMicActive(true)
        pendingOperation = .transcribe
        pendingRewriteOriginal = ""
        pendingRewriteTarget = .none
        clearRealtimePreview()
        voiceRecordingCoordinator.startRecording(
            operation: .transcribe,
            target: .none,
            selectedText: nil,
            replacementText: nil,
            context: nil,
            fastMode: false,
            realtimeMode: true,
            // 键盘麦克风固定 ≤60s(后端最长处理 60s;倒计时环随之递减)
            maxDurationSec: min(maxRecordingDurationSec, 60)
        )
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 键盘收起时若正在键盘内识别:结束识别(能控则等结果替换,否则断开),状态由 end 流程复位,不影响下次拉起
        if typingCoordinator.isTypingMicActive { endKeyboardMicCapture() }
        // 键盘会话结束:清除会话级粘性(数字页/自动英文),下次拉起回归输入框类型感知 + 用户偏好
        typingCoordinator.onSessionEnd()
    }

    func endKeyboardMicCapture() {
        guard typingCoordinator.isTypingMicActive else { return }
        if isActivelyRecording {
            isProcessing = true
            voiceRecordingCoordinator.stopRecording()
        } else {
            typingCoordinator.setTypingMicActive(false)
            typingCoordinator.stopMicUI()
        }
    }

    func refreshEditorContext() {
        typingCoordinator.onInputFieldChanged()
    }

    private func finishTypingMic(result: KeyboardRecordingResult) {
        // 收尾前先 flush 打字机:把预览补齐到完整目标并停掉揭示 timer,
        // 与语音模式 endRealtimeRecording 对齐,避免停手瞬间预览停在揭示一半的状态。
        realtimeTypewriter.flush()
        if !realtimePreviewText.isEmpty {
            deleteTextBeforeCursor(realtimePreviewText)
            realtimePreviewText = ""
        }
        typingCoordinator.finishTypingMic(result: result)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
