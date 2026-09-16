import Foundation

private enum RealtimeWorkflowPhase: Equatable {
    case idle
    case starting(UUID)
    case streaming(UUID)
    case stopping(UUID)
    case processing(UUID)
}

private struct RealtimeContextResult {
    let selectedText: String?
    let snapshot: SelectionSnapshot?
    let clipboardHistory: [String]
    let clipboardItems: [ClipboardContextItem]

    static let empty = RealtimeContextResult(
        selectedText: nil,
        snapshot: nil,
        clipboardHistory: [],
        clipboardItems: []
    )
}

private enum RealtimeWaitResult<Value> {
    case value(Value)
    case timedOut
}

private struct RealtimeFinalResolution {
    let text: String
    let language: String?
    let asrSessionID: String?
    let didSendFinishSignal: Bool
    let clientFinalIssue: String?
}

@MainActor
private final class RealtimeContextCapture {
    private let operation: String
    private var snapshotFuture: SnapshotFuture?
    private var delayedSnapshotTask: Task<Void, Never>?
    private var clipboardHistoryTask: Task<[String], Never>?
    private var clipboardItemsTask: Task<[ClipboardContextItem], Never>?
    private var cancelled = false

    init(operation: String) {
        self.operation = operation
    }

    func start() {
        cancelled = false
        if operation == "transcribe" {
            startClipboardHistory(maxItems: 3)
            startClipboardItems(maxItems: 1)
            return
        }

        delayedSnapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled, !self.cancelled else { return }
            self.ensureSelectionCaptureStarted()
        }
    }

    func cancel() {
        cancelled = true
        delayedSnapshotTask?.cancel()
        delayedSnapshotTask = nil
        snapshotFuture?.cancel()
        snapshotFuture = nil
        clipboardHistoryTask?.cancel()
        clipboardHistoryTask = nil
        clipboardItemsTask?.cancel()
        clipboardItemsTask = nil
    }

    func resolve(snapshotTimeoutSeconds: TimeInterval, clipboardTimeoutSeconds: TimeInterval) async -> RealtimeContextResult {
        guard !cancelled else { return .empty }

        if operation != "transcribe" {
            ensureSelectionCaptureStarted()
        }

        let snapshot = await resolveSnapshot(timeoutSeconds: snapshotTimeoutSeconds)
        if let snapshot {
            _ = SelectedTextRestorer.restore(snapshot)
        }

        async let history = resolveClipboardHistory(timeoutSeconds: clipboardTimeoutSeconds)
        async let items = resolveClipboardItems(timeoutSeconds: clipboardTimeoutSeconds)
        let resolvedHistory = await history
        let resolvedItems = await items
        DebugTrace.log(
            "RealtimeASR context resolved clipboard historyCount=\(resolvedHistory.count) itemCount=\(resolvedItems.count)"
        )

        return RealtimeContextResult(
            selectedText: snapshot?.text,
            snapshot: snapshot,
            clipboardHistory: resolvedHistory,
            clipboardItems: resolvedItems
        )
    }

    private func ensureSelectionCaptureStarted() {
        guard !cancelled, operation != "transcribe", snapshotFuture == nil else { return }
        delayedSnapshotTask?.cancel()
        delayedSnapshotTask = nil

        let future = SnapshotFuture()
        snapshotFuture = future
        future.start()
        startClipboardHistory(maxItems: 5)
        startClipboardItems(maxItems: 1)
    }

    private func startClipboardHistory(maxItems: Int) {
        guard clipboardHistoryTask == nil else { return }
        clipboardHistoryTask = Task(priority: .utility) {
            await ClipboardHistoryReader.readTextOnlyAsync(maxItems: maxItems)
        }
    }

    private func startClipboardItems(maxItems: Int) {
        guard clipboardItemsTask == nil else { return }
        clipboardItemsTask = Task(priority: .utility) {
            await ClipboardHistoryReader.readItemsNonBlocking(maxItems: maxItems)
        }
    }

    private func resolveSnapshot(timeoutSeconds: TimeInterval) async -> SelectionSnapshot? {
        guard let future = snapshotFuture else { return nil }
        if let snapshot = await future.resolvedValue {
            return snapshot
        }

        return await withTaskGroup(
            of: RealtimeWaitResult<SelectionSnapshot?>.self,
            returning: SelectionSnapshot?.self
        ) { group in
            group.addTask {
                .value(await future.result())
            }
            group.addTask {
                let nanoseconds = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return .timedOut
            }

            guard let result = await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()

            switch result {
            case .value(let snapshot):
                return snapshot
            case .timedOut:
                future.cancel()
                DebugTrace.log("RealtimeASR context snapshot timed out after \(timeoutSeconds)s")
                return nil
            }
        }
    }

    private func resolveClipboardHistory(timeoutSeconds: TimeInterval) async -> [String] {
        guard let task = clipboardHistoryTask else { return [] }
        return await withTaskGroup(of: RealtimeWaitResult<[String]>.self, returning: [String].self) { group in
            group.addTask {
                .value(await task.value)
            }
            group.addTask {
                let nanoseconds = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return .timedOut
            }

            guard let result = await group.next() else {
                group.cancelAll()
                return []
            }
            group.cancelAll()

            switch result {
            case .value(let history):
                return history
            case .timedOut:
                task.cancel()
                DebugTrace.log("RealtimeASR context clipboard history timed out after \(timeoutSeconds)s")
                return []
            }
        }
    }

    private func resolveClipboardItems(timeoutSeconds: TimeInterval) async -> [ClipboardContextItem] {
        guard let task = clipboardItemsTask else { return [] }
        return await withTaskGroup(
            of: RealtimeWaitResult<[ClipboardContextItem]>.self,
            returning: [ClipboardContextItem].self
        ) { group in
            group.addTask {
                .value(await task.value)
            }
            group.addTask {
                let nanoseconds = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return .timedOut
            }

            guard let result = await group.next() else {
                group.cancelAll()
                return []
            }
            group.cancelAll()

            switch result {
            case .value(let items):
                return items
            case .timedOut:
                task.cancel()
                DebugTrace.log("RealtimeASR context clipboard items timed out after \(timeoutSeconds)s")
                return []
            }
        }
    }
}

@MainActor
private final class RealtimeRecordingSession {
    let id = UUID()
    let operation: String
    let targetPid: pid_t?
    let client: RealtimeASRWebSocketClient
    let context: RealtimeContextCapture
    var connectTask: Task<Void, Never>?
    var acceptingPreview = false
    var websocketReadyOnce = false
    var transcriptLanguage = ""
    var websocketErrorCount = 0
    var receivedFinal = false
    var receivedFinalBeforeStop = false
    var audioChunkCount = 0
    var capturedAudioBytes = 0
    var capturedAudio: [Data] = []
    var lastAudioStatsLogAt = Date.distantPast
    var lastPreviewLogAt = Date.distantPast
    var lastPreviewTextLength = 0

    init(operation: String, targetPid: pid_t?, client: RealtimeASRWebSocketClient) {
        self.operation = operation
        self.targetPid = targetPid
        self.client = client
        self.context = RealtimeContextCapture(operation: operation)
    }
}

@MainActor
final class RealtimeRecordingWorkflow {
    private weak var actionHandler: AppHotKeyHandler?
    private let recorder = AudioRecorder.shared
    private let streamer = RealtimeAudioStreamer.shared
    private let historyStore = HistoryStore.shared
    private var phase: RealtimeWorkflowPhase = .idle
    private var session: RealtimeRecordingSession?
    private var pendingAudio: [Data] = []
    private var pendingAudioBytes = 0
    private var processingRecordId: String?
    private var cancelledRecordIds: Set<String> = []
    private let audioBufferLimitBytes = 2_500_000
    private let snapshotStopWaitSeconds: TimeInterval = 0.65
    private let clipboardStopWaitSeconds: TimeInterval = 0.9
    private let finalWaitSeconds: TimeInterval = 1.8
    private let processTimeoutSeconds: TimeInterval = 75
    private let audioFallbackTimeoutSeconds: TimeInterval = 90
    private let capturedAudioLimitBytes = 20_000_000

    init(actionHandler: AppHotKeyHandler) {
        self.actionHandler = actionHandler
    }

    func handle(_ combo: HotKeyCombo) {
        DebugTrace.log(
            "RealtimeASR handle combo=\(combo.rawValue) phase=\(phase.debugName) streamer=\(streamer.state) recorder=\(recorder.state)"
        )
        guard recorder.state == .idle else {
            DebugTrace.log("RealtimeASR handle ignored: recorderState=\(recorder.state)")
            return
        }

        switch phase {
        case .idle:
            guard streamer.state == .idle else {
                DebugTrace.log("RealtimeASR idle phase but streamer=\(streamer.state), resetting UI")
                resetIdleUI()
                return
            }
            guard AuthStore.shared.isLoggedIn else {
                DebugTrace.log("RealtimeASR handle ignored: not logged in")
                return
            }
            guard PermissionManager.shared.refreshAccessibilityStatus(reason: "realtime hotkey \(combo.rawValue)") else {
                DebugTrace.log("RealtimeASR handle ignored: accessibility not granted after refresh")
                return
            }
            Task { await start(operation: combo.rawValue) }
        case .starting:
            DebugTrace.log("RealtimeASR handle during starting: cancel streaming")
            cancelStreaming()
        case .streaming:
            DebugTrace.log("RealtimeASR handle during streaming: stop and process")
            Task { await stopAndProcess() }
        case .stopping:
            DebugTrace.log("RealtimeASR handle ignored: stopping")
            break
        case .processing:
            DebugTrace.log("RealtimeASR handle ignored: processing")
            break
        }
    }

    func cancelStreaming() {
        switch phase {
        case .idle, .starting, .streaming, .stopping:
            DebugTrace.log("RealtimeASR cancelStreaming phase=\(phase.debugName)")
            session?.connectTask?.cancel()
            session?.client.disconnect()
            session?.context.cancel()
            session = nil
            clearAudioBuffer()
            streamer.cancel()
            FillVerifier.shared.detach()
            RealtimeRecordingOverlayWindowController.shared.hide()
            phase = .idle
        case .processing:
            break
        }
    }

    func cancelProcessing() {
        switch phase {
        case .stopping:
            DebugTrace.log("RealtimeASR cancelProcessing while stopping")
            session?.connectTask?.cancel()
            session?.client.disconnect()
            session?.context.cancel()
            session = nil
            clearAudioBuffer()
            FillVerifier.shared.detach()
            RealtimeRecordingOverlayWindowController.shared.hide()
            streamer.resetToIdle()
            phase = .idle
        case .processing:
            DebugTrace.log("RealtimeASR cancelProcessing recordId=\(processingRecordId ?? "nil")")
            if let processingRecordId {
                cancelledRecordIds.insert(processingRecordId)
                historyStore.update(id: processingRecordId, status: .failed, error: L10n.errorUserCancelled)
            }
            self.processingRecordId = nil
            session?.connectTask?.cancel()
            session?.client.disconnect()
            session?.context.cancel()
            session = nil
            clearAudioBuffer()
            FillVerifier.shared.detach()
            RealtimeRecordingOverlayWindowController.shared.hide()
            streamer.resetToIdle()
            phase = .idle
        case .idle, .starting, .streaming:
            break
        }
    }

    private func start(operation: String) async {
        guard case .idle = phase else { return }

        let pm = PermissionManager.shared
        let startID = UUID()
        phase = .starting(startID)
        DebugTrace.log("RealtimeASR start requested id=\(shortID(startID)) op=\(operation)")
        if pm.microphoneStatus != .granted {
            DebugTrace.log("RealtimeASR requesting microphone permission")
            await pm.requestMicrophone()
            pm.refreshStatuses()
            guard pm.microphoneStatus == .granted else {
                DebugTrace.log("RealtimeASR start aborted: microphone not granted")
                phase = .idle
                return
            }
        }
        guard pm.refreshAccessibilityStatus(reason: "realtime start") else {
            DebugTrace.log("RealtimeASR start aborted: accessibility not granted after refresh")
            phase = .idle
            return
        }
        guard phase == .starting(startID) else { return }

        let targetPid = FocusedInputFiller.captureTargetApp()
        // 挂载填充确认观察者（兼做 Chromium/Electron AX 树预热，录音期间零成本完成）
        if let targetPid {
            FillVerifier.shared.attach(pid: targetPid)
        }
        guard streamer.prepareStartingVisualState() else {
            DebugTrace.log("RealtimeASR start failed: streamer could not enter starting state")
            phase = .idle
            return
        }
        RealtimeRecordingOverlayWindowController.shared.show()

        let client = RealtimeASRWebSocketClient()
        let newSession = RealtimeRecordingSession(operation: operation, targetPid: targetPid, client: client)
        session = newSession
        phase = .starting(newSession.id)
        DebugTrace.log(
            "RealtimeASR session created id=\(shortID(newSession.id)) asrSession=\(shortASRID(client.asrSessionID)) targetPid=\(targetPid.map { "\($0)" } ?? "nil")"
        )
        clearAudioBuffer()
        await AudioRecorder.shared.releaseWarmEngineForRealtimeStart()
        guard currentSession(id: newSession.id, client: client) != nil,
              phase == .starting(newSession.id) else { return }
        startConnecting(newSession)

        let success = await streamer.startStreaming(
            onChunk: { [weak client] data in
                guard let client else { return }
                Task { @MainActor [weak self, data] in
                    self?.handleAudioChunk(data, for: client)
                }
            },
            onMaxDuration: { [weak self] in
                Task { @MainActor in await self?.stopAndProcess() }
            }
        )

        guard currentSession(id: newSession.id, client: client) != nil else {
            DebugTrace.log("RealtimeASR start result ignored: stale session id=\(shortID(newSession.id)) success=\(success)")
            if success { streamer.cancel() }
            return
        }

        guard success else {
            DebugTrace.log("RealtimeASR streamer start failed id=\(shortID(newSession.id))")
            cleanupStartFailure(newSession)
            return
        }

        phase = .streaming(newSession.id)
        newSession.acceptingPreview = client.isReady
        newSession.context.start()
        flushBufferedAudio(to: client)
        DebugTrace.log(
            "RealtimeASR streaming started id=\(shortID(newSession.id)) clientReady=\(client.isReady)"
        )
    }

    private func startConnecting(_ activeSession: RealtimeRecordingSession) {
        let client = activeSession.client
        let sessionID = activeSession.id
        activeSession.connectTask = Task { @MainActor [weak self, weak client] in
            guard let self, let client else { return }
            do {
                DebugTrace.log("RealtimeASR connect task begin id=\(self.shortID(sessionID))")
                try await client.connect(language: LanguageManager.shared.current.rawValue) { [weak self, weak client] event in
                    guard let self, let client else { return }
                    self.handleEvent(event, client: client, sessionID: sessionID)
                }

                guard let session = self.currentSession(id: sessionID, client: client),
                      self.phase == .streaming(sessionID) else { return }
                session.acceptingPreview = true
                self.flushBufferedAudio(to: client)
                DebugTrace.log("RealtimeASR connect task ready id=\(self.shortID(sessionID))")
            } catch {
                guard self.currentSession(id: sessionID, client: client) != nil else { return }
                DebugTrace.log("RealtimeASR connect failed: \(error.localizedDescription)")
                if let session = self.currentSession(id: sessionID, client: client) {
                    session.websocketErrorCount += 1
                    session.acceptingPreview = false
                }
            }
        }
    }

    private func stopAndProcess() async {
        guard case .streaming(let sessionID) = phase,
              let activeSession = currentSession(id: sessionID) else { return }

        phase = .stopping(sessionID)
        activeSession.acceptingPreview = false
        DebugTrace.log(
            "RealtimeASR stop begin id=\(shortID(sessionID)) liveLen=\(trimmed(streamer.liveText).count) capturedBytes=\(activeSession.capturedAudioBytes)"
        )
        await streamer.stopForProcessing()
        DebugTrace.log("RealtimeASR streamer stopped for processing id=\(shortID(sessionID))")

        let liveBeforeFinish = trimmed(streamer.liveText)
        let contextTask = Task { @MainActor [activeSession] in
            await activeSession.context.resolve(
                snapshotTimeoutSeconds: self.snapshotStopWaitSeconds,
                clipboardTimeoutSeconds: self.clipboardStopWaitSeconds
            )
        }

        do {
            let final = await resolveFinalTranscript(for: activeSession, liveBeforeFinish: liveBeforeFinish)
            let context = await contextTask.value

            guard phase == .stopping(sessionID),
                  currentSession(id: sessionID, client: activeSession.client) != nil else { return }

            let transcript = chooseTranscript(
                final: final.text,
                liveFallback: liveBeforeFinish.isEmpty ? trimmed(streamer.liveText) : liveBeforeFinish
            )
            let fallbackReason = audioFallbackReason(
                final: final,
                activeSession: activeSession
            )
            let fallbackAudioURL = makeAudioFallbackFileIfNeeded(
                reason: fallbackReason,
                activeSession: activeSession,
                sessionID: sessionID
            )
            guard !transcript.isEmpty || final.asrSessionID != nil || fallbackAudioURL != nil else {
                throw URLError(.cannotDecodeContentData)
            }

            activeSession.connectTask?.cancel()
            activeSession.client.disconnect()
            activeSession.context.cancel()
            session = nil
            clearAudioBuffer()

            var record = RecordingHistory(
                operation: activeSession.operation,
                audioFilePath: nil,
                selectedText: context.selectedText
            )
            record.status = .processing
            historyStore.add(record)
            let recordId = record.id
            processingRecordId = recordId
            phase = .processing(sessionID)

            await processRealtimeRecord(
                id: recordId,
                operation: activeSession.operation,
                transcript: transcript,
                asrSessionID: final.asrSessionID,
                clientASRText: transcript,
                transcriptLanguage: final.language,
                selectedText: context.selectedText,
                snapshot: context.snapshot,
                clipboardHistory: context.clipboardHistory,
                clipboardItems: context.clipboardItems,
                targetPid: activeSession.targetPid,
                fallbackAudioFileURL: fallbackAudioURL,
                fallbackReason: fallbackReason
            )
        } catch {
            contextTask.cancel()
            guard phase == .stopping(sessionID) else { return }
            DebugTrace.log("RealtimeASR stop failed: \(error.localizedDescription)")
            activeSession.connectTask?.cancel()
            activeSession.client.disconnect()
            activeSession.context.cancel()
            session = nil
            clearAudioBuffer()
            actionHandler?.showRealtimeWorkflowWarning(apiErrorMessage(error))
            RealtimeRecordingOverlayWindowController.shared.hide()
            streamer.resetToIdle()
            phase = .idle
        }
    }

    private func handleEvent(_ event: RealtimeASREvent, client: RealtimeASRWebSocketClient, sessionID: UUID) {
        guard let activeSession = currentSession(id: sessionID, client: client) else { return }

        switch event {
        case .ready:
            DebugTrace.log("RealtimeASR event ready id=\(shortID(sessionID))")
            activeSession.websocketReadyOnce = true
            if phase == .streaming(sessionID) {
                activeSession.acceptingPreview = true
                flushBufferedAudio(to: client)
            }
        case .partial(let text, _, _, let language):
            guard shouldAcceptPreview(activeSession, sessionID: sessionID) else { return }
            activeSession.transcriptLanguage = language
            streamer.updateLiveText(text)
            logPreviewEvent(kind: "partial", textLen: text.count, language: language, sessionID: sessionID)
        case .completed(let text, let language):
            guard shouldAcceptPreview(activeSession, sessionID: sessionID) else { return }
            activeSession.transcriptLanguage = language
            streamer.updateLiveText(text)
            logPreviewEvent(kind: "completed", textLen: text.count, language: language, sessionID: sessionID)
        case .finished(let final):
            let wasStreaming = phase == .streaming(sessionID)
            activeSession.receivedFinal = true
            activeSession.receivedFinalBeforeStop = wasStreaming
            activeSession.transcriptLanguage = final.language
            if shouldAcceptPreview(activeSession, sessionID: sessionID), !final.text.isEmpty {
                streamer.updateLiveText(final.text)
            }
            if wasStreaming {
                activeSession.acceptingPreview = false
                DebugTrace.log(
                    "RealtimeASR event finished before stop id=\(shortID(sessionID)) finalLen=\(final.text.count)"
                )
            } else {
                DebugTrace.log(
                    "RealtimeASR event finished id=\(shortID(sessionID)) finalLen=\(final.text.count)"
                )
            }
            if let remaining = final.creditsRemaining {
                AuthStore.shared.creditsRemaining = remaining
            }
        case .error(let message):
            activeSession.websocketErrorCount += 1
            activeSession.acceptingPreview = false
            DebugTrace.log("RealtimeASR websocket error: \(message)")
        }
    }

    private func handleAudioChunk(_ data: Data, for client: RealtimeASRWebSocketClient) {
        guard let activeSession = session, activeSession.client === client else { return }
        guard phase == .starting(activeSession.id) || phase == .streaming(activeSession.id) else { return }

        captureAudioChunk(data, activeSession: activeSession)
        logAudioStatsIfNeeded(activeSession)

        if client.isReady {
            flushBufferedAudio(to: client)
            if !client.enqueueAudio(data) {
                bufferAudio(data)
            }
            return
        }
        bufferAudio(data)
    }

    private func resolveFinalTranscript(
        for activeSession: RealtimeRecordingSession,
        liveBeforeFinish: String
    ) async -> RealtimeFinalResolution {
        let client = activeSession.client
        let readyTimeout: TimeInterval = liveBeforeFinish.isEmpty ? 1.2 : 0.45
        let isReady = await waitForReady(client, timeoutSeconds: readyTimeout)
        var finalText = ""
        var finalLanguage: String?
        var sessionIDForProcess = activeSession.websocketReadyOnce || activeSession.receivedFinal ? client.asrSessionID : nil
        var didSendFinishSignal = false
        var clientFinalIssue: String?

        if isReady {
            activeSession.websocketReadyOnce = true
            sessionIDForProcess = client.asrSessionID
            flushBufferedAudio(to: client)
            do {
                DebugTrace.log(
                    "RealtimeASR finish request begin id=\(shortID(activeSession.id)) liveLen=\(liveBeforeFinish.count)"
                )
                try await client.requestFinish(timeoutSeconds: 2)
                didSendFinishSignal = true
                if let final = try await client.waitForFinalResult(timeoutSeconds: finalWaitSeconds) {
                    finalText = final.text
                    finalLanguage = final.language
                    if let remaining = final.creditsRemaining {
                        AuthStore.shared.creditsRemaining = remaining
                    }
                    DebugTrace.log(
                        "RealtimeASR final received id=\(shortID(activeSession.id)) finalLen=\(final.text.count) language=\(final.language)"
                    )
                } else {
                    clientFinalIssue = "client_final_wait_timeout"
                    DebugTrace.log(
                        "RealtimeASR client final wait timed out id=\(shortID(activeSession.id)); v2 will resolve server final asrSession=\(shortASRID(client.asrSessionID))"
                    )
                }
            } catch {
                clientFinalIssue = "finish_signal_error"
                DebugTrace.log(
                    "RealtimeASR finish request/final wait skipped: \(error.localizedDescription); asrSession=\(sessionIDForProcess.map { shortASRID($0) } ?? "nil")"
                )
            }
        } else {
            activeSession.connectTask?.cancel()
            clearAudioBuffer()
            clientFinalIssue = "websocket_not_ready"
            DebugTrace.log("RealtimeASR stop using audio fallback if possible because websocket was not ready")
        }

        let liveAfterFinish = trimmed(streamer.liveText)
        let resolvedText = chooseTranscript(
            final: finalText.isEmpty ? liveAfterFinish : finalText,
            liveFallback: liveBeforeFinish
        )
        let resolvedLanguage = finalLanguage ?? activeSession.transcriptLanguage
        return RealtimeFinalResolution(
            text: resolvedText,
            language: resolvedLanguage.isEmpty ? nil : resolvedLanguage,
            asrSessionID: sessionIDForProcess,
            didSendFinishSignal: didSendFinishSignal,
            clientFinalIssue: clientFinalIssue
        )
    }

    private func processRealtimeRecord(
        id: String,
        operation: String,
        transcript: String,
        asrSessionID: String?,
        clientASRText: String?,
        transcriptLanguage: String?,
        selectedText: String?,
        snapshot: SelectionSnapshot?,
        clipboardHistory: [String],
        clipboardItems: [ClipboardContextItem],
        targetPid: pid_t?,
        fallbackAudioFileURL: URL?,
        fallbackReason: String?
    ) async {
        historyStore.markProcessingStarted(id: id)
        defer {
            if let fallbackAudioFileURL {
                try? FileManager.default.removeItem(at: fallbackAudioFileURL)
            }
            finishProcessing(id: id)
        }
        do {
            let fastMode = operation == "transcribe" && TranscribeFastModeStore.isEnabled
            let response: AudioProcessResponse
            if let fallbackAudioFileURL {
                DebugTrace.log(
                    "processRealtimeRecord: audio fallback start id=\(id) op=\(operation) reason=\(fallbackReason ?? "unknown") transcriptChars=\(transcript.count) bytes=\(fileSize(fallbackAudioFileURL)) fast=\(fastMode)"
                )
                response = try await processRealtimeAudioFallbackWithTimeout(
                    fileURL: fallbackAudioFileURL,
                    operation: operation,
                    selectedText: selectedText,
                    clipboardHistory: clipboardHistory,
                    clipboardItems: clipboardItems,
                    fastMode: fastMode
                )
            } else {
                DebugTrace.log(
                    "processRealtimeRecord: v2 text start id=\(id) op=\(operation) chars=\(transcript.count) asrSession=\(asrSessionID.map { shortASRID($0) } ?? "nil") fast=\(fastMode)"
                )
                response = try await processRealtimeTextWithTimeout(
                    text: transcript,
                    clientASRText: clientASRText,
                    asrSessionID: asrSessionID,
                    operation: operation,
                    selectedText: selectedText,
                    clipboardHistory: clipboardHistory,
                    clipboardItems: clipboardItems,
                    fastMode: fastMode,
                    transcriptLanguage: transcriptLanguage
                )
            }
            let asrSource = response.asrResolutionSource ?? (fallbackAudioFileURL == nil ? "nil" : "audio_fallback")
            DebugTrace.log(
                "processRealtimeRecord: process success id=\(id) action=\(response.actionType.rawValue) transcriptLen=\(response.transcript.count) resultLen=\(response.result.count) asrSource=\(asrSource)"
            )

            if cancelledRecordIds.remove(id) != nil {
                processingRecordId = nil
                return
            }

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
            RecordingResultStore.shared.update(transcript: response.transcript, result: resultToStore, error: nil)
            finishProcessing(id: id)
            actionHandler?.handleRealtimeWorkflowAction(
                response.actionType,
                text: response.result,
                operation: operation,
                selectedText: selectedText,
                clipboardItems: clipboardItems,
                snapshot: snapshot,
                targetPid: targetPid,
                clarifyQuestion: response.clarifyQuestion,
                recordId: id
            )

            if let remaining = response.creditsRemaining {
                AuthStore.shared.creditsRemaining = remaining
            }
            Task { await AppDelegate.fetchUserPlanInfo() }
            if let warning = response.warning {
                actionHandler?.showRealtimeWorkflowWarning(warning)
            }
        } catch {
            DebugTrace.log("processRealtimeRecord: process failed id=\(id) error=\(error.localizedDescription)")
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
                if apiError?.isNonRetryable == true {
                    actionHandler?.showRealtimeWorkflowWarning(msg)
                }
            }
        }
    }

    private func processRealtimeTextWithTimeout(
        text: String,
        clientASRText: String?,
        asrSessionID: String?,
        operation: String,
        selectedText: String?,
        clipboardHistory: [String],
        clipboardItems: [ClipboardContextItem],
        fastMode: Bool,
        transcriptLanguage: String?
    ) async throws -> AudioProcessResponse {
        let timeoutSeconds = processTimeoutSeconds
        return try await withThrowingTaskGroup(of: AudioProcessResponse.self) { group in
            group.addTask {
                if operation == "agent" {
                    let streamedText = RealtimeSearchStreamTextBuffer()
                    let streamID = UUID()
                    return try await APIClient.shared.processRealtimeTextStream(
                        text: text,
                        clientASRText: clientASRText,
                        asrSessionID: asrSessionID,
                        operation: operation,
                        selectedText: selectedText,
                        clipboardHistory: clipboardHistory,
                        clipboardItems: clipboardItems,
                        fastMode: fastMode,
                        transcriptLanguage: transcriptLanguage,
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
                }
                return try await APIClient.shared.processRealtimeText(
                    text: text,
                    clientASRText: clientASRText,
                    asrSessionID: asrSessionID,
                    operation: operation,
                    selectedText: selectedText,
                    clipboardHistory: clipboardHistory,
                    clipboardItems: clipboardItems,
                    fastMode: fastMode,
                    transcriptLanguage: transcriptLanguage
                )
            }
            group.addTask {
                let nanoseconds = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw URLError(.timedOut)
            }

            guard let response = try await group.next() else {
                group.cancelAll()
                throw URLError(.unknown)
            }
            group.cancelAll()
            return response
        }
    }

    private func processRealtimeAudioFallbackWithTimeout(
        fileURL: URL,
        operation: String,
        selectedText: String?,
        clipboardHistory: [String],
        clipboardItems: [ClipboardContextItem],
        fastMode: Bool
    ) async throws -> AudioProcessResponse {
        let timeoutSeconds = audioFallbackTimeoutSeconds
        return try await withThrowingTaskGroup(of: AudioProcessResponse.self) { group in
            group.addTask {
                if operation == "agent" {
                    let streamedText = RealtimeSearchStreamTextBuffer()
                    let streamID = UUID()
                    return try await APIClient.shared.processAudioStream(
                        fileURL: fileURL,
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
                }
                return try await APIClient.shared.processAudio(
                    fileURL: fileURL,
                    operation: operation,
                    selectedText: selectedText,
                    clipboardHistory: clipboardHistory,
                    clipboardItems: clipboardItems,
                    fastMode: fastMode
                )
            }
            group.addTask {
                let nanoseconds = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw URLError(.timedOut)
            }

            guard let response = try await group.next() else {
                group.cancelAll()
                throw URLError(.unknown)
            }
            group.cancelAll()
            return response
        }
    }

    private func audioFallbackReason(
        final: RealtimeFinalResolution,
        activeSession: RealtimeRecordingSession
    ) -> String? {
        if activeSession.receivedFinalBeforeStop {
            return "websocket_finished_before_user_stop"
        }
        if activeSession.websocketErrorCount > 0 {
            return "websocket_error"
        }
        let ws = activeSession.client.debugSnapshot()
        if ws.droppedAudioBytes > 0 {
            return "websocket_dropped_audio"
        }
        if final.asrSessionID == nil {
            return final.clientFinalIssue ?? (final.didSendFinishSignal ? "session_missing_after_finish" : "websocket_not_ready")
        }
        return nil
    }

    private func makeAudioFallbackFileIfNeeded(
        reason: String?,
        activeSession: RealtimeRecordingSession,
        sessionID: UUID
    ) -> URL? {
        guard let reason else { return nil }
        do {
            let url = try writeCapturedPCMAsWAV(activeSession.capturedAudio, sessionID: sessionID)
            DebugTrace.log(
                "RealtimeASR audio fallback prepared id=\(shortID(sessionID)) reason=\(reason) chunks=\(activeSession.audioChunkCount) bytes=\(activeSession.capturedAudioBytes) file=\(url.lastPathComponent)"
            )
            return url
        } catch {
            DebugTrace.log(
                "RealtimeASR audio fallback prepare failed id=\(shortID(sessionID)) reason=\(reason) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private func writeCapturedPCMAsWAV(_ chunks: [Data], sessionID: UUID) throws -> URL {
        let pcmByteCount = chunks.reduce(0) { $0 + $1.count }
        guard pcmByteCount > 0 else { throw URLError(.zeroByteResource) }

        var wav = Data()
        wav.reserveCapacity(44 + pcmByteCount)
        appendASCII("RIFF", to: &wav)
        appendUInt32LE(UInt32(36 + pcmByteCount), to: &wav)
        appendASCII("WAVE", to: &wav)
        appendASCII("fmt ", to: &wav)
        appendUInt32LE(16, to: &wav)
        appendUInt16LE(1, to: &wav)
        appendUInt16LE(1, to: &wav)
        appendUInt32LE(16_000, to: &wav)
        appendUInt32LE(32_000, to: &wav)
        appendUInt16LE(2, to: &wav)
        appendUInt16LE(16, to: &wav)
        appendASCII("data", to: &wav)
        appendUInt32LE(UInt32(pcmByteCount), to: &wav)
        for chunk in chunks {
            wav.append(chunk)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("realtime-asr-\(sessionID.uuidString.lowercased()).wav")
        try wav.write(to: url, options: .atomic)
        return url
    }

    private func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func captureAudioChunk(_ data: Data, activeSession: RealtimeRecordingSession) {
        activeSession.audioChunkCount += 1
        activeSession.capturedAudio.append(data)
        activeSession.capturedAudioBytes += data.count

        var droppedBytes = 0
        while activeSession.capturedAudioBytes > capturedAudioLimitBytes,
              !activeSession.capturedAudio.isEmpty {
            let removed = activeSession.capturedAudio.removeFirst()
            activeSession.capturedAudioBytes -= removed.count
            droppedBytes += removed.count
        }
        if droppedBytes > 0 {
            DebugTrace.log(
                "RealtimeASR captured audio trimmed id=\(shortID(activeSession.id)) droppedBytes=\(droppedBytes) remainingBytes=\(activeSession.capturedAudioBytes)"
            )
        }
    }

    private func logAudioStatsIfNeeded(_ activeSession: RealtimeRecordingSession) {
        let now = Date()
        guard now.timeIntervalSince(activeSession.lastAudioStatsLogAt) >= 1 else { return }
        activeSession.lastAudioStatsLogAt = now
        let ws = activeSession.client.debugSnapshot()
        DebugTrace.log(
            "RealtimeASR audio stats id=\(shortID(activeSession.id)) chunks=\(activeSession.audioChunkCount) capturedBytes=\(activeSession.capturedAudioBytes) pendingBytes=\(pendingAudioBytes) wsReady=\(ws.isReady) wsFinal=\(ws.hasFinalReceived) wsFinish=\(ws.isFinishRequested) wsPending=\(ws.pendingMessages) wsQueuedBytes=\(ws.queuedAudioBytes) wsDroppedBytes=\(ws.droppedAudioBytes) wsInFlight=\(ws.sendInFlight)"
        )
    }

    private func logPreviewEvent(kind: String, textLen: Int, language: String, sessionID: UUID) {
        guard let activeSession = currentSession(id: sessionID) else { return }
        let now = Date()
        let lengthChangedEnough = abs(textLen - activeSession.lastPreviewTextLength) >= 8
        guard lengthChangedEnough || now.timeIntervalSince(activeSession.lastPreviewLogAt) >= 1.5 else { return }
        activeSession.lastPreviewLogAt = now
        activeSession.lastPreviewTextLength = textLen
        DebugTrace.log(
            "RealtimeASR preview \(kind) id=\(shortID(sessionID)) textLen=\(textLen) language=\(language)"
        )
    }

    private func fileSize(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private actor RealtimeSearchStreamTextBuffer {
        private var text = ""

        func append(_ delta: String) -> String {
            text += delta
            return text
        }
    }

    private func finishProcessing(id: String) {
        if processingRecordId == id {
            processingRecordId = nil
        }
        RealtimeRecordingOverlayWindowController.shared.hide()
        streamer.resetToIdle()
        phase = .idle
        restoreSyncAudioPrewarmAfterRealtime()
    }

    private func cleanupStartFailure(_ failedSession: RealtimeRecordingSession) {
        failedSession.connectTask?.cancel()
        failedSession.client.disconnect()
        failedSession.context.cancel()
        if session === failedSession {
            session = nil
        }
        clearAudioBuffer()
        RealtimeRecordingOverlayWindowController.shared.hide()
        streamer.resetToIdle()
        phase = .idle
        restoreSyncAudioPrewarmAfterRealtime()
    }

    private func resetIdleUI() {
        session?.connectTask?.cancel()
        session?.client.disconnect()
        session?.context.cancel()
        session = nil
        clearAudioBuffer()
        RealtimeRecordingOverlayWindowController.shared.hide()
        streamer.resetToIdle()
        phase = .idle
        restoreSyncAudioPrewarmAfterRealtime()
    }

    private func restoreSyncAudioPrewarmAfterRealtime() {
        Task { @MainActor in
            if RealtimeRecognitionStore.isEnabled {
                await RealtimeAudioStreamer.shared.prewarmIfNeeded()
            } else {
                await AudioRecorder.shared.prewarmIfNeeded()
            }
        }
    }

    private func currentSession(id: UUID, client: RealtimeASRWebSocketClient? = nil) -> RealtimeRecordingSession? {
        guard let session, session.id == id else { return nil }
        if let client, session.client !== client { return nil }
        return session
    }

    private func shouldAcceptPreview(_ activeSession: RealtimeRecordingSession, sessionID: UUID) -> Bool {
        activeSession.acceptingPreview && phase == .streaming(sessionID)
    }

    private func waitForReady(_ client: RealtimeASRWebSocketClient, timeoutSeconds: TimeInterval) async -> Bool {
        if client.isReady { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return false }
            if client.isReady { return true }
        }
        return client.isReady
    }

    private func bufferAudio(_ data: Data) {
        while pendingAudioBytes + data.count > audioBufferLimitBytes, !pendingAudio.isEmpty {
            pendingAudioBytes -= pendingAudio.removeFirst().count
        }
        if data.count <= audioBufferLimitBytes {
            pendingAudio.append(data)
            pendingAudioBytes += data.count
        }
    }

    private func flushBufferedAudio(to client: RealtimeASRWebSocketClient) {
        guard client.isReady else { return }
        let chunks = pendingAudio
        pendingAudio.removeAll()
        pendingAudioBytes = 0

        for (index, chunk) in chunks.enumerated() {
            if !client.enqueueAudio(chunk) {
                bufferAudio(chunk)
                for remaining in chunks.dropFirst(index + 1) {
                    bufferAudio(remaining)
                }
                return
            }
        }
    }

    private func clearAudioBuffer() {
        pendingAudio.removeAll()
        pendingAudioBytes = 0
    }

    private func chooseTranscript(final: String, liveFallback: String) -> String {
        let finalText = trimmed(final)
        let fallback = trimmed(liveFallback)
        guard !fallback.isEmpty else { return finalText }
        guard !finalText.isEmpty else { return fallback }
        if fallback.count > finalText.count,
           fallback.hasPrefix(finalText) || fallback.contains(finalText) {
            DebugTrace.log(
                "RealtimeASR final shorter than live fallback finalLen=\(finalText.count) fallbackLen=\(fallback.count)"
            )
            return fallback
        }
        return finalText
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private func shortASRID(_ id: String) -> String {
        String(id.suffix(8))
    }
}

private extension RealtimeWorkflowPhase {
    var debugName: String {
        switch self {
        case .idle:
            return "idle"
        case .starting(let id):
            return "starting:\(String(id.uuidString.prefix(8)).lowercased())"
        case .streaming(let id):
            return "streaming:\(String(id.uuidString.prefix(8)).lowercased())"
        case .stopping(let id):
            return "stopping:\(String(id.uuidString.prefix(8)).lowercased())"
        case .processing(let id):
            return "processing:\(String(id.uuidString.prefix(8)).lowercased())"
        }
    }
}
