import Foundation

enum RealtimeASREvent {
    case ready
    case partial(text: String, confirmedText: String, stash: String, language: String)
    case completed(text: String, language: String)
    case finished(RealtimeASRFinal)
    case error(String)
}

struct RealtimeASRFinal {
    let text: String
    let language: String
    let creditsRemaining: Int?
}

struct RealtimeASRWebSocketDebugSnapshot {
    let isReady: Bool
    let isClosing: Bool
    let isFinishRequested: Bool
    let hasFinalReceived: Bool
    let pendingMessages: Int
    let queuedAudioBytes: Int
    let sendInFlight: Bool
    let droppedAudioMessages: Int
    let droppedAudioBytes: Int
}

final class RealtimeASRWebSocketClient: @unchecked Sendable {
    let asrSessionID: String

    private let session: URLSession
    private let sendQueue = DispatchQueue(label: "ssh2026.voice-input.realtime-asr-send", qos: .userInitiated)
    private let maxQueuedAudioBytes = 4_000_000
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var onEvent: (@MainActor (RealtimeASREvent) -> Void)?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var finalContinuation: CheckedContinuation<RealtimeASRFinal, Error>?
    private let continuationLock = NSLock()
    private var readyState = false
    private var closing = false
    private var finishRequested = false
    private var finalReceived = false
    private var cachedFinal: RealtimeASRFinal?
    private var pendingMessages: [OutgoingMessage] = []
    private var queuedAudioBytes = 0
    private var sendInFlight = false
    private var inFlightMessage: OutgoingMessage?
    private var droppedAudioMessages = 0
    private var droppedAudioBytes = 0
    private let debugSnapshotLock = NSLock()
    private var snapshotPendingMessages = 0
    private var snapshotQueuedAudioBytes = 0
    private var snapshotSendInFlight = false
    private var snapshotDroppedAudioMessages = 0
    private var snapshotDroppedAudioBytes = 0

    var isReady: Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return readyState
    }

    init(asrSessionID: String = RealtimeASRWebSocketClient.makeSessionID()) {
        self.asrSessionID = asrSessionID
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    deinit {
        // 每次实时录音都会新建一个 client，实例释放时主动 invalidate session，
        // 及时释放底层 CFNetwork 资源（工作队列/连接池），避免长期运行累积。
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    func connect(
        language: String,
        onEvent: @escaping @MainActor (RealtimeASREvent) -> Void
    ) async throws {
        setReady(false)
        setLifecycle(closing: false, finishRequested: false, finalReceived: false, cachedFinal: nil)
        resetSendQueue()
        self.onEvent = onEvent
        guard var components = URLComponents(string: APIConfig.AudioV2.realtimeASR) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "audio_format", value: "pcm"),
            URLQueryItem(name: "vad", value: "true"),
            URLQueryItem(name: "max_duration_sec", value: "60"),
            URLQueryItem(name: "asr_session_id", value: asrSessionID),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        DebugTrace.log(
            "RealtimeASR ws connect start asrSession=\(shortSessionID) host=\(url.host ?? "nil") path=\(url.path)"
        )
        var request = URLRequest(url: url)
        if let token = AuthStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(APIConfig.appVariant, forHTTPHeaderField: "X-App-Variant")
        request.setValue("macos", forHTTPHeaderField: "X-Client-Platform")
        let languageCode = LanguageManager.shared.current.rawValue
        request.setValue(languageCode, forHTTPHeaderField: "Accept-Language")
        request.setValue(languageCode, forHTTPHeaderField: "X-Accept-Language")
        request.timeoutInterval = 30

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuationLock.lock()
            readyContinuation = continuation
            continuationLock.unlock()

            let wsTask = session.webSocketTask(with: request)
            task = wsTask
            wsTask.resume()
            receiveTask = Task { [weak self] in await self?.receiveLoop() }
        }
        setReady(true)
        DebugTrace.log("RealtimeASR ws connect ready asrSession=\(shortSessionID)")
        pumpSendQueue()
    }

    func enqueueAudio(_ data: Data) -> Bool {
        guard !data.isEmpty, isReady else { return false }
        sendQueue.async { [weak self] in
            guard let self, self.task != nil else { return }
            guard self.isReady, !self.isFinishRequested, !self.isClosing, !self.hasFinalReceived else { return }
            self.enqueueMessageOnSendQueue(OutgoingMessage(payload: .data(data)))
        }
        return true
    }

    func finish(timeoutSeconds: TimeInterval = 12) async throws -> RealtimeASRFinal? {
        try await requestFinish(timeoutSeconds: min(8, timeoutSeconds))
        do {
            return try await waitForFinal(timeoutSeconds: timeoutSeconds)
        } catch {
            if (error as? URLError)?.code == .timedOut {
                return nil
            }
            throw error
        }
    }

    func waitForFinalResult(timeoutSeconds: TimeInterval) async throws -> RealtimeASRFinal? {
        do {
            return try await waitForFinal(timeoutSeconds: timeoutSeconds)
        } catch {
            if (error as? URLError)?.code == .timedOut {
                return nil
            }
            throw error
        }
    }

    func requestFinish(timeoutSeconds: TimeInterval = 8) async throws {
        if cachedFinalResult() != nil { return }
        guard isReady else { throw URLError(.notConnectedToInternet) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async { [weak self] in
                guard let self, self.task != nil else {
                    continuation.resume(throwing: URLError(.notConnectedToInternet))
                    return
                }
                if self.hasFinalReceived {
                    continuation.resume()
                    return
                }
                guard self.isReady, !self.isClosing else {
                    continuation.resume(throwing: URLError(.notConnectedToInternet))
                    return
                }
                self.setFinishRequested(true)
                let message = OutgoingMessage(
                    payload: .text("{\"type\":\"finish\"}")
                )
                self.enqueueMessageOnSendQueue(message)
                DebugTrace.log("RealtimeASR ws finish enqueued asrSession=\(self.shortSessionID)")
                continuation.resume()
            }
        }
    }

    func disconnect() {
        DebugTrace.log("RealtimeASR ws disconnect asrSession=\(shortSessionID)")
        setClosing(true)
        setReady(false)
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failQueuedSends(error: URLError(.cancelled))
        resumeReadyIfNeeded(error: URLError(.cancelled))
        resumeFinalIfNeeded(error: URLError(.cancelled))
    }

    func debugSnapshot() -> RealtimeASRWebSocketDebugSnapshot {
        continuationLock.lock()
        let ready = readyState
        let close = closing
        let finish = finishRequested
        let final = finalReceived
        continuationLock.unlock()

        debugSnapshotLock.lock()
        let pending = snapshotPendingMessages
        let queued = snapshotQueuedAudioBytes
        let inFlight = snapshotSendInFlight
        let droppedMessages = snapshotDroppedAudioMessages
        let droppedBytes = snapshotDroppedAudioBytes
        debugSnapshotLock.unlock()
        return RealtimeASRWebSocketDebugSnapshot(
            isReady: ready,
            isClosing: close,
            isFinishRequested: finish,
            hasFinalReceived: final,
            pendingMessages: pending,
            queuedAudioBytes: queued,
            sendInFlight: inFlight,
            droppedAudioMessages: droppedMessages,
            droppedAudioBytes: droppedBytes
        )
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                setReady(false)
                resumeReadyIfNeeded(error: error)
                resumeFinalIfNeeded(error: error)
                failQueuedSends(error: error)
                if self.isClosing || self.hasFinalReceived {
                    return
                }
                Task { @MainActor in
                    self.onEvent?(.error(error.localizedDescription))
                }
                return
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String else {
            return
        }
        switch type {
        case "ready":
            setReady(true)
            resumeReadyIfNeeded(error: nil)
            pumpSendQueue()
            Task { @MainActor in self.onEvent?(.ready) }
        case "partial":
            let text = payload["text"] as? String ?? ""
            let confirmed = payload["confirmed_text"] as? String ?? ""
            let stash = payload["stash"] as? String ?? ""
            let language = payload["language"] as? String ?? ""
            Task { @MainActor in
                self.onEvent?(.partial(text: text, confirmedText: confirmed, stash: stash, language: language))
            }
        case "completed":
            let text = (payload["text"] as? String) ?? (payload["transcript"] as? String) ?? ""
            let language = payload["language"] as? String ?? ""
            Task { @MainActor in self.onEvent?(.completed(text: text, language: language)) }
        case "finished":
            let text = (payload["text"] as? String) ?? (payload["transcript"] as? String) ?? ""
            let language = payload["language"] as? String ?? ""
            let remaining = payload["credits_remaining"] as? Int
            DebugTrace.log(
                "RealtimeASR ws finished asrSession=\(shortSessionID) textLen=\(text.count) language=\(language)"
            )
            let final = RealtimeASRFinal(text: text, language: language, creditsRemaining: remaining)
            setFinal(final)
            resumeFinalIfNeeded(value: final)
            Task { @MainActor in self.onEvent?(.finished(final)) }
        case "error":
            let message = payload["message"] as? String ?? L10n.errorUnknown
            DebugTrace.log("RealtimeASR ws server error asrSession=\(shortSessionID) message=\(message)")
            setReady(false)
            resumeReadyIfNeeded(error: APIError.httpError(500, message, nil))
            resumeFinalIfNeeded(error: APIError.httpError(500, message, nil))
            failQueuedSends(error: APIError.httpError(500, message, nil))
            Task { @MainActor in self.onEvent?(.error(message)) }
        default:
            break
        }
    }

    private func setReady(_ value: Bool) {
        continuationLock.lock()
        readyState = value
        continuationLock.unlock()
    }

    private var isClosing: Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return closing
    }

    private var isFinishRequested: Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return finishRequested
    }

    private var hasFinalReceived: Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return finalReceived
    }

    private func setClosing(_ value: Bool) {
        continuationLock.lock()
        closing = value
        continuationLock.unlock()
    }

    private func setFinishRequested(_ value: Bool) {
        continuationLock.lock()
        finishRequested = value
        continuationLock.unlock()
    }

    private func setFinalReceived(_ value: Bool) {
        continuationLock.lock()
        finalReceived = value
        continuationLock.unlock()
    }

    private func setFinal(_ final: RealtimeASRFinal) {
        continuationLock.lock()
        finalReceived = true
        readyState = false
        cachedFinal = final
        continuationLock.unlock()
    }

    private func setLifecycle(
        closing: Bool,
        finishRequested: Bool,
        finalReceived: Bool,
        cachedFinal: RealtimeASRFinal?
    ) {
        continuationLock.lock()
        self.closing = closing
        self.finishRequested = finishRequested
        self.finalReceived = finalReceived
        self.cachedFinal = cachedFinal
        continuationLock.unlock()
    }

    private func cachedFinalResult() -> RealtimeASRFinal? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return cachedFinal
    }

    private func resumeReadyIfNeeded(error: Error?) {
        continuationLock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        continuationLock.unlock()
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func resumeFinalIfNeeded(value: RealtimeASRFinal? = nil, error: Error? = nil) {
        continuationLock.lock()
        let continuation = finalContinuation
        finalContinuation = nil
        continuationLock.unlock()
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: value ?? RealtimeASRFinal(text: "", language: "", creditsRemaining: nil))
        }
    }

    private func waitForFinal(timeoutSeconds: TimeInterval) async throws -> RealtimeASRFinal {
        if let final = cachedFinalResult() {
            return final
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RealtimeASRFinal, Error>) in
            continuationLock.lock()
            if let final = cachedFinal {
                continuationLock.unlock()
                continuation.resume(returning: final)
                return
            }
            finalContinuation = continuation
            continuationLock.unlock()

            Task { [weak self] in
                let nanoseconds = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                self?.resumeFinalIfNeeded(error: URLError(.timedOut))
            }
        }
    }

    private func enqueueMessageOnSendQueue(_ message: OutgoingMessage) {
        pendingMessages.append(message)
        queuedAudioBytes += message.audioBytes
        trimAudioQueueIfNeeded()
        publishDebugSnapshotOnSendQueue()
        pumpSendQueueOnSendQueue()
    }

    private func pumpSendQueue() {
        sendQueue.async { [weak self] in
            self?.pumpSendQueueOnSendQueue()
        }
    }

    private func pumpSendQueueOnSendQueue() {
        guard !sendInFlight,
              let task,
              isReady,
              !isClosing,
              !hasFinalReceived,
              !pendingMessages.isEmpty else {
            return
        }
        let message = pendingMessages.removeFirst()
        queuedAudioBytes -= message.audioBytes
        sendInFlight = true
        inFlightMessage = message
        publishDebugSnapshotOnSendQueue()

        task.send(message.webSocketMessage) { [weak self, weak message] error in
            self?.sendQueue.async {
                guard let self else { return }
                self.sendInFlight = false
                self.inFlightMessage = nil
                self.publishDebugSnapshotOnSendQueue()
                if let error {
                    message?.complete(error: error)
                    self.handleSendFailureOnSendQueue(error)
                    return
                }
                message?.complete()
                self.pumpSendQueueOnSendQueue()
            }
        }
    }

    private func handleSendFailureOnSendQueue(_ error: Error) {
        setReady(false)
        failQueuedSendsOnSendQueue(error: error)
        resumeReadyIfNeeded(error: error)
        resumeFinalIfNeeded(error: error)
        if !isClosing && !hasFinalReceived {
            Task { @MainActor in
                self.onEvent?(.error(error.localizedDescription))
            }
        }
    }

    private func trimAudioQueueIfNeeded() {
        var droppedBytes = 0
        var droppedMessages = 0
        while queuedAudioBytes > maxQueuedAudioBytes,
              let index = pendingMessages.firstIndex(where: { $0.audioBytes > 0 }) {
            droppedBytes += pendingMessages[index].audioBytes
            droppedMessages += 1
            queuedAudioBytes -= pendingMessages[index].audioBytes
            pendingMessages.remove(at: index)
        }
        if droppedMessages > 0 {
            droppedAudioMessages += droppedMessages
            droppedAudioBytes += droppedBytes
            publishDebugSnapshotOnSendQueue()
            DebugTrace.log(
                "RealtimeASR ws dropped queued audio asrSession=\(shortSessionID) chunks=\(droppedMessages) bytes=\(droppedBytes)"
            )
        }
    }

    private func resetSendQueue() {
        sendQueue.sync {
            failQueuedSendsOnSendQueue(error: URLError(.cancelled))
        }
    }

    private func failQueuedSends(error: Error) {
        sendQueue.async { [weak self] in
            self?.failQueuedSendsOnSendQueue(error: error)
        }
    }

    private func failQueuedSendsOnSendQueue(error: Error) {
        inFlightMessage?.complete(error: error)
        inFlightMessage = nil
        for message in pendingMessages {
            message.complete(error: error)
        }
        pendingMessages.removeAll()
        queuedAudioBytes = 0
        sendInFlight = false
        droppedAudioMessages = 0
        droppedAudioBytes = 0
        publishDebugSnapshotOnSendQueue()
    }

    private func publishDebugSnapshotOnSendQueue() {
        debugSnapshotLock.lock()
        snapshotPendingMessages = pendingMessages.count
        snapshotQueuedAudioBytes = queuedAudioBytes
        snapshotSendInFlight = sendInFlight
        snapshotDroppedAudioMessages = droppedAudioMessages
        snapshotDroppedAudioBytes = droppedAudioBytes
        debugSnapshotLock.unlock()
    }

    private static func makeSessionID() -> String {
        "mac_\(UUID().uuidString.lowercased())"
    }

    private var shortSessionID: String {
        String(asrSessionID.suffix(8))
    }
}

private final class OutgoingMessage: @unchecked Sendable {
    enum Payload {
        case data(Data)
        case text(String)
    }

    let payload: Payload
    private let continuationLock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<Void, Error>?

    init(payload: Payload, continuation: CheckedContinuation<Void, Error>? = nil) {
        self.payload = payload
        self.continuation = continuation
    }

    var audioBytes: Int {
        if case .data(let data) = payload {
            return data.count
        }
        return 0
    }

    var webSocketMessage: URLSessionWebSocketTask.Message {
        switch payload {
        case .data(let data):
            return .data(data)
        case .text(let text):
            return .string(text)
        }
    }

    nonisolated func complete(error: Error? = nil) {
        continuationLock.lock()
        let continuation = continuation
        self.continuation = nil
        continuationLock.unlock()
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
