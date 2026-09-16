/// AppHotKeyHandler.swift
/// 快捷键事件处理器（单例），串联录音→识别→填充的完整流程。
/// 核心流程:
///   1. 按下快捷键 → 校验权限 → 记录目标 App → 抓取剪贴板 → 开始录音
///   2. 再次按下 → 停止录音 → 读取选中文本 → 上传后端 → 写入剪贴板 → Cmd+V 填充
/// 同时负责历史记录的创建和状态更新，支持失败重试。
import Foundation
import Combine
import AppKit
import os.log

private let flowLog = Logger(subsystem: "ssh2026.voice-input", category: "HotKeyFlow")

@MainActor
final class AppHotKeyHandler: ObservableObject {

    static let shared = AppHotKeyHandler()

    private init() {
        NotificationCenter.default.addObserver(
            forName: .recordingMaxDurationReached,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.stopAndProcess()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .overlayDismissedDuringRecording,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.cancelDuringRecording()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .overlayDismissedDuringProcessing,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if RealtimeAudioStreamer.shared.state == .processing {
                    self.realtimeWorkflow.cancelProcessing()
                } else {
                    self.cancelDuringProcessing()
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .realtimeOverlayDismissedDuringStreaming,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.realtimeWorkflow.cancelStreaming()
            }
        }
    }

    private let recorder    = AudioRecorder.shared
    private let realtimeStreamer = RealtimeAudioStreamer.shared
    private let historyStore = HistoryStore.shared
    private lazy var realtimeWorkflow = RealtimeRecordingWorkflow(actionHandler: self)
    private var currentOperation: String?
    /// 录音开始时记录的目标 App PID（识别完成后向它填充文本）
    private var targetAppPid: pid_t?
    /// 录音开始时抓取的剪贴板历史
    private var clipboardHistory: [String] = []
    private var clipboardItems: [ClipboardContextItem] = []
    /// 当前正在处理的历史记录 ID（用于识别中取消时标记）
    private var processingRecordId: String?
    /// 用户在识别中点击关闭，标记忽略本次 API 返回结果
    private var cancelledRecordIds: Set<String> = []
    /// 录音触发前保存的文本选区快照（用于浮窗弹出后无感知恢复选区）
    private var selectionSnapshot: SelectionSnapshot?
    /// 录音引擎正在启动中（浮窗已显示但 recorder.state 还是 idle），防止重复触发
    private var isStartingRecording = false
    /// 停止录音到识别回填的完整链路只允许单飞，避免并发 stop/upload 重复回填。
    private var isStopAndProcessInFlight = false
    /// 选区快照异步读取状态机：按下快捷键时立即后台发起，录音期间与引擎并行执行。
    /// stop 时同步检查 resolvedValue；未完成则 await result() 挂起等待（零 CPU 轮询）。
    /// 取消时调用 cancel()，所有等待者立即收到 nil。
    private var snapshotFuture: SnapshotFuture?
    private var clipboardHistoryTask: Task<[String], Never>?
    private var clipboardItemsTask: Task<[ClipboardContextItem], Never>?
    private var contextCaptureTask: Task<Void, Never>?

    /// 引导页「带页内输入框的步骤」期间置为 true：结果由 RecordingResultStore 的 onReceive
    /// 写入页内输入框，跳过系统 Cmd+V 粘贴，避免引导页内 TextEditor 被写入两次。
    /// 注意：只读改写等以浮窗为预期结果的步骤不会置位（由 OnboardingView 按步骤同步），
    /// 否则 TextFillEngine 的浮窗出口会被短路。
    var skipSystemPaste: Bool = false

    func handle(_ combo: HotKeyCombo) {
        if combo == .screenshot {
            DebugTrace.log("HotKey: screenshot combo received, recorderState=\(recorder.state)")
            guard recorder.state == .idle, realtimeStreamer.state == .idle else { return }
            ScreenshotManager.shared.captureToClipboard()
            return
        }

        if RealtimeRecognitionStore.isEnabled {
            realtimeWorkflow.handle(combo)
            return
        }

        switch recorder.state {
        case .idle:
            guard !isStartingRecording else { return }
            // 未登录时拒绝触发，快捷键监听在退出登录后仍存活，需在此处拦截
            guard AuthStore.shared.isLoggedIn else { return }
            // macOS 26 上辅助功能权限未授权时，AX API 调用会触发 DriverKit 空指针崩溃
            // 此时快捷键监听可能因 defaultTap 降级而处于半工作状态，需在此处拦截
            // 辅助功能未授权 → SelectedTextReader.snapshot() 内的 AX 调用不安全，直接跳过
            guard PermissionManager.shared.refreshAccessibilityStatus(reason: "hotkey \(combo.rawValue)") else {
                DebugTrace.log("HotKey ignored: accessibility not granted after refresh combo=\(combo.rawValue)")
                return
            }
            currentOperation = combo.rawValue
            snapshotFuture = nil
            clipboardHistoryTask = nil
            clipboardItemsTask = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            Task { await startRecording() }
        case .starting:
            cancelDuringRecording()
        case .recording:
            Task { await stopAndProcess() }
        case .processing:
            break
        }
    }

    // MARK: - Cancel

    /// 录音中取消：丢弃音频、不创建历史、关麦、关浮窗
    private func cancelDuringRecording() {
        // state 可能还在 idle（engine 正在启动中）或已经是 recording
        guard recorder.state == .recording || recorder.state == .starting || recorder.state == .idle else { return }
        recorder.cancelRecording()
        currentOperation = nil
        targetAppPid = nil
        clipboardHistory = []
        clipboardItems = []
        selectionSnapshot = nil
        // 取消后台选区读取，立即唤醒所有挂起的 result() 等待者返回 nil
        snapshotFuture?.cancel()
        snapshotFuture = nil
        clipboardHistoryTask?.cancel()
        clipboardHistoryTask = nil
        clipboardItemsTask?.cancel()
        clipboardItemsTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        // 重置所有飞行标志，确保取消后下次快捷键能正常进入录音及停止流程
        isStartingRecording = false
        isStopAndProcessInFlight = false
        FillVerifier.shared.detach()
        RecordingOverlayWindowController.shared.hide()
    }

    /// 识别中取消：保留历史记录（标记为用户取消），忽略后续 API 回调
    private func cancelDuringProcessing() {
        guard recorder.state == .processing else { return }
        if let rid = processingRecordId {
            cancelledRecordIds.insert(rid)
            historyStore.update(id: rid, status: .failed, error: L10n.errorUserCancelled)
        }
        processingRecordId = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        FillVerifier.shared.detach()
        RecordingOverlayWindowController.shared.hide()
        recorder.resetToIdle()
    }

    // MARK: - Recording

    private func startRecording() async {
        let pm = PermissionManager.shared

        // 1. 校验麦克风权限（必需，未授权则阻塞请求）
        if pm.microphoneStatus != .granted {
            await pm.requestMicrophone()
            pm.refreshStatuses()
            if pm.microphoneStatus != .granted {
                currentOperation = nil
                snapshotFuture?.cancel()
                snapshotFuture = nil
                clipboardHistoryTask?.cancel()
                clipboardHistoryTask = nil
                clipboardItemsTask?.cancel()
                clipboardItemsTask = nil
                contextCaptureTask?.cancel()
                contextCaptureTask = nil
                return
            }
        }

        let axTrusted = pm.refreshAccessibilityStatus(reason: "startRecording")
        flowLog.info("AX trusted refreshed=\(axTrusted), accessibilityStatus=\(pm.accessibilityStatus == .granted ? "granted" : "denied/notDetermined")")
        DebugTrace.log("startRecording: AX trusted refreshed=\(axTrusted), accessibilityStatus=\(pm.accessibilityStatus == .granted ? "granted" : "denied/notDetermined")")
        guard axTrusted else {
            currentOperation = nil
            snapshotFuture?.cancel()
            snapshotFuture = nil
            clipboardHistoryTask?.cancel()
            clipboardHistoryTask = nil
            clipboardItemsTask?.cancel()
            clipboardItemsTask = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            return
        }

        // 2. 记录目标 App PID。剪贴板读取在后台并行，避免低配机器阻塞浮窗即时反馈。
        //    同时挂载填充确认观察者（兼做 Chromium/Electron AX 树预热，录音期间零成本完成）。
        targetAppPid = FocusedInputFiller.captureTargetApp()
        if let pid = targetAppPid {
            FillVerifier.shared.attach(pid: pid)
        }

        // 3. 先进入启动视觉态，再显示浮窗，避免 SwiftUI 首帧渲染 idle UI 后抖动切换。
        isStartingRecording = true
        guard recorder.prepareStartingVisualState() else {
            isStartingRecording = false
            currentOperation = nil
            targetAppPid = nil
            snapshotFuture?.cancel()
            snapshotFuture = nil
            clipboardHistoryTask?.cancel()
            clipboardHistoryTask = nil
            clipboardItemsTask?.cancel()
            clipboardItemsTask = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            return
        }
        RecordingOverlayWindowController.shared.show()

        // 4. 只等录音引擎启动，不等 snapshot。
        //    snapshot 由 snapshotFuture 在后台独立运行，与引擎启动完全隔离。
        //    引擎就绪即可进入录音状态，snapshot 慢不影响这条路径。
        DebugTrace.log("startRecording: starting engine (snapshot running independently in background)...")
        let success = await startRecorderWithTimeout(seconds: 6)
        isStartingRecording = false
        flowLog.info("startRecording engine: \(success)")
        DebugTrace.log("startRecording engine result: \(success), currentOperation=\(currentOperation ?? "nil")")

        // 5. 引擎就绪后再启动 rewrite/clipboard 上下文采集，避免 AX、Cmd+C 和图片剪贴板读取
        //    与音频冷启动竞争。上下文采集仍在录音期间并行完成，stop 时再消费结果。
        if success, let operation = currentOperation {
            beginContextCapture(for: operation)
        }

        // 6. 引擎就绪后，尝试同步查询 snapshot 结果（通常 AX 直读已完成）。
        //    若已完成则做 restore；若尚未完成则跳过，等 stopAndProcess 时再取结果。
        if let snap = await snapshotFuture?.resolvedValue {
            selectionSnapshot = snap
            flowLog.info("snapshot already ready after engine start: textLen=\(snap.text.count)")
            DebugTrace.log("snapshot ready: textLen=\(snap.text.count)")
            let restored = SelectedTextRestorer.restore(snap)
            flowLog.info("immediate restore: \(restored)")
        } else {
            flowLog.info("snapshot still pending after engine start, will await in stopAndProcess")
            DebugTrace.log("snapshot pending: restore deferred to stopAndProcess")
        }

        // 检查：若用户在 engine 启动期间取消了录音，则引擎启动后立即停止
        guard currentOperation != nil else {
            DebugTrace.log("startRecording: user cancelled during engine startup, discarding")
            if success { recorder.cancelRecording() }
            return
        }

        if !success {
            // 引擎启动失败：隐藏浮窗并清理所有状态
            recorder.recoverAfterEngineStartTimeout()
            RecordingOverlayWindowController.shared.hide()
            currentOperation = nil
            targetAppPid = nil
            FillVerifier.shared.detach()
            clipboardHistory = []
            clipboardItems = []
            selectionSnapshot = nil
            snapshotFuture?.cancel()
            snapshotFuture = nil
            clipboardHistoryTask?.cancel()
            clipboardHistoryTask = nil
            clipboardItemsTask?.cancel()
            clipboardItemsTask = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
        }
    }

    private func beginContextCapture(for operation: String) {
        contextCaptureTask?.cancel()
        contextCaptureTask = nil

        if operation == "transcribe" {
            snapshotFuture = nil
            clipboardHistoryTask = Task(priority: .utility) {
                await ClipboardHistoryReader.readTextOnlyAsync(maxItems: 3)
            }
            clipboardItemsTask = Task(priority: .utility) {
                await ClipboardHistoryReader.readItemsNonBlocking(maxItems: 1)
            }
            return
        }

        let future = SnapshotFuture()
        snapshotFuture = future
        contextCaptureTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled,
                  self.currentOperation == operation,
                  self.recorder.state == .recording else {
                future.cancel()
                return
            }

            future.start()
            self.clipboardHistoryTask = Task(priority: .utility) {
                await ClipboardHistoryReader.readTextOnlyAsync(maxItems: 5)
            }
            self.clipboardItemsTask = Task(priority: .utility) {
                await ClipboardHistoryReader.readItemsNonBlocking(maxItems: 1)
            }
        }
    }

    private func startRecorderWithTimeout(seconds: TimeInterval) async -> Bool {
        let startTask = Task { [recorder] in
            await recorder.startRecording()
        }

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var timeoutTask: Task<Void, Never>?

            Task {
                let result = await startTask.value
                finish(result)
            }
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard !startTask.isCancelled else { return }
                startTask.cancel()
                DebugTrace.log("startRecording: engine start timeout after \(seconds)s")
                finish(false)
            }

            func finish(_ result: Bool) {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()
                timeoutTask?.cancel()
                continuation.resume(returning: result)
            }
        }
    }

    private func stopAndProcess() async {
        guard !isStopAndProcessInFlight else {
            DebugTrace.log("stopAndProcess: ignored because another stop flow is in flight")
            return
        }
        isStopAndProcessInFlight = true
        defer { isStopAndProcessInFlight = false }

        guard let audioURL = await recorder.stopRecording() else {
            DebugTrace.log("stopAndProcess: recorder.stopRecording returned nil")
            RecordingOverlayWindowController.shared.hide()
            return
        }
        DebugTrace.log("stopAndProcess: recorder.stopRecording OK → \(audioURL.lastPathComponent)")

        let operation = currentOperation ?? "transcribe"

        // 取 snapshot 结果：
        //   1. startRecording 引擎就绪后若 snapshot 已完成，已写入 selectionSnapshot → 直接用
        //   2. snapshot 仍在后台运行（超长文本 Cmd+C 兜底场景）→ await result() 挂起等待
        //      CheckedContinuation 挂起，零 CPU 轮询，future 完成时自动唤醒
        //   3. future 已被 cancel（用户取消后又触发了 stop，理论上不可达）→ 返回 nil
        let resolvedSnapshot: SelectionSnapshot?
        if let snap = selectionSnapshot {
            // 最常见路径：引擎启动期间 snapshot 已完成并写入
            resolvedSnapshot = snap
            DebugTrace.log("stopAndProcess: snapshot already resolved (textLen=\(snap.text.count))")
        } else if let future = snapshotFuture {
            // snapshot 仍在后台，挂起等待（不轮询，不阻塞 CPU）
            DebugTrace.log("stopAndProcess: snapshot still pending, awaiting result()...")
            resolvedSnapshot = await future.result()
            DebugTrace.log("stopAndProcess: snapshot result arrived, hasSnap=\(resolvedSnapshot != nil)")
        } else {
            resolvedSnapshot = nil
        }

        // 若此时才拿到结果（路径 2），补做一次选区恢复
        if selectionSnapshot == nil, let snap = resolvedSnapshot {
            selectionSnapshot = snap
            let restored = SelectedTextRestorer.restore(snap)
            flowLog.info("processing-phase restore (deferred): \(restored)")
        }

        let selectedText = resolvedSnapshot?.text
        let savedPid       = targetAppPid
        let savedClipboard = await clipboardHistoryTask?.value ?? clipboardHistory
        let savedClipboardItems = await clipboardItemsTask?.value ?? clipboardItems
        DebugTrace.log(
            "stopAndProcess: clipboard historyCount=\(savedClipboard.count) itemCount=\(savedClipboardItems.count)"
        )
        let savedSnapshot  = resolvedSnapshot
        currentOperation = nil
        targetAppPid = nil
        clipboardHistory = []
        clipboardItems = []
        selectionSnapshot = nil
        snapshotFuture = nil
        clipboardHistoryTask = nil
        clipboardItemsTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil

        let persistedPath = await historyStore.persistAudio(from: audioURL)
        DebugTrace.log("stopAndProcess: persisted audio → \(persistedPath ?? "nil")")

        var record = RecordingHistory(
            operation: operation,
            audioFilePath: persistedPath,
            selectedText: selectedText
        )
        record.status = .processing
        historyStore.add(record)
        let recordId = record.id
        processingRecordId = recordId

        try? FileManager.default.removeItem(at: audioURL)

        await processRecord(id: recordId, operation: operation,
                            audioPath: persistedPath, selectedText: selectedText,
                            snapshot: savedSnapshot,
                            clipboardHistory: savedClipboard,
                            clipboardItems: savedClipboardItems,
                            targetPid: savedPid)
    }

    /// 通用识别方法（新录音 & 重试都走这里）
    func processRecord(id: String, operation: String,
                       audioPath: String?, selectedText: String?,
                       snapshot: SelectionSnapshot? = nil,
                       clipboardHistory: [String]? = nil,
                       clipboardItems: [ClipboardContextItem]? = nil,
                       targetPid: pid_t? = nil) async {
        guard let path = audioPath,
              FileManager.default.fileExists(atPath: path) else {
            historyStore.update(id: id, status: .failed, error: L10n.errorInvalidAudio)
            return
        }

        let audioURL = URL(fileURLWithPath: path)
        historyStore.markProcessingStarted(id: id)
        let fileSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        DebugTrace.log("processRecord: upload start id=\(id) op=\(operation) file=\(audioURL.lastPathComponent) bytes=\(fileSize)")

        do {
            let fastMode = operation == "transcribe" && TranscribeFastModeStore.isEnabled
            let response: AudioProcessResponse
            if operation == "agent" {
                let streamedText = HotKeySearchStreamTextBuffer()
                let streamID = UUID()
                response = try await APIClient.shared.processAudioStream(
                    fileURL: audioURL,
                    operation: operation,
                    selectedText: selectedText,
                    clipboardHistory: clipboardHistory,
                    clipboardItems: clipboardItems,
                    fastMode: fastMode,
                    streamCallbacks: AudioProcessStreamCallbacks(
                        onSearchStart: {
                            await MainActor.run {
                                ResultOverlayWindowController.shared.beginMarkdownStream(streamID: streamID)
                            }
                        },
                        onSearchDelta: { delta in
                            let text = await streamedText.append(delta)
                            await MainActor.run {
                                ResultOverlayWindowController.shared.updateMarkdown(text: text, streamID: streamID)
                            }
                        }
                    )
                )
            } else {
                response = try await APIClient.shared.processAudio(
                    fileURL: audioURL,
                    operation: operation,
                    selectedText: selectedText,
                    clipboardHistory: clipboardHistory,
                    clipboardItems: clipboardItems,
                    fastMode: fastMode
                )
            }
            DebugTrace.log(
                "processRecord: upload success id=\(id) action=\(response.actionType.rawValue) transcriptLen=\(response.transcript.count) resultLen=\(response.result.count)"
            )

            // 用户在等待期间点击了关闭，忽略本次结果
            if cancelledRecordIds.remove(id) != nil {
                processingRecordId = nil
                return
            }

            // 存储到历史的 result：tip 用国际化文案，openclaw 流式任务用占位符（完成后会更新）
            let resultToStore: String
            switch response.actionType {
            case .tip:
                resultToStore = L10n.tipForCode(response.result)
            case .openclawExecute, .openclawSlashCommand:
                resultToStore = L10n.openclawProcessing
            default:
                resultToStore = response.result
            }

            historyStore.update(
                id: id,
                status: .success,
                transcript: response.transcript,
                result: resultToStore,
                actionType: response.actionType.rawValue
            )
            RecordingResultStore.shared.update(
                transcript: response.transcript,
                result: resultToStore,
                error: nil
            )

            handleAction(response.actionType, text: response.result, operation: operation, selectedText: selectedText, clipboardItems: clipboardItems, snapshot: snapshot, targetPid: targetPid, clarifyQuestion: response.clarifyQuestion, recordId: id)

            if let remaining = response.creditsRemaining {
                AuthStore.shared.creditsRemaining = remaining
            }
            Task { await AppDelegate.fetchUserPlanInfo() }

            if let update = response.configUpdate, let newMax = update.maxDurationSec {
                recorder.maxDuration = TimeInterval(newMax)
            }
            if let warning = response.warning {
                showWarningAlert(warning)
            }

            processingRecordId = nil
            RecordingOverlayWindowController.shared.hide()
            AudioRecorder.shared.resetToIdle()

        } catch {
            DebugTrace.log("processRecord: upload failed id=\(id) error=\(error.localizedDescription)")
            if cancelledRecordIds.remove(id) != nil {
                processingRecordId = nil
                return
            }

            let apiError = error as? APIError
            if case .unauthorized = apiError {
                RecordingResultStore.shared.clear()
                AuthStore.shared.logout()
                historyStore.update(id: id, status: .failed, error: L10n.errorUnauthorized)
            } else if case .userBanned = apiError {
                RecordingResultStore.shared.clear()
                AuthStore.shared.logout()
                historyStore.update(id: id, status: .failed, error: apiError?.errorDescription ?? "")
            } else if apiError?.isCreditsExhausted == true {
                Task { await AppDelegate.fetchUserPlanInfo() }
                let msg = L10n.errorCreditsExhausted
                historyStore.update(id: id, status: .failed, error: msg, retryable: false)
                RecordingResultStore.shared.update(transcript: "", result: "", error: msg)
                TipOverlayWindowController.shared.show(message: msg)
            } else {
                let msg = apiError?.errorDescription ?? error.localizedDescription
                let canRetry = !(apiError?.isNonRetryable ?? false)
                historyStore.update(id: id, status: .failed, error: msg, retryable: canRetry)
                RecordingResultStore.shared.update(transcript: "", result: "", error: msg)

                if let configUpdate = apiError?.configUpdate, let newMax = configUpdate.maxDurationSec {
                    recorder.maxDuration = TimeInterval(newMax)
                }
                if apiError?.isNonRetryable == true {
                    showWarningAlert(msg)
                }
            }
            processingRecordId = nil
            RecordingOverlayWindowController.shared.hide()
            AudioRecorder.shared.resetToIdle()
        }
    }

    func handleRealtimeWorkflowAction(
        _ actionType: ActionType,
        text: String,
        operation: String,
        selectedText: String?,
        clipboardItems: [ClipboardContextItem]? = nil,
        snapshot: SelectionSnapshot?,
        targetPid: pid_t?,
        clarifyQuestion: String? = nil,
        recordId: String? = nil
    ) {
        handleAction(
            actionType,
            text: text,
            operation: operation,
            selectedText: selectedText,
            clipboardItems: clipboardItems,
            snapshot: snapshot,
            targetPid: targetPid,
            clarifyQuestion: clarifyQuestion,
            recordId: recordId
        )
    }

    func showRealtimeWorkflowWarning(_ message: String) {
        showWarningAlert(message)
    }

    /// 根据后端返回的 actionType 分支执行对应操作
    /// - Parameters:
    ///   - actionType: 后端返回的操作类型
    ///   - text: 处理结果文本
    ///   - selectedText: 录音时选中的原始文本（rewrite 上下文）
    ///   - snapshot: 选区快照（含选区 AX 元素，rewrite 场景用于原位替换）
    ///   - targetPid: 目标 App PID
    ///   - clarifyQuestion: clarify 模式时 LLM 生成的询问文案
    ///   - recordId: 历史记录 ID（openclaw 流式完成后用于更新历史）
    private func handleAction(
        _ actionType: ActionType,
        text: String,
        operation: String,
        selectedText: String?,
        clipboardItems: [ClipboardContextItem]? = nil,
        snapshot: SelectionSnapshot?,
        targetPid: pid_t?,
        clarifyQuestion: String? = nil,
        recordId: String? = nil
    ) {
        switch actionType {
        case .paste:
            // 填充/浮窗的判定与执行统一收敛在 TextFillEngine（快探 + 盲填确认）
            guard !text.isEmpty else { return }
            flowLog.info("handleAction(.paste): selectedText=\(selectedText?.isEmpty == false ? "yes(\(selectedText!.count))" : "none"), snapshotSource=\(snapshot?.source.rawValue ?? "nil")")
            DebugTrace.log("handleAction(.paste): selectedText=\(selectedText?.isEmpty == false ? "yes" : "none"), snapshotSource=\(snapshot?.source.rawValue ?? "nil")")
            attemptFillResult(text, targetPid: targetPid)
        case .clarify:
            // LLM 意图不明：显示询问悬浮窗（不抢焦点），result 为原选中文本（不做任何粘贴操作）
            let question = clarifyQuestion ?? L10n.overlayClarifyFallback
            ClarifyOverlayWindowController.shared.show(question: question)
        case .showMarkdown:
            // 搜索结果等 Markdown 内容：拉起悬浮窗展示，不写入输入框
            ResultOverlayWindowController.shared.showMarkdown(text: text)
        case .tip:
            // 系统操作反馈提示（如 openclaw 开启/关闭）：
            // result 为 tip code 字符串，通过 L10n.tipForCode 映射为国际化文案
            OpenClawManager.shared.handleSessionTipCode(text)
            let tipMessage = L10n.tipForCode(text)
            TipOverlayWindowController.shared.show(message: tipMessage)
        case .openclawExecute:
            // 自然语言任务 → Gateway RPC 发送，完成后更新历史为 OpenClaw 实际输出
            let onComplete: ((String) -> Void)? = recordId.map { rid in
                { [weak self] full in
                    self?.historyStore.update(id: rid, status: .success, result: full.isEmpty ? nil : full)
                }
            }
            OpenClawManager.shared.sendToOpenClaw(text, selectedText: selectedText, clipboardItems: clipboardItems, onComplete: onComplete)
        case .openclawSlashCommand:
            // slash 命令（/stop 等）→ Gateway RPC，完成后更新历史
            let onComplete: ((String) -> Void)? = recordId.map { rid in
                { [weak self] full in
                    self?.historyStore.update(id: rid, status: .success, result: full.isEmpty ? nil : full)
                }
            }
            OpenClawManager.shared.sendCommandToOpenClaw(text, onComplete: onComplete)
        case .openclawCliCommand:
            // 无交互 CLI 命令 → 复用 openclaw 专属终端执行（不更新历史）
            OpenClawManager.shared.sendCommandToOpenClaw(text)
        case .openclawInteractive:
            // 交互式 CLI 命令 → 新建独立终端（需用户交互）
            OpenClawManager.shared.sendCommandToOpenClaw(text)
        }
    }

    /// 弹出系统 Alert 提示用户后端返回的警告信息
    private func showWarningAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.appNameFull
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.btnDone)
        alert.runModal()
    }

    /// 通过 TextFillEngine 填充文本；引擎判定为浮窗时展示结果浮窗，保证识别结果不丢失。
    private func attemptFillResult(_ text: String, targetPid: pid_t?) {
        guard !text.isEmpty else { return }

        // 引导页期间由 RecordingResultStore.onReceive 负责写入页内输入框，
        // 跳过系统写入，避免自己程序的 TextEditor 被写入两次
        if skipSystemPaste { return }

        Task { @MainActor in
            let resolution = await TextFillEngine.shared.fill(text: text, targetPid: targetPid)
            DebugTrace.log("attemptFillResult: \(resolution.summary)")
            if !resolution.isFilled {
                ResultOverlayWindowController.shared.show(text: text)
            }
        }
    }

    private actor HotKeySearchStreamTextBuffer {
        private var text = ""

        func append(_ delta: String) -> String {
            text += delta
            return text
        }
    }

}
