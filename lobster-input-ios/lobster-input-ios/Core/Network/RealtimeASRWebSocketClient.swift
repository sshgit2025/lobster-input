import Foundation

enum RealtimeASREvent {
    case ready
    case partial(text: String, language: String)
    case completed(text: String, language: String)
    case finished(RealtimeASRFinal)
    case error(String)
}

struct RealtimeASRFinal {
    let text: String
    let language: String
    let creditsRemaining: Int?
}

final class RealtimeASRWebSocketClient: @unchecked Sendable {
    let asrSessionID: String

    private let session: URLSession
    private let sendQueue = DispatchQueue(label: "ssh2026.lobster-input-ios.realtime-asr-send", qos: .userInitiated)
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

    var isReady: Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return readyState
    }

    init(asrSessionID: String = RealtimeASRWebSocketClient.makeSessionID()) {
        self.asrSessionID = asrSessionID
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    func connect(
        language: String,
        onEvent: @escaping @MainActor (RealtimeASREvent) -> Void
    ) async throws {
        setReady(false)
        setLifecycle(closing: false, finishRequested: false, finalReceived: false)
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
        guard let token = AuthStore.shared.token else { throw APIError.notLoggedIn }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(APIConfig.clientPlatform, forHTTPHeaderField: "X-Client-Platform")
        request.setValue(MobileStrings.language.rawValue, forHTTPHeaderField: "Accept-Language")
        request.setValue(MobileStrings.language.rawValue, forHTTPHeaderField: "X-Accept-Language")

        let wsTask = session.webSocketTask(with: request)
        task = wsTask
        wsTask.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuationLock.lock()
            readyContinuation = continuation
            continuationLock.unlock()
        }
        setReady(true)
    }

    func enqueueAudio(_ data: Data) -> Bool {
        guard isReady else { return false }
        sendQueue.async { [weak self] in
            guard let self, let task = self.task else { return }
            guard self.isReady, !self.isFinishRequested, !self.isClosing, !self.hasFinalReceived else { return }
            task.send(.data(data)) { error in
                if let error {
                    Task { @MainActor in
                        self.onEvent?(.error(error.localizedDescription))
                    }
                }
            }
        }
        return true
    }

    func finish() async throws -> RealtimeASRFinal {
        try await requestFinish()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RealtimeASRFinal, Error>) in
            continuationLock.lock()
            finalContinuation = continuation
            continuationLock.unlock()
        }
    }

    func requestFinish() async throws {
        guard isReady else { throw URLError(.notConnectedToInternet) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async { [weak self] in
                guard let self, let task = self.task else {
                    continuation.resume(throwing: URLError(.notConnectedToInternet))
                    return
                }
                guard self.isReady, !self.isClosing, !self.hasFinalReceived else {
                    continuation.resume(throwing: URLError(.notConnectedToInternet))
                    return
                }
                self.setFinishRequested(true)
                task.send(.string("{\"type\":\"finish\"}")) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func disconnect() {
        setClosing(true)
        setReady(false)
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        resumeReadyIfNeeded(error: URLError(.cancelled))
        resumeFinalIfNeeded(error: URLError(.cancelled))
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
            Task { @MainActor in self.onEvent?(.ready) }
        case "partial":
            let text = payload["text"] as? String ?? ""
            let language = payload["language"] as? String ?? ""
            Task { @MainActor in self.onEvent?(.partial(text: text, language: language)) }
        case "completed":
            let text = messageText(from: payload)
            let language = payload["language"] as? String ?? ""
            Task { @MainActor in self.onEvent?(.completed(text: text, language: language)) }
        case "finished":
            setFinalReceived(true)
            setReady(false)
            let text = messageText(from: payload)
            let language = payload["language"] as? String ?? ""
            let final = RealtimeASRFinal(
                text: text,
                language: language,
                creditsRemaining: payload["credits_remaining"] as? Int
            )
            resumeFinalIfNeeded(value: final)
            Task { @MainActor in self.onEvent?(.finished(final)) }
        case "error":
            let message = payload["message"] as? String ?? "Realtime ASR error"
            setReady(false)
            resumeReadyIfNeeded(error: APIError.httpError(500, message, nil))
            resumeFinalIfNeeded(error: APIError.httpError(500, message, nil))
            Task { @MainActor in self.onEvent?(.error(message)) }
        default:
            break
        }
    }

    private func messageText(from payload: [String: Any]) -> String {
        let text = payload["text"] as? String ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return payload["transcript"] as? String ?? ""
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

    private func setLifecycle(closing: Bool, finishRequested: Bool, finalReceived: Bool) {
        continuationLock.lock()
        self.closing = closing
        self.finishRequested = finishRequested
        self.finalReceived = finalReceived
        continuationLock.unlock()
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

    private static func makeSessionID() -> String {
        "ios_\(UUID().uuidString.lowercased())"
    }
}
