/// OpenClawGatewayClient.swift
/// OpenClaw Gateway RPC 客户端。
///
/// OpenClaw 2026.5.27 的会话执行过程需要通过 Gateway WebSocket 订阅事件：
///   connect -> sessions.messages.subscribe -> sessions.subscribe -> sessions.send
/// CLI 的 `openclaw gateway call sessions.send` 只是一次 RPC 调用，不能持续接收
/// `agent` / `chat` / `session.message` / `sessions.changed` 实时事件。
import Foundation

// MARK: - Gateway Agent Event

enum GatewayAgentEvent {
    case started(runId: String?, messageSeq: Int?)
    case text(chunk: String, accumulated: String)
    case done(String)
    case error(String)
}

private struct OpenClawTranscript {
    let messages: [OpenClawTranscriptMessage]
}

private struct OpenClawTranscriptMessage {
    let role: String
    let text: String
    let seq: Int?
    let stopReason: String?
}

// MARK: - OpenClawGatewayClient

@MainActor
final class OpenClawGatewayClient: NSObject {

    static let shared = OpenClawGatewayClient()
    private override init() { super.init() }

    // MARK: - Public API

    func sendMessage(
        message: String,
        attachments: [[String: Any]] = [],
        binaryPath: String,
        sessionKey: String,
        onEvent: @escaping (GatewayAgentEvent) -> Void
    ) async throws {
        let baselineSeq = (try? await sessionMaxSeq(binaryPath: binaryPath, sessionKey: sessionKey)) ?? 0
        let credential = try Self.readGatewayCredential()
        let connection = OpenClawGatewayWebSocketConnection(
            url: try Self.gatewayWebSocketURL(),
            credential: credential,
            sessionKey: sessionKey,
            baselineSeq: baselineSeq,
            onEvent: onEvent
        )
        let finalText = try await connection.run(message: message, attachments: attachments)
        onEvent(.done(finalText))
    }

    func abortActiveSession(binaryPath: String, sessionKey: String, runId: String? = nil) async throws -> String {
        if let message = try? await abortActiveSessionViaWebSocket(sessionKey: sessionKey, runId: runId) {
            return message
        }
        var params: [String: Any] = ["key": sessionKey]
        if let runId, !runId.isEmpty {
            params["runId"] = runId
        }
        let output = try await runOpenClaw(
            binaryPath: binaryPath,
            arguments: [
                "gateway", "call", "sessions.abort",
                "--timeout", "10000",
                "--json",
                "--params", try jsonString(params),
            ],
            timeout: 15
        )
        return Self.extractAbortText(from: output)
    }

    func deleteSession(binaryPath: String, sessionKey: String) async throws {
        let params = try jsonString(["key": sessionKey, "deleteTranscript": true])
        _ = try await runOpenClaw(
            binaryPath: binaryPath,
            arguments: [
                "gateway", "call", "sessions.delete",
                "--timeout", "10000",
                "--json",
                "--params", params,
            ],
            timeout: 15
        )
    }

    private func abortActiveSessionViaWebSocket(sessionKey: String, runId: String? = nil) async throws -> String {
        let credential = try Self.readGatewayCredential()
        let connection = OpenClawGatewayWebSocketConnection(
            url: try Self.gatewayWebSocketURL(),
            credential: credential,
            sessionKey: sessionKey,
            baselineSeq: 0,
            onEvent: { _ in }
        )
        return try await connection.abort(runId: runId)
    }

    // MARK: - Session polling

    private func sessionMaxSeq(binaryPath: String, sessionKey: String) async throws -> Int {
        let transcript = try await fetchSessionTranscript(binaryPath: binaryPath, sessionKey: sessionKey)
        return transcript.messages.compactMap(\.seq).max() ?? 0
    }

    private func fetchSessionTranscript(binaryPath: String, sessionKey: String) async throws -> OpenClawTranscript {
        let params = try jsonString(["key": sessionKey])
        let output = try await runOpenClaw(
            binaryPath: binaryPath,
            arguments: [
                "gateway", "call", "sessions.get",
                "--timeout", "10000",
                "--json",
                "--params", params,
            ],
            timeout: 15
        )
        return Self.parseTranscript(from: output)
    }

    // MARK: - Process

    private func runOpenClaw(
        binaryPath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            proc.arguments = arguments
            proc.environment = Self.openClawProcessEnvironment(binaryPath: binaryPath)

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            var didResume = false
            @Sendable func finish(_ result: Result<String, Error>) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            proc.terminationHandler = { process in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    finish(.success(out))
                } else {
                    finish(.failure(GatewayError.commandFailed(Int(process.terminationStatus), err.isEmpty ? out : err)))
                }
            }

            do {
                try proc.run()
            } catch {
                finish(.failure(error))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning {
                    proc.terminate()
                    finish(.failure(GatewayError.timeout))
                }
            }
        }
    }

    private static func openClawProcessEnvironment(binaryPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binaryDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let commonPaths = [binaryDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let merged = (commonPaths + existingPath.split(separator: ":").map(String.init))
            .filter { path in
                guard !path.isEmpty, !seen.contains(path) else { return false }
                seen.insert(path)
                return true
            }
            .joined(separator: ":")
        env["PATH"] = merged
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["TMPDIR"] = env["TMPDIR"] ?? NSTemporaryDirectory()
        env["USER"] = env["USER"] ?? NSUserName()
        env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
        return env
    }

    private func jsonString(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func gatewayWebSocketURL() throws -> URL {
        guard let url = URL(string: APIConfig.OpenClaw.gatewayWS) else {
            throw GatewayError.invalidGatewayURL
        }
        return url
    }

    private static func readGatewayCredential() throws -> OpenClawGatewayCredential {
        let cfgPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
        guard let data = try? Data(contentsOf: cfgPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gw = json["gateway"] as? [String: Any],
              let auth = gw["auth"] as? [String: Any] else {
            throw GatewayError.missingCredential
        }

        let mode = auth["mode"] as? String ?? "token"
        if mode == "password", let password = auth["password"] as? String, !password.isEmpty {
            return OpenClawGatewayCredential(mode: "password", value: password)
        }
        if let token = auth["token"] as? String, !token.isEmpty {
            return OpenClawGatewayCredential(mode: "token", value: token)
        }
        throw GatewayError.missingCredential
    }

    // MARK: - Response Formatting

    private static func extractStartedRun(from output: String) -> (runId: String?, messageSeq: Int?) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        return (
            json["runId"] as? String,
            json["messageSeq"] as? Int
        )
    }

    private static func parseTranscript(from output: String) -> OpenClawTranscript {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["messages"] as? [[String: Any]] else {
            return OpenClawTranscript(messages: [])
        }
        let messages = rows.map { row in
            let meta = row["__openclaw"] as? [String: Any]
            return OpenClawTranscriptMessage(
                role: row["role"] as? String ?? "message",
                text: extractMessageText(from: row["content"] ?? row["text"] ?? ""),
                seq: meta?["seq"] as? Int,
                stopReason: row["stopReason"] as? String
            )
        }
        return OpenClawTranscript(messages: messages)
    }

    fileprivate static func extractMessageText(from value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let blocks = value as? [[String: Any]] {
            let pieces = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if let content = block["content"] as? String { return content }
                if let type = block["type"] as? String {
                    if let name = block["name"] as? String {
                        return "[\(type)] \(name)"
                    }
                    return "[\(type)]"
                }
                return nil
            }
            return pieces.joined(separator: "\n")
        }
        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String { return text }
            if let content = dict["content"] as? String { return content }
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return ""
    }

    private static func renderTranscript(_ messages: [OpenClawTranscriptMessage]) -> String {
        messages
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { message in
                let title: String
                switch message.role {
                case "user": title = "用户指令"
                case "assistant": title = "OpenClaw"
                case "tool": title = "工具"
                default: title = message.role
                }
                return "### \(title)\n\n\(message.text)"
            }
            .joined(separator: "\n\n---\n\n")
    }

    private static func extractAbortText(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return trimmed.isEmpty ? "OpenClaw 中断请求已发送" : trimmed
        }
        let aborted = json["aborted"] as? Bool
        let status = json["status"] as? String
        if aborted == true || status == "aborted" {
            return "已中断 OpenClaw 当前任务"
        }
        if status == "no-active-run" {
            return "OpenClaw 当前没有正在运行的任务"
        }
        return "OpenClaw 中断请求已发送"
    }

    fileprivate static func extractAbortText(fromJSONObject json: [String: Any]) -> String {
        let aborted = json["aborted"] as? Bool
        let status = json["status"] as? String
        if aborted == true || status == "aborted" {
            return "已中断 OpenClaw 当前任务"
        }
        if status == "no-active-run" {
            return "OpenClaw 当前没有正在运行的任务"
        }
        return "OpenClaw 中断请求已发送"
    }
}

// MARK: - Errors

enum GatewayError: LocalizedError {
    case commandFailed(Int, String)
    case timeout
    case invalidGatewayURL
    case missingCredential
    case websocketDisconnected
    case gatewayRejected(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let msg): return "OpenClaw 命令失败 \(code): \(msg)"
        case .timeout: return "OpenClaw 请求超时"
        case .invalidGatewayURL: return "OpenClaw Gateway WebSocket 地址无效"
        case .missingCredential: return "未找到 OpenClaw Gateway 本地认证凭证"
        case .websocketDisconnected: return "OpenClaw Gateway WebSocket 连接已断开"
        case .gatewayRejected(let msg): return "OpenClaw Gateway 拒绝请求：\(msg)"
        }
    }
}

// MARK: - WebSocket Gateway Protocol

private struct OpenClawGatewayCredential {
    let mode: String
    let value: String

    var authPayload: [String: Any] {
        if mode == "password" {
            return ["password": value]
        }
        return ["token": value]
    }
}

@MainActor
private final class OpenClawGatewayWebSocketConnection {
    private let url: URL
    private let credential: OpenClawGatewayCredential
    private let sessionKey: String
    private let baselineSeq: Int
    private let onEvent: (GatewayAgentEvent) -> Void
    private let urlSession = URLSession(configuration: .default)

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pendingResponses: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var challengeContinuation: CheckedContinuation<Void, Error>?
    private var completionContinuation: CheckedContinuation<String, Error>?
    private var completedText: String?
    private var renderer: OpenClawLiveTranscriptRenderer
    private var lastStarted: (runId: String?, messageSeq: Int?)
    private var didComplete = false
    private var didClose = false

    init(
        url: URL,
        credential: OpenClawGatewayCredential,
        sessionKey: String,
        baselineSeq: Int,
        onEvent: @escaping (GatewayAgentEvent) -> Void
    ) {
        self.url = url
        self.credential = credential
        self.sessionKey = sessionKey
        self.baselineSeq = baselineSeq
        self.onEvent = onEvent
        self.renderer = OpenClawLiveTranscriptRenderer(baselineSeq: baselineSeq)
        self.lastStarted = (nil, nil)
    }

    func run(message: String, attachments: [[String: Any]] = []) async throws -> String {
        try await connect()
        defer { close() }

        _ = try await request(method: "sessions.subscribe", params: [:], timeout: 10)
        _ = try await request(method: "sessions.create", params: ["key": sessionKey], timeout: 10)
        _ = try await request(method: "sessions.messages.subscribe", params: ["key": sessionKey], timeout: 10)

        var params: [String: Any] = ["key": sessionKey, "message": message]
        if !attachments.isEmpty {
            params["attachments"] = attachments
        }
        let response = try await request(
            method: "sessions.send",
            params: params,
            timeout: 20
        )
        lastStarted = (
            response["runId"] as? String,
            response["messageSeq"] as? Int
        )
        onEvent(.started(runId: lastStarted.runId, messageSeq: lastStarted.messageSeq))

        return try await waitForCompletion(timeout: 240)
    }

    func abort(runId: String?) async throws -> String {
        try await connect()
        defer { close() }

        var params: [String: Any] = ["key": sessionKey]
        if let runId, !runId.isEmpty {
            params["runId"] = runId
        }
        let response = try await request(method: "sessions.abort", params: params, timeout: 10)
        return OpenClawGatewayClient.extractAbortText(fromJSONObject: response)
    }

    private func connect() async throws {
        task = urlSession.webSocketTask(with: url)
        task?.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        try await waitForChallenge(timeout: 10)
        _ = try await request(method: "connect", params: connectParams(), id: "connect-1", timeout: 10)
    }

    private func connectParams() -> [String: Any] {
        [
            "minProtocol": 4,
            "maxProtocol": 4,
            "client": [
                "id": "gateway-client",
                "version": "lobster-input",
                "platform": "macos",
                "mode": "backend",
            ],
            "role": "operator",
            "scopes": ["operator.read", "operator.write", "operator.admin"],
            "caps": [],
            "commands": [],
            "permissions": [:],
            "auth": credential.authPayload,
            "locale": Locale.current.identifier,
            "userAgent": "lobster-input/openclaw-gateway",
        ]
    }

    private func waitForChallenge(timeout: TimeInterval) async throws {
        return try await withTimeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { continuation in
                self.challengeContinuation = continuation
            }
        }
    }

    private func request(
        method: String,
        params: [String: Any],
        id: String = UUID().uuidString,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        guard let task else { throw GatewayError.websocketDisconnected }
        return try await withTimeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingResponses[id] = continuation
                do {
                    let payload: [String: Any] = [
                        "type": "req",
                        "id": id,
                        "method": method,
                        "params": params,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                    let text = String(data: data, encoding: .utf8) ?? "{}"
                    task.send(.string(text)) { [weak self] error in
                        guard let error else { return }
                        Task { @MainActor [weak self] in
                            self?.resumePendingResponse(id: id, result: .failure(error))
                        }
                    }
                } catch {
                    self.resumePendingResponse(id: id, result: .failure(error))
                }
            }
        }
    }

    private func waitForCompletion(timeout: TimeInterval) async throws -> String {
        if let completedText {
            return completedText
        }
        return try await withTimeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { continuation in
                if let completedText = self.completedText {
                    continuation.resume(returning: completedText)
                    return
                }
                self.completionContinuation = continuation
            }
        }
    }

    private func receiveLoop() async {
        while !didClose {
            do {
                guard let task else { throw GatewayError.websocketDisconnected }
                let message = try await task.receive()
                try await handle(message: message)
            } catch is CancellationError {
                return
            } catch {
                if !didClose {
                    failAll(error)
                }
                return
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) async throws {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return
        }
        guard let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "res" {
            handleResponse(json)
        } else if type == "event" {
            handleEvent(json)
        }
    }

    private func handleResponse(_ json: [String: Any]) {
        guard let id = json["id"] as? String else { return }
        if (json["ok"] as? Bool) == true {
            let payload = json["payload"] as? [String: Any] ?? [:]
            resumePendingResponse(id: id, result: .success(payload))
        } else {
            let errorPayload = json["error"] as? [String: Any]
            let message = errorPayload?["message"] as? String ?? "未知错误"
            resumePendingResponse(id: id, result: .failure(GatewayError.gatewayRejected(message)))
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? String else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]

        if event == "connect.challenge" {
            challengeContinuation?.resume()
            challengeContinuation = nil
            return
        }

        guard isCurrentSession(payload) else { return }

        switch event {
        case "agent":
            handleAgentEvent(payload)
        case "chat":
            handleChatEvent(payload)
        case "session.message":
            handleSessionMessage(payload)
        case "sessions.changed":
            handleSessionChanged(payload)
        case "session.tool", "session.operation":
            if let rendered = renderer.addOperationalEvent(event: event, payload: payload) {
                onEvent(.text(chunk: "", accumulated: rendered))
            }
        default:
            break
        }
    }

    private func isCurrentSession(_ payload: [String: Any]) -> Bool {
        let expected = "agent:main:\(sessionKey)"
        let payloadKey = payload["sessionKey"] as? String
        if payloadKey == nil { return true }
        return payloadKey == sessionKey || payloadKey == expected
    }

    private func handleAgentEvent(_ payload: [String: Any]) {
        if let runId = payload["runId"] as? String,
           let activeRunId = lastStarted.runId,
           runId != activeRunId {
            return
        }
        guard let stream = payload["stream"] as? String else { return }
        let data = payload["data"] as? [String: Any] ?? [:]

        if stream == "assistant",
           let text = data["text"] as? String,
           !text.isEmpty,
           let rendered = renderer.updateAssistantDelta(text) {
            onEvent(.text(chunk: text, accumulated: rendered))
            return
        }

        if let rendered = renderer.addAgentProgress(stream: stream, data: data) {
            onEvent(.text(chunk: "", accumulated: rendered))
        }
    }

    private func handleChatEvent(_ payload: [String: Any]) {
        if let runId = payload["runId"] as? String,
           let activeRunId = lastStarted.runId,
           runId != activeRunId {
            return
        }
        if let delta = payload["deltaText"] as? String,
           !delta.isEmpty,
           let rendered = renderer.updateAssistantDelta(delta) {
            onEvent(.text(chunk: delta, accumulated: rendered))
        }
        if payload["state"] as? String == "final" {
            completeIfNeeded(renderer.renderFinal())
        }
    }

    private func handleSessionMessage(_ payload: [String: Any]) {
        guard let message = payload["message"] as? [String: Any] else { return }
        let messageSeq = payload["messageSeq"] as? Int
        if let rendered = renderer.addSessionMessage(message, fallbackSeq: messageSeq) {
            onEvent(.text(chunk: "", accumulated: rendered))
        }
    }

    private func handleSessionChanged(_ payload: [String: Any]) {
        let eventRunId = payload["runId"] as? String
        if let eventRunId,
           let activeRunId = lastStarted.runId,
           eventRunId != activeRunId {
            return
        }
        if payload["phase"] as? String == "start" {
            if let rendered = renderer.addProgress("任务开始执行") {
                onEvent(.text(chunk: "", accumulated: rendered))
            }
        }
        if payload["phase"] as? String == "end" {
            completeIfNeeded(renderer.renderFinal())
        }
        if payload["status"] as? String == "aborted",
           eventRunId != nil || lastStarted.runId == nil {
            completeIfNeeded("OpenClaw 当前任务已中断")
        }
    }

    private func completeIfNeeded(_ text: String) {
        guard !didComplete else { return }
        didComplete = true
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = final.isEmpty ? "（OpenClaw 未返回内容）" : final
        completedText = result
        completionContinuation?.resume(returning: result)
        completionContinuation = nil
    }

    private func resumePendingResponse(id: String, result: Result<[String: Any], Error>) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        challengeContinuation?.resume(throwing: error)
        challengeContinuation = nil
        for id in Array(pendingResponses.keys) {
            resumePendingResponse(id: id, result: .failure(error))
        }
        completionContinuation?.resume(throwing: error)
        completionContinuation = nil
    }

    private func close() {
        guard !didClose else { return }
        didClose = true
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAll(GatewayError.websocketDisconnected)
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw GatewayError.timeout
            }
            guard let result = try await group.next() else {
                throw GatewayError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

private struct OpenClawLiveTranscriptRenderer {
    private let baselineSeq: Int
    private var messagesBySeq: [Int: OpenClawTranscriptMessage] = [:]
    private var progressLines: [String] = []
    private var progressSet = Set<String>()
    private var assistantDraft = ""

    init(baselineSeq: Int) {
        self.baselineSeq = baselineSeq
    }

    mutating func addProgress(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !progressSet.contains(clean) else { return nil }
        progressSet.insert(clean)
        progressLines.append(clean)
        return render()
    }

    mutating func addAgentProgress(stream: String, data: [String: Any]) -> String? {
        if stream == "codex_app_server.lifecycle" || stream == "lifecycle" {
            guard let phase = data["phase"] as? String else { return nil }
            switch phase {
            case "startup": return addProgress("正在启动 OpenClaw 执行环境")
            case "thread_ready": return addProgress("会话已就绪")
            case "turn_starting": return addProgress("开始执行用户任务")
            case "start": return addProgress("任务开始执行")
            case "end": return addProgress("任务执行完成")
            default: return addProgress("OpenClaw：\(phase)")
            }
        }

        if stream == "codex_app_server.item" {
            let phase = data["phase"] as? String ?? ""
            let type = data["type"] as? String ?? "item"
            switch (phase, type) {
            case (_, "userMessage"): return nil
            case ("started", "reasoning"): return addProgress("OpenClaw 正在分析任务")
            case ("completed", "reasoning"): return addProgress("OpenClaw 分析完成")
            case ("started", "toolCall"): return addProgress("开始调用工具")
            case ("completed", "toolCall"): return addProgress("工具调用完成")
            case ("started", "commandExecution"): return addProgress("开始执行命令")
            case ("completed", "commandExecution"): return addProgress("命令执行完成")
            case ("started", "agentMessage"): return addProgress("OpenClaw 正在生成回复")
            case ("completed", "agentMessage"): return addProgress("OpenClaw 回复已生成")
            default:
                if !phase.isEmpty {
                    return addProgress("\(readableItemType(type))：\(readablePhase(phase))")
                }
            }
        }
        return nil
    }

    mutating func addOperationalEvent(event: String, payload: [String: Any]) -> String? {
        if event == "session.tool" {
            let name = payload["name"] as? String ?? payload["tool"] as? String ?? "工具"
            return addProgress("工具：\(name)")
        }
        if event == "session.operation" {
            let name = payload["name"] as? String ?? payload["operation"] as? String ?? "操作"
            return addProgress("操作：\(name)")
        }
        return nil
    }

    mutating func updateAssistantDelta(_ text: String) -> String? {
        assistantDraft += text
        return render()
    }

    mutating func addSessionMessage(_ row: [String: Any], fallbackSeq: Int?) -> String? {
        let meta = row["__openclaw"] as? [String: Any]
        let seq = meta?["seq"] as? Int ?? fallbackSeq ?? 0
        guard seq > baselineSeq else { return nil }
        let message = OpenClawTranscriptMessage(
            role: row["role"] as? String ?? "message",
            text: OpenClawGatewayClient.extractMessageText(from: row["content"] ?? row["text"] ?? ""),
            seq: seq,
            stopReason: row["stopReason"] as? String
        )
        guard shouldDisplayMessage(message) else { return nil }
        messagesBySeq[seq] = message
        if message.role == "assistant", !message.text.isEmpty {
            assistantDraft = ""
        }
        return render()
    }

    func renderFinal() -> String {
        render() ?? ""
    }

    private func render() -> String? {
        var sections: [String] = []
        if !progressLines.isEmpty {
            let lines = progressLines.map { "- \($0)" }.joined(separator: "\n")
            sections.append("### 执行进度\n\n\(lines)")
        }

        let messages = messagesBySeq
            .sorted { $0.key < $1.key }
            .map(\.value)
            .filter { $0.role != "user" }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        sections.append(contentsOf: messages.map { message in
            "### \(title(for: message.role))\n\n\(message.text)"
        })

        if !assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("### OpenClaw\n\n\(assistantDraft)")
        }

        let rendered = sections.joined(separator: "\n\n---\n\n")
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rendered
    }

    private func title(for role: String) -> String {
        switch role {
        case "assistant": return "OpenClaw"
        case "tool": return "工具结果"
        case "toolCall": return "工具调用"
        case "toolResult": return "工具结果"
        default: return role
        }
    }

    private func shouldDisplayMessage(_ message: OpenClawTranscriptMessage) -> Bool {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text == "[toolCall] bash" || text == "[toolCall]" {
            return false
        }
        if message.role == "toolCall" {
            return false
        }
        return true
    }

    private func readableItemType(_ type: String) -> String {
        switch type {
        case "userMessage": return "用户指令"
        case "reasoning": return "OpenClaw 分析"
        case "agentMessage": return "OpenClaw 回复"
        case "toolCall": return "工具调用"
        case "toolResult": return "工具结果"
        case "commandExecution": return "命令执行"
        default: return type
        }
    }

    private func readablePhase(_ phase: String) -> String {
        switch phase {
        case "started": return "开始"
        case "completed": return "完成"
        default: return phase
        }
    }
}
