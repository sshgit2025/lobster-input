import Foundation
import os.log

private let voiceCoordLog = Logger(subsystem: "ssh2026.lobster-input-ios", category: "KeyboardVoiceRecording")

enum KeyboardVoiceSessionBadge {
    case ready
    case connecting
    case needsApp
}

enum KeyboardVoiceRecordingPhase: Equatable {
    case idle
    case wakingSession
    /// 已下发 start，等待主 App 确认 snapshot.recording
    case arming
    case recording(remainingSec: Int)
    case processing
}

protocol KeyboardVoiceRecordingCoordinatorDelegate: AnyObject {
    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didUpdate phase: KeyboardVoiceRecordingPhase)
    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didUpdate badge: KeyboardVoiceSessionBadge)
    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didUpdateAudioLevel level: Float)
    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didUpdateLiveText text: String)
    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, showError message: String)
    func voiceCoordinator(_ coordinator: KeyboardVoiceRecordingCoordinator, didFinishWith result: KeyboardRecordingResult)
    func voiceCoordinatorNeedsOpenApp(_ coordinator: KeyboardVoiceRecordingCoordinator, url: URL)
}

private struct PendingStartParams {
    let operation: KeyboardHandoffOperation
    let target: KeyboardHandoffTarget
    let selectedText: String?
    let replacementText: String?
    let context: String?
    let fastMode: Bool
    let realtimeMode: Bool
    let maxDurationSec: Int
}

/// 键盘侧语音录音编排：仅负责会话检测、指令下发与状态机，不触碰 AVFoundation。
final class KeyboardVoiceRecordingCoordinator {

    weak var delegate: KeyboardVoiceRecordingCoordinatorDelegate?

    private(set) var phase: KeyboardVoiceRecordingPhase = .idle
    private(set) var activeRequestID: String?
    private var recordingTotalDurationSec = 60
    private var pendingStart: PendingStartParams?
    private var uiTimer: Timer?
    private var statusObserver: KeyboardDarwinNotificationObserver?
    private var resultObserver: KeyboardDarwinNotificationObserver?
    private var didRequestHostAppOpen = false
    private var processingWatchdog: DispatchWorkItem?
    private var activeRealtimeMode = false

    /// 主 App 已在录音或键盘已进入录音态（不含「等待启动」的 arming）
    var isActivelyRecording: Bool {
        if case .recording = phase { return true }
        return KeyboardVoiceSessionBridge.snapshot().recording
    }

    /// 已拉起/已下发 start，但尚未进入真正录音（返回键盘后常卡在此）
    var isPendingVoiceActivation: Bool {
        switch phase {
        case .wakingSession, .arming: return true
        default: return false
        }
    }

    var isRealtimeModeActive: Bool {
        activeRealtimeMode || pendingStart?.realtimeMode == true
    }

    func configure() {
        KeyboardVoiceSessionBridge.invalidateStaleSessionIfNeeded()
        guard statusObserver == nil else { return }
        statusObserver = KeyboardVoiceSessionBridge.observe(
            KeyboardVoiceSessionBridge.NotificationName.statusChanged
        ) { [weak self] in
            DispatchQueue.main.async { self?.handleStatusChanged() }
        }
        resultObserver = KeyboardVoiceSessionBridge.observe(
            KeyboardVoiceSessionBridge.NotificationName.resultReady
        ) { [weak self] in
            DispatchQueue.main.async { self?.consumeResultIfNeeded() }
        }
    }

    func teardown() {
        uiTimer?.invalidate()
        uiTimer = nil
        statusObserver?.stop()
        resultObserver?.stop()
        statusObserver = nil
        resultObserver = nil
    }

    func refreshSessionBadge() {
        delegate?.voiceCoordinator(self, didUpdate: currentBadge())
    }

    /// 从主 App 返回输入法时续接唤醒/启动流程
    func resumeWhenKeyboardActive() {
        KeyboardVoiceSessionBridge.invalidateStaleSessionIfNeeded()
        let snapshot = KeyboardVoiceSessionBridge.snapshot()
        voiceCoordLog.info(
            "Resume keyboard voice phase=\(String(describing: self.phase), privacy: .public) ready=\(snapshot.isReady, privacy: .public) recording=\(snapshot.recording, privacy: .public)"
        )

        switch phase {
        case .wakingSession:
            if snapshot.isReady, let pending = pendingStart {
                issueStart(
                    operation: pending.operation,
                    target: pending.target,
                    selectedText: pending.selectedText,
                    replacementText: pending.replacementText,
                    context: pending.context,
                    fastMode: pending.fastMode,
                    realtimeMode: pending.realtimeMode,
                    maxDurationSec: pending.maxDurationSec
                )
            }
        case .arming:
            if snapshot.recording {
                setPhase(.recording(remainingSec: recordingTotalDurationSec))
                startUIMonitor()
                syncRecordingUI()
            } else if let requestID = activeRequestID {
                KeyboardVoiceSessionBridge.postCommand(action: .start, requestID: requestID)
                waitForRecordingStarted(attempt: 0, requestID: requestID, maxDurationSec: recordingTotalDurationSec)
            } else if snapshot.isReady, let pending = pendingStart {
                issueStart(
                    operation: pending.operation,
                    target: pending.target,
                    selectedText: pending.selectedText,
                    replacementText: pending.replacementText,
                    context: pending.context,
                    fastMode: pending.fastMode,
                    realtimeMode: pending.realtimeMode,
                    maxDurationSec: pending.maxDurationSec
                )
            }
        default:
            break
        }
        refreshSessionBadge()
    }

    func cancelPendingActivation() {
        if let requestID = activeRequestID {
            KeyboardVoiceSessionBridge.postCommand(action: .cancel, requestID: requestID)
        }
        reset()
    }

    func startRecording(
        operation: KeyboardHandoffOperation,
        target: KeyboardHandoffTarget,
        selectedText: String?,
        replacementText: String?,
        context: String?,
        fastMode: Bool,
        realtimeMode: Bool = false,
        maxDurationSec: Int
    ) {
        if phase == .arming || phase == .wakingSession {
            resumeWhenKeyboardActive()
            return
        }
        guard phase == .idle else { return }

        let snapshot = KeyboardVoiceSessionBridge.snapshot()
        voiceCoordLog.info(
            "Start recording op=\(operation.rawValue, privacy: .public) ready=\(snapshot.isReady, privacy: .public) alive=\(snapshot.isAlive, privacy: .public)"
        )

        if snapshot.isReady {
            issueStart(
                operation: operation,
                target: target,
                selectedText: selectedText,
                replacementText: replacementText,
                context: context,
                fastMode: fastMode,
                realtimeMode: realtimeMode,
                maxDurationSec: maxDurationSec
            )
        } else {
            pendingStart = PendingStartParams(
                operation: operation,
                target: target,
                selectedText: selectedText,
                replacementText: replacementText,
                context: context,
                fastMode: fastMode,
                realtimeMode: realtimeMode,
                maxDurationSec: maxDurationSec
            )
            didRequestHostAppOpen = false
            setPhase(.wakingSession)
            requestOpenHostApp()
            waitForSessionReady(
                attempt: 0,
                operation: operation,
                target: target,
                selectedText: selectedText,
                replacementText: replacementText,
                context: context,
                fastMode: fastMode,
                realtimeMode: realtimeMode,
                maxDurationSec: maxDurationSec
            )
        }
    }

    func stopRecording() {
        if let requestID = activeRequestID {
            setPhase(.processing)
            KeyboardVoiceSessionBridge.postCommand(action: .stop, requestID: requestID)
            scheduleProcessingWatchdog()
            voiceCoordLog.info("Stop requested \(requestID, privacy: .public)")
            return
        }
        if isPendingVoiceActivation {
            cancelPendingActivation()
            return
        }
        reset()
    }

    func reset() {
        activeRequestID = nil
        pendingStart = nil
        activeRealtimeMode = false
        recordingTotalDurationSec = 60
        didRequestHostAppOpen = false
        processingWatchdog?.cancel()
        processingWatchdog = nil
        stopUIMonitor()
        setPhase(.idle)
        refreshSessionBadge()
    }

    private func scheduleProcessingWatchdog() {
        processingWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.consumeResultIfNeeded()
            guard case .processing = self.phase else { return }
            if let requestID = self.activeRequestID {
                KeyboardVoiceSessionBridge.postCommand(action: .cancel, requestID: requestID)
            }
            self.reset()
            self.delegate?.voiceCoordinator(self, showError: MobileStrings.recordingUnavailable())
        }
        processingWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 75, execute: work)
    }

    func requestOpenHostApp() {
        delegate?.voiceCoordinatorNeedsOpenApp(self, url: KeyboardHostAppLauncher.activateVoiceSessionURL)
        didRequestHostAppOpen = true
    }

    func consumeResultIfNeeded() {
        guard let result = KeyboardRecordingBridge.consumeResult() else { return }
        processingWatchdog?.cancel()
        processingWatchdog = nil
        reset()
        delegate?.voiceCoordinator(self, didFinishWith: result)
    }

    // MARK: - Private

    private func currentBadge() -> KeyboardVoiceSessionBadge {
        let snapshot = KeyboardVoiceSessionBridge.snapshot()
        if snapshot.isReady { return .ready }
        if snapshot.enabled { return .needsApp }
        return .needsApp
    }

    private func setPhase(_ newPhase: KeyboardVoiceRecordingPhase) {
        phase = newPhase
        delegate?.voiceCoordinator(self, didUpdate: newPhase)
        refreshSessionBadge()
    }

    private func issueStart(
        operation: KeyboardHandoffOperation,
        target: KeyboardHandoffTarget,
        selectedText: String?,
        replacementText: String?,
        context: String?,
        fastMode: Bool,
        realtimeMode: Bool,
        maxDurationSec: Int
    ) {
        let request = KeyboardRecordingBridge.requestRecording(
            operation: operation,
            target: target,
            selectedText: selectedText,
            replacementText: replacementText,
            context: context,
            fastMode: fastMode,
            realtimeMode: realtimeMode
        )
        activeRequestID = request.id
        activeRealtimeMode = realtimeMode
        recordingTotalDurationSec = max(5, maxDurationSec)
        KeyboardVoiceSessionBridge.postCommand(action: .start, requestID: request.id)
        setPhase(.arming)
        waitForRecordingStarted(attempt: 0, requestID: request.id, maxDurationSec: maxDurationSec)
    }

    private func waitForSessionReady(
        attempt: Int,
        operation: KeyboardHandoffOperation,
        target: KeyboardHandoffTarget,
        selectedText: String?,
        replacementText: String?,
        context: String?,
        fastMode: Bool,
        realtimeMode: Bool,
        maxDurationSec: Int
    ) {
        if KeyboardVoiceSessionBridge.snapshot().isReady {
            issueStart(
                operation: operation,
                target: target,
                selectedText: selectedText,
                replacementText: replacementText,
                context: context,
                fastMode: fastMode,
                realtimeMode: realtimeMode,
                maxDurationSec: maxDurationSec
            )
            return
        }
        if attempt == 12 || attempt == 28, !KeyboardVoiceSessionBridge.snapshot().isReady {
            requestOpenHostApp()
        }
        guard attempt < 50 else {
            voiceCoordLog.error("Voice session activation timed out")
            reset()
            delegate?.voiceCoordinator(self, showError: MobileStrings.voiceSessionNotReady())
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForSessionReady(
                attempt: attempt + 1,
                operation: operation,
                target: target,
                selectedText: selectedText,
                replacementText: replacementText,
                context: context,
                fastMode: fastMode,
                realtimeMode: realtimeMode,
                maxDurationSec: maxDurationSec
            )
        }
    }

    private func waitForRecordingStarted(attempt: Int, requestID: String, maxDurationSec: Int) {
        let snapshot = KeyboardVoiceSessionBridge.snapshot()
        if snapshot.recording {
            if case .arming = phase {
                setPhase(.recording(remainingSec: recordingTotalDurationSec))
                startUIMonitor()
            }
            syncRecordingUI()
            return
        }
        if let result = KeyboardRecordingBridge.peekResult(forRequestID: requestID) {
            reset()
            if let error = result.error, !error.isEmpty {
                delegate?.voiceCoordinator(self, showError: error)
            } else {
                delegate?.voiceCoordinator(self, showError: MobileStrings.recordingUnavailable())
            }
            return
        }
        guard attempt < 90 else {
            voiceCoordLog.error("Recording start timed out \(requestID, privacy: .public)")
            KeyboardVoiceSessionBridge.postCommand(action: .cancel, requestID: requestID)
            reset()
            delegate?.voiceCoordinator(self, showError: MobileStrings.recordingUnavailable())
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForRecordingStarted(attempt: attempt + 1, requestID: requestID, maxDurationSec: maxDurationSec)
        }
    }

    private func handleStatusChanged() {
        let snapshot = KeyboardVoiceSessionBridge.snapshot()
        switch phase {
        case .wakingSession:
            if snapshot.isReady, let pending = pendingStart {
                issueStart(
                    operation: pending.operation,
                    target: pending.target,
                    selectedText: pending.selectedText,
                    replacementText: pending.replacementText,
                    context: pending.context,
                    fastMode: pending.fastMode,
                    realtimeMode: pending.realtimeMode,
                    maxDurationSec: pending.maxDurationSec
                )
            }
        case .arming:
            if snapshot.recording {
                setPhase(.recording(remainingSec: recordingTotalDurationSec))
                startUIMonitor()
                syncRecordingUI()
            } else if let requestID = activeRequestID {
                waitForRecordingStarted(attempt: 0, requestID: requestID, maxDurationSec: recordingTotalDurationSec)
            }
        case .recording:
            syncRecordingUI()
        case .processing:
            consumeResultIfNeeded()
        default:
            break
        }
    }

    private func syncRecordingUI() {
        let snapshot = KeyboardVoiceSessionBridge.snapshot()
        if snapshot.recording {
            var remaining = recordingTotalDurationSec
            if let startedAt = snapshot.recordingStartedAt {
                let elapsed = max(0, Int(Date().timeIntervalSince1970 - startedAt))
                remaining = max(0, recordingTotalDurationSec - elapsed)
            }
            setPhase(.recording(remainingSec: remaining))
            delegate?.voiceCoordinator(self, didUpdateAudioLevel: snapshot.audioLevel)
            delegate?.voiceCoordinator(self, didUpdateLiveText: snapshot.liveText)
        }
    }

    private func startUIMonitor() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, case .recording = self.phase else { return }
            self.syncRecordingUI()
        }
    }

    private func stopUIMonitor() {
        uiTimer?.invalidate()
        uiTimer = nil
    }
}
