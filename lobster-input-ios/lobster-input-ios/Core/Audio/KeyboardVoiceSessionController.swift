import AVFoundation
import Combine
import Foundation
import UIKit
import os.log

private let keyboardVoiceLog = Logger(subsystem: "ssh2026.lobster-input-ios", category: "KeyboardVoiceSession")
private let realtimeAudioBufferLimitBytes = 2_500_000

final class KeyboardVoiceAudioWriter {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var fileURL: URL?

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return file != nil
    }

    func begin(format: AVAudioFormat) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        file = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyboard-\(UUID().uuidString).wav")
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        fileURL = url
        return url
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let targetFile = file
        lock.unlock()

        guard let targetFile else { return }
        do {
            try targetFile.write(from: buffer)
        } catch {
            keyboardVoiceLog.error("Keyboard voice file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finish() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        file = nil
        fileURL = nil
        return url
    }

    func cancel() {
        let url = finish()
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

final class KeyboardVoiceAudioTapState {
    private let lock = NSLock()
    private var lastHeartbeat: TimeInterval = 0
    private var lastLevel: TimeInterval = 0

    func handle(buffer: AVAudioPCMBuffer, writer: KeyboardVoiceAudioWriter, realtimePipe: KeyboardRealtimeAudioPipe) {
        let now = Date().timeIntervalSince1970
        var shouldHeartbeat = false
        var shouldLevel = false

        lock.lock()
        if now - lastHeartbeat >= 0.5 {
            lastHeartbeat = now
            shouldHeartbeat = true
        }
        if now - lastLevel >= 1.0 / 24.0 {
            lastLevel = now
            shouldLevel = true
        }
        lock.unlock()

        if shouldHeartbeat {
            KeyboardVoiceSessionBridge.writeHeartbeat(now)
        }
        let isAudioActive = writer.isRecording || realtimePipe.isActive
        if shouldLevel, isAudioActive {
            KeyboardVoiceSessionBridge.writeAudioLevel(Self.normalizedLevel(from: buffer))
        }

        writer.append(buffer)
        realtimePipe.append(buffer)
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let samples = channelData[0]
        let step = max(1, count / 256)
        var sum: Float = 0
        var sampleCount = 0
        var index = 0
        while index < count {
            let sample = samples[index]
            sum += sample * sample
            sampleCount += 1
            index += step
        }
        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sum / Float(sampleCount))
        return min(1, max(0, rms * 12))
    }
}

final class KeyboardRealtimeAudioPipe {
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var active = false
    private var converter: AVAudioConverter?
    private var sourceSignature = ""
    private var onChunk: ((Data) -> Void)?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func begin(onChunk: @escaping (Data) -> Void) {
        lock.lock()
        active = true
        converter = nil
        sourceSignature = ""
        self.onChunk = onChunk
        lock.unlock()
    }

    func stop() {
        lock.lock()
        active = false
        converter = nil
        sourceSignature = ""
        onChunk = nil
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        let signature = "\(buffer.format.sampleRate)-\(buffer.format.channelCount)-\(buffer.format.commonFormat.rawValue)-\(buffer.format.isInterleaved)"
        if converter == nil || sourceSignature != signature {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            sourceSignature = signature
        }
        guard let converter, let data = Self.convert(buffer, converter: converter, targetFormat: targetFormat) else {
            lock.unlock()
            return
        }
        let callback = onChunk
        lock.unlock()
        callback?(data)
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> Data? {
        let ratio = targetFormat.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData, converted.frameLength > 0 else { return nil }
        let audioBuffer = converted.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }
}

@MainActor
final class KeyboardVoiceSessionController: ObservableObject {
    static let shared = KeyboardVoiceSessionController()

    @Published private(set) var isSessionActive = false
    @Published private(set) var isKeyboardRecording = false
    @Published private(set) var lastError: String?

    var isEnabled: Bool {
        KeyboardVoiceSessionBridge.isEnabled
    }

    private let audioEngine = AVAudioEngine()
    private let audioWriter = KeyboardVoiceAudioWriter()
    private let tapState = KeyboardVoiceAudioTapState()
    private let realtimePipe = KeyboardRealtimeAudioPipe()
    private var commandObserver: KeyboardDarwinNotificationObserver?
    private var interruptionObserver: NSObjectProtocol?
    private var lastCommandID: String?
    private var activeRequest: KeyboardRecordingRequest?
    private var activeRealtimeClient: RealtimeASRWebSocketClient?
    private var activeRealtimeConnectTask: Task<Void, Error>?
    private let realtimeAudioBufferLock = NSLock()
    private var realtimePendingAudio: [Data] = []
    private var realtimePendingAudioBytes = 0
    private var realtimeConnectError: String?
    private var activeRealtimeTranscript = ""
    private var activeRealtimeTranscriptLanguage: String?
    private var maxDurationTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var configured = false

    private init() {}

    func configure() {
        guard !configured else { return }
        configured = true
        if UserDefaults(suiteName: APIConfig.appGroupID)?.object(forKey: "ios_keyboard_voice_session_enabled") == nil {
            KeyboardVoiceSessionBridge.setEnabled(true)
        }
        commandObserver = KeyboardVoiceSessionBridge.observe(KeyboardVoiceSessionBridge.NotificationName.commandPosted) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleLatestCommand()
            }
        }
        setupInterruptionObserver()
        Task { @MainActor in
            await startIfEnabled()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        KeyboardVoiceSessionBridge.setEnabled(enabled)
        lastError = nil
        if enabled {
            await startIfEnabled()
        } else {
            stopSession()
        }
    }

    func startIfEnabled() async {
        guard KeyboardVoiceSessionBridge.isEnabled else { return }
        do {
            try await startSession()
        } catch {
            lastError = error.localizedDescription
            KeyboardRecordingBridge.saveDiagnostic(
                error: "Keyboard voice session failed: \(error.localizedDescription)",
                hasFullAccess: true,
                recordPermission: String(describing: AVAudioApplication.shared.recordPermission)
            )
        }
    }

    private func startSession() async throws {
        if isSessionActive {
            if !audioEngine.isRunning {
                try audioEngine.start()
                keyboardVoiceLog.info("Keyboard voice session engine restarted")
            }
            KeyboardVoiceSessionBridge.writeHeartbeat()
            return
        }

        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else { throw NSError(domain: "KeyboardVoiceSession", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.errorMicPermission]) }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [audioWriter, tapState, realtimePipe] buffer, _ in
            tapState.handle(buffer: buffer, writer: audioWriter, realtimePipe: realtimePipe)
        }
        audioEngine.prepare()
        try audioEngine.start()

        isSessionActive = true
        lastError = nil
        KeyboardVoiceSessionBridge.markSessionActive(true)
        startHeartbeatTimer()
        beginBackgroundKeepAlive()
        keyboardVoiceLog.info("Keyboard voice session started")
    }

    func processPendingCommandIfNeeded() {
        handleLatestCommand()
    }

    private func stopSession() {
        stopHeartbeatTimer()
        endBackgroundKeepAlive()
        maxDurationTask?.cancel()
        maxDurationTask = nil
        activeRequest = nil
        audioWriter.cancel()
        realtimePipe.stop()
        activeRealtimeConnectTask?.cancel()
        activeRealtimeConnectTask = nil
        clearRealtimeAudioBuffer()
        activeRealtimeClient?.disconnect()
        activeRealtimeClient = nil
        resetActiveRealtimeTranscript()

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        isKeyboardRecording = false
        isSessionActive = false
        KeyboardVoiceSessionBridge.updateRecording(false)
        KeyboardVoiceSessionBridge.updateLiveText("")
        KeyboardVoiceSessionBridge.markSessionActive(false)
        keyboardVoiceLog.info("Keyboard voice session stopped")
    }

    private func handleLatestCommand() {
        guard let command = KeyboardVoiceSessionBridge.latestCommand() else { return }
        guard command.id != lastCommandID else { return }
        lastCommandID = command.id

        switch command.action {
        case .start:
            Task { @MainActor in await beginKeyboardRecording(command: command) }
        case .stop:
            Task { @MainActor in await finishKeyboardRecording(command: command) }
        case .cancel:
            cancelKeyboardRecording()
        }
    }

    private func beginKeyboardRecording(command: KeyboardVoiceSessionCommand) async {
        guard let request = KeyboardRecordingBridge.currentRequest() else {
            keyboardVoiceLog.error("Keyboard recording missing request for command \(command.requestID, privacy: .public)")
            return
        }
        guard request.id == command.requestID else {
            keyboardVoiceLog.error(
                "Keyboard recording request mismatch command=\(command.requestID, privacy: .public) request=\(request.id, privacy: .public)"
            )
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: MobileStrings.recordingStartFailed()
            )
            return
        }

        do {
            try await startSession()
        } catch {
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: error.localizedDescription
            )
            return
        }

        if AuthStore.shared.creditsTotal > 0 && AuthStore.shared.creditsRemaining <= 0 {
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: L10n.errorCreditsExhausted
            )
            return
        }

        if request.realtimeMode {
            await beginRealtimeKeyboardRecording(request: request)
            return
        }

        do {
            _ = try audioWriter.begin(format: audioEngine.inputNode.outputFormat(forBus: 0))
            activeRequest = request
            isKeyboardRecording = true
            KeyboardVoiceSessionBridge.updateRecording(true)
            scheduleMaxDurationStop(for: request)
            keyboardVoiceLog.info("Keyboard voice recording started \(request.id, privacy: .public)")
        } catch {
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: error.localizedDescription
            )
        }
    }

    /// 链路层错误(URLError/POSIX,如 "Software caused connection abort")的原始英文文案
    /// 不可直接展示给用户,统一映射为本地化网络提示;APIError 保留自身本地化描述。
    private func realtimeErrorDisplayMessage(_ error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? L10n.errorUnknown
        }
        let nsError = error as NSError
        if error is URLError
            || nsError.domain == NSURLErrorDomain
            || nsError.domain == NSPOSIXErrorDomain {
            return L10n.errorNetwork
        }
        return error.localizedDescription
    }

    private func beginRealtimeKeyboardRecording(request: KeyboardRecordingRequest) async {
        let client = RealtimeASRWebSocketClient()
        resetActiveRealtimeTranscript()
        KeyboardVoiceSessionBridge.updateLiveText("")
        clearRealtimeAudioBuffer()
        realtimeConnectError = nil
        activeRealtimeClient = client
        activeRealtimeConnectTask = Task { [weak self, weak client] in
            guard let self, let client else { return }
            do {
                try await client.connect(language: MobileStrings.language.rawValue) { [weak self, weak client] event in
                    guard let self, let client else { return }
                    self.handleRealtimeASREvent(event, client: client)
                }
                self.flushBufferedRealtimeAudio(client)
            } catch {
                let display = self.realtimeErrorDisplayMessage(error)
                self.realtimeConnectError = display
                if self.activeRealtimeClient === client && self.isKeyboardRecording {
                    self.failActiveRealtimeConnection(client, message: display)
                }
                throw error
            }
        }
        realtimePipe.begin { [weak self, weak client] data in
            guard let client else { return }
            self?.handleRealtimeAudioChunk(data, client: client)
        }
        activeRequest = request
        isKeyboardRecording = true
        KeyboardVoiceSessionBridge.updateRecording(true)
        scheduleMaxDurationStop(for: request)
        keyboardVoiceLog.info("Keyboard realtime voice recording started \(request.id, privacy: .public) session=\(client.asrSessionID, privacy: .public)")
    }

    private func handleRealtimeASREvent(_ event: RealtimeASREvent, client: RealtimeASRWebSocketClient? = nil) {
        if let client {
            guard let activeRealtimeClient, activeRealtimeClient === client else { return }
        }
        switch event {
        case .ready:
            break
        case .partial(let text, let language), .completed(let text, let language):
            guard isKeyboardRecording else { return }
            updateActiveRealtimeTranscript(text, language: language)
        case .finished(let final):
            updateActiveRealtimeTranscript(final.text, language: final.language)
            if let remaining = final.creditsRemaining {
                AuthStore.shared.creditsRemaining = remaining
            }
        case .error(let message):
            keyboardVoiceLog.error("Keyboard realtime ASR error: \(message, privacy: .public)")
        }
    }

    private func handleRealtimeAudioChunk(_ data: Data, client: RealtimeASRWebSocketClient) {
        guard activeRealtimeClient === client else { return }
        if client.isReady {
            flushBufferedRealtimeAudio(client)
            if !client.enqueueAudio(data) {
                bufferRealtimeAudio(data)
            }
            return
        }
        bufferRealtimeAudio(data)
    }

    private func bufferRealtimeAudio(_ data: Data) {
        realtimeAudioBufferLock.lock()
        while realtimePendingAudioBytes + data.count > realtimeAudioBufferLimitBytes,
              !realtimePendingAudio.isEmpty {
            realtimePendingAudioBytes -= realtimePendingAudio.removeFirst().count
        }
        if data.count <= realtimeAudioBufferLimitBytes {
            realtimePendingAudio.append(data)
            realtimePendingAudioBytes += data.count
        }
        realtimeAudioBufferLock.unlock()
    }

    private func flushBufferedRealtimeAudio(_ client: RealtimeASRWebSocketClient) {
        guard client.isReady else { return }
        realtimeAudioBufferLock.lock()
        let chunks = realtimePendingAudio
        realtimePendingAudio.removeAll()
        realtimePendingAudioBytes = 0
        realtimeAudioBufferLock.unlock()

        for (index, chunk) in chunks.enumerated() {
            if !client.enqueueAudio(chunk) {
                bufferRealtimeAudio(chunk)
                for remaining in chunks.dropFirst(index + 1) {
                    bufferRealtimeAudio(remaining)
                }
                return
            }
        }
    }

    private func clearRealtimeAudioBuffer() {
        realtimeAudioBufferLock.lock()
        realtimePendingAudio.removeAll()
        realtimePendingAudioBytes = 0
        realtimeAudioBufferLock.unlock()
    }

    private func failActiveRealtimeConnection(_ client: RealtimeASRWebSocketClient, message: String) {
        guard activeRealtimeClient === client else { return }
        let request = activeRequest
        activeRequest = nil
        isKeyboardRecording = false
        activeRealtimeConnectTask = nil
        activeRealtimeClient = nil
        realtimePipe.stop()
        clearRealtimeAudioBuffer()
        client.disconnect()
        resetActiveRealtimeTranscript()
        KeyboardVoiceSessionBridge.updateRecording(false)
        KeyboardVoiceSessionBridge.updateLiveText("")
        if let request {
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: message
            )
        }
    }

    private func finishKeyboardRecording(command: KeyboardVoiceSessionCommand?) async {
        guard let request = activeRequest else { return }
        if let command, command.requestID != request.id { return }
        await finishAndProcess(request: request)
    }

    private func finishAndProcess(request: KeyboardRecordingRequest) async {
        if request.realtimeMode {
            await finishRealtimeAndProcess(request: request)
            return
        }

        maxDurationTask?.cancel()
        maxDurationTask = nil
        activeRequest = nil
        isKeyboardRecording = false
        KeyboardVoiceSessionBridge.updateRecording(false)

        guard let audioURL = audioWriter.finish() else {
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: MobileStrings.recordingStartFailed()
            )
            return
        }

        let historyStore = HistoryStore.shared
        let persistedPath = historyStore.persistAudio(from: audioURL)
        var record = RecordingHistory(
            operation: request.operation.rawValue,
            audioFilePath: persistedPath,
            selectedText: request.selectedText
        )
        record.status = .processing
        historyStore.add(record)
        try? FileManager.default.removeItem(at: audioURL)

        do {
            guard let path = persistedPath else { throw APIError.networkError(URLError(.fileDoesNotExist)) }
            let response = try await APIClient.shared.processAudio(
                fileURL: URL(fileURLWithPath: path),
                operation: request.operation.rawValue,
                selectedText: request.selectedText,
                clipboardHistory: request.context,
                fastMode: request.fastMode
            )

            historyStore.update(
                id: record.id,
                status: .success,
                transcript: response.transcript,
                result: response.result,
                actionType: response.actionType.rawValue
            )
            RecordingResultStore.shared.update(transcript: response.transcript, result: response.result, error: nil)
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: response.transcript,
                result: response.result,
                actionType: response.actionType.rawValue,
                error: nil
            )

            if let remaining = response.creditsRemaining {
                AuthStore.shared.creditsRemaining = remaining
            }
            if let update = response.configUpdate, let newMax = update.maxDurationSec {
                AudioRecorder.shared.maxDuration = TimeInterval(newMax)
            }
        } catch {
            let apiError = error as? APIError
            if case .unauthorized = apiError {
                AuthStore.shared.logout()
            }
            let message = apiError?.errorDescription ?? error.localizedDescription
            historyStore.update(id: record.id, status: .failed, error: message)
            RecordingResultStore.shared.update(transcript: "", result: "", error: message)
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: message
            )
        }
    }

    private func finishRealtimeAndProcess(request: KeyboardRecordingRequest) async {
        maxDurationTask?.cancel()
        maxDurationTask = nil
        activeRequest = nil
        isKeyboardRecording = false
        KeyboardVoiceSessionBridge.updateRecording(false)
        realtimePipe.stop()

        let snapshot = KeyboardVoiceSessionBridge.snapshot()
        let cachedText = activeRealtimeTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let bridgedText = snapshot.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientText = cachedText.isEmpty ? bridgedText : cachedText
        let transcriptLanguage = activeRealtimeTranscriptLanguage ?? snapshot.transcriptLanguage
        let client = activeRealtimeClient
        let connectTask = activeRealtimeConnectTask
        activeRealtimeClient = nil
        activeRealtimeConnectTask = nil

        if let client {
            do {
                try await connectTask?.value
                flushBufferedRealtimeAudio(client)
                try await client.requestFinish()
            } catch {
                let message = realtimeConnectError ?? realtimeErrorDisplayMessage(error)
                keyboardVoiceLog.error("Keyboard realtime ASR finish signal failed: \(message, privacy: .public)")
                FileLog.e("VoiceRT", "ws finish failed: \(message) clientTextLen=\(clientText.count)")
                client.disconnect()
                // BUG修复:WS finish 失败但屏幕上已有识别文本时,不再直接报错丢弃——
                // 降级为纯文本通道照常投递 LLM 加工(与安卓端一致),只有确无文本才报错返回。
                if clientText.isEmpty {
                    clearRealtimeAudioBuffer()
                    resetActiveRealtimeTranscript()
                    KeyboardVoiceSessionBridge.updateLiveText("")
                    KeyboardRecordingBridge.complete(
                        request: request,
                        transcript: "",
                        result: "",
                        actionType: nil,
                        error: message
                    )
                    return
                }
            }
        }

        let historyStore = HistoryStore.shared
        var record = RecordingHistory(
            operation: request.operation.rawValue,
            audioFilePath: nil,
            selectedText: request.selectedText
        )
        record.status = .processing
        historyStore.add(record)

        do {
            FileLog.i("VoiceRT", "processRealtimeText call: fastMode=\(request.fastMode) len=\(clientText.count) session=\(client?.asrSessionID ?? "nil")")
            let response = try await APIClient.shared.processRealtimeText(
                text: clientText,
                clientASRText: clientText,
                asrSessionID: client?.asrSessionID ?? "ios_\(request.id.lowercased())",
                operation: request.operation.rawValue,
                selectedText: request.selectedText,
                clipboardHistory: contextList(from: request.context),
                fastMode: request.fastMode,
                transcriptLanguage: transcriptLanguage
            )
            FileLog.i("VoiceRT", "processRealtimeText ok: action=\(response.actionType.rawValue) resultLen=\(response.result.count)")

            historyStore.update(
                id: record.id,
                status: .success,
                transcript: response.transcript,
                result: response.result,
                actionType: response.actionType.rawValue
            )
            RecordingResultStore.shared.update(transcript: response.transcript, result: response.result, error: nil)
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: response.transcript,
                result: response.result,
                actionType: response.actionType.rawValue,
                error: nil
            )

            if let remaining = response.creditsRemaining {
                AuthStore.shared.creditsRemaining = remaining
            }
            if let update = response.configUpdate, let newMax = update.maxDurationSec {
                AudioRecorder.shared.maxDuration = TimeInterval(newMax)
            }
        } catch {
            let apiError = error as? APIError
            if case .unauthorized = apiError {
                AuthStore.shared.logout()
            }
            let message = realtimeErrorDisplayMessage(error)
            FileLog.e("VoiceRT", "processRealtimeText failed: \(message)")
            historyStore.update(id: record.id, status: .failed, error: message)
            RecordingResultStore.shared.update(transcript: "", result: "", error: message)
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: message
            )
        }
        client?.disconnect()
        clearRealtimeAudioBuffer()
        resetActiveRealtimeTranscript()
        KeyboardVoiceSessionBridge.updateLiveText("")
    }

    private func cancelKeyboardRecording() {
        FileLog.w("VoiceRT", "cancelKeyboardRecording: session dropped without LLM processing")
        maxDurationTask?.cancel()
        maxDurationTask = nil
        activeRequest = nil
        audioWriter.cancel()
        realtimePipe.stop()
        activeRealtimeConnectTask?.cancel()
        activeRealtimeConnectTask = nil
        clearRealtimeAudioBuffer()
        activeRealtimeClient?.disconnect()
        activeRealtimeClient = nil
        resetActiveRealtimeTranscript()
        isKeyboardRecording = false
        KeyboardVoiceSessionBridge.updateRecording(false)
        KeyboardVoiceSessionBridge.updateLiveText("")
    }

    private func scheduleMaxDurationStop(for request: KeyboardRecordingRequest) {
        maxDurationTask?.cancel()
        let maxDuration = max(5, AudioRecorder.shared.maxDuration)
        maxDurationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(maxDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.activeRequest?.id == request.id else { return }
            await self.finishAndProcess(request: request)
        }
    }

    private func contextList(from raw: String?) -> [String]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }
        return [raw]
    }

    private func updateActiveRealtimeTranscript(_ text: String, language: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeRealtimeTranscript = trimmed
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeRealtimeTranscriptLanguage = language
        }
        KeyboardVoiceSessionBridge.updateLiveText(trimmed, language: activeRealtimeTranscriptLanguage)
    }

    private func resetActiveRealtimeTranscript() {
        activeRealtimeTranscript = ""
        activeRealtimeTranscriptLanguage = nil
    }

    private func startHeartbeatTimer() {
        stopHeartbeatTimer()
        KeyboardVoiceSessionBridge.writeHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            KeyboardVoiceSessionBridge.writeHeartbeat()
        }
    }

    private func stopHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func beginBackgroundKeepAlive() {
        endBackgroundKeepAlive()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "KeyboardVoiceSession") { [weak self] in
            self?.endBackgroundKeepAlive()
        }
    }

    private func endBackgroundKeepAlive() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func setupInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let type = value.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
            Task { @MainActor [weak self] in
                switch type {
                case .began:
                    self?.cancelKeyboardRecording()
                case .ended:
                    await self?.startIfEnabled()
                @unknown default:
                    break
                }
            }
        }
    }
}
