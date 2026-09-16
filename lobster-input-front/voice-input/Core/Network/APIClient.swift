/// APIClient.swift
/// REST API 客户端（单例），封装与后端的所有 HTTP 通信。
/// 支持 JSON POST 和 multipart/form-data 音频上传两种请求方式。
/// 鉴权: requiresAuth=true 时自动携带 JWT Bearer Token；
///       requiresAuth=false 时不注入 Authorization，适用于登录/注册等公开接口。
/// 域名和路径统一由 APIConfig 管理，本文件不出现任何硬编码地址。
import Foundation

struct AudioProcessStreamCallbacks {
    var onSearchStart: (() async -> Void)?
    var onSearchDelta: ((String) async -> Void)?
}

final class APIClient {

    static let shared = APIClient()
    private init() {}

    /// 交互式接口（登录/验证码/配置/词典/人设等）的默认超时，避免半开连接下 UI 长时间挂起。
    private static let interactiveTimeout: TimeInterval = 30
    /// 音频/文本处理接口（含 LLM 生成）的超时，给足生成时间但仍有上限。
    private static let processingTimeout: TimeInterval = 180

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // 单请求超时统一改由 request.timeoutInterval 按接口区分；这里仅保留资源总时长上限。
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    // MARK: - Auth

    /// 统一发送验证码（不区分登录/注册）
    func sendCode(email: String) async throws {
        let _: EmptyResponse = try await post(
            url: APIConfig.Auth.sendCode,
            body: SendCodeRequest(email: email),
            requiresAuth: false
        )
    }

    /// 统一验证（有账号登录，无账号自动注册）
    func verify(email: String, code: String) async throws -> AuthResponse {
        return try await post(
            url: APIConfig.Auth.verify,
            body: LoginRequest(
                email: email,
                code: code,
                deviceId: DeviceIdentity.deviceID(),
                hardwareFingerprint: DeviceIdentity.hardwareFingerprint()
            ),
            requiresAuth: false
        )
    }

    /// 新用户提交邀请码完成注册
    func verifyInvite(email: String, inviteCode: String, deviceId: String, hardwareFingerprint: String) async throws -> AuthResponse {
        return try await post(
            url: APIConfig.Auth.verifyInvite,
            body: VerifyInviteRequest(email: email, inviteCode: inviteCode, deviceId: deviceId, hardwareFingerprint: hardwareFingerprint),
            requiresAuth: false
        )
    }

    /// 获取当前用户的3个邀请码及使用状态
    func fetchMyInviteCodes() async throws -> [InviteCodeItem] {
        let resp: MyInviteCodesResponse = try await get(url: APIConfig.Auth.inviteCodes)
        return resp.inviteCodes
    }

    /// 通知服务端退出登录（销毁服务端会话，幂等）。
    /// 由退出登录入口 fire-and-forget 调用，失败不阻塞本地登出流程。
    /// token 由调用方在清除本地登录态之前捕获后传入，避免异步执行时本地 token 已被清空。
    func logout(token: String) async throws {
        var request = try buildRequest(url: APIConfig.Auth.logout, method: "POST", requiresAuth: false)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let _: LogoutResponse = try await perform(request)
    }

    // MARK: - Audio

    func processAudio(
        fileURL: URL,
        operation: String,
        selectedText: String?,
        clipboardHistory: [String]? = nil,
        clipboardItems: [ClipboardContextItem]? = nil,
        fastMode: Bool = false
    ) async throws -> AudioProcessResponse {
        var request = try buildRequest(url: APIConfig.Audio.process, method: "POST", timeout: Self.processingTimeout)

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try buildMultipartBody(
            fileURL: fileURL,
            operation: operation,
            selectedText: selectedText,
            clipboardHistory: clipboardHistory,
            clipboardItems: clipboardItems,
            openclawStatus: OpenClawManager.shared.statusString,
            openclawSessionActive: OpenClawManager.shared.agentSessionActiveForRequest,
            fastMode: fastMode,
            boundary: boundary
        )

        return try await perform(request)
    }

    func processAudioStream(
        fileURL: URL,
        operation: String,
        selectedText: String?,
        clipboardHistory: [String]? = nil,
        clipboardItems: [ClipboardContextItem]? = nil,
        fastMode: Bool = false,
        streamCallbacks: AudioProcessStreamCallbacks
    ) async throws -> AudioProcessResponse {
        var request = try buildRequest(url: APIConfig.Audio.processStream, method: "POST", timeout: Self.processingTimeout)

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try buildMultipartBody(
            fileURL: fileURL,
            operation: operation,
            selectedText: selectedText,
            clipboardHistory: clipboardHistory,
            clipboardItems: clipboardItems,
            openclawStatus: OpenClawManager.shared.statusString,
            openclawSessionActive: OpenClawManager.shared.agentSessionActiveForRequest,
            fastMode: fastMode,
            boundary: boundary
        )

        return try await performAudioProcessStream(request, streamCallbacks: streamCallbacks)
    }

    func processRealtimeText(
        text: String,
        clientASRText: String? = nil,
        asrSessionID: String? = nil,
        operation: String,
        selectedText: String?,
        clipboardHistory: [String]? = nil,
        clipboardItems: [ClipboardContextItem]? = nil,
        fastMode: Bool = false,
        transcriptLanguage: String? = nil
    ) async throws -> AudioProcessResponse {
        return try await post(
            url: APIConfig.AudioV2.processText,
            body: TextProcessRequest(
                operation: operation,
                text: text,
                clientASRText: clientASRText,
                asrSessionID: asrSessionID,
                selectedText: selectedText,
                clipboardHistory: clipboardHistory,
                clipboardItems: clipboardItems,
                provider: nil,
                model: nil,
                openclawStatus: OpenClawManager.shared.statusString,
                openclawSessionActive: OpenClawManager.shared.agentSessionActiveForRequest,
                fastMode: fastMode,
                transcriptLanguage: transcriptLanguage
            ),
            timeout: Self.processingTimeout
        )
    }

    func processRealtimeTextStream(
        text: String,
        clientASRText: String? = nil,
        asrSessionID: String? = nil,
        operation: String,
        selectedText: String?,
        clipboardHistory: [String]? = nil,
        clipboardItems: [ClipboardContextItem]? = nil,
        fastMode: Bool = false,
        transcriptLanguage: String? = nil,
        streamCallbacks: AudioProcessStreamCallbacks
    ) async throws -> AudioProcessResponse {
        var request = try buildRequest(url: APIConfig.AudioV2.processTextStream, method: "POST", timeout: Self.processingTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(TextProcessRequest(
            operation: operation,
            text: text,
            clientASRText: clientASRText,
            asrSessionID: asrSessionID,
            selectedText: selectedText,
            clipboardHistory: clipboardHistory,
            clipboardItems: clipboardItems,
            provider: nil,
            model: nil,
            openclawStatus: OpenClawManager.shared.statusString,
            openclawSessionActive: OpenClawManager.shared.agentSessionActiveForRequest,
            fastMode: fastMode,
            transcriptLanguage: transcriptLanguage
        ))
        return try await performAudioProcessStream(request, streamCallbacks: streamCallbacks)
    }

    // MARK: - Config

    /// 获取 App 启动全局配置（无需鉴权）
    func fetchStartupConfig() async throws -> AppStartupConfig {
        return try await get(url: APIConfig.Config.startup, requiresAuth: false)
    }

    /// 获取当前用户套餐积分信息
    func fetchUserPlanInfo() async throws -> UserPlanInfo {
        return try await get(url: APIConfig.Config.plan)
    }

    func fetchRecordingConfig() async throws -> RecordingConfigResponse {
        return try await get(url: APIConfig.Config.recording)
    }

    // MARK: - Payments

    func fetchPaymentCatalog() async throws -> PaymentCatalogResponse {
        return try await get(url: APIConfig.Payments.catalog)
    }

    func createSubscriptionCheckout(
        provider: String,
        productCode: String,
        paymentMethod: String,
        currency: String,
        planCode: String,
        billingCycle: String
    ) async throws -> PaymentCheckoutResponse {
        return try await post(
            url: APIConfig.Payments.subscriptionCheckout,
            body: CreateSubscriptionCheckoutBody(
                planCode: planCode,
                billingCycle: billingCycle,
                autoRenew: true,
                provider: provider,
                productCode: productCode,
                paymentMethod: paymentMethod,
                currency: currency,
                settlementMode: "full_price",
                discountCode: ""
            )
        )
    }

    /// 取消订阅自动续费（请求体为空 JSON，鉴权/请求头与其它业务接口一致）
    func cancelSubscriptionRenewal() async throws -> SubscriptionCancelRenewalResponse {
        return try await post(
            url: APIConfig.Subscription.cancelRenewal,
            body: EmptyJSONBody()
        )
    }

    func createCreditsTopupCheckout(provider: String, productCode: String, paymentMethod: String, currency: String) async throws -> PaymentCheckoutResponse {
        return try await post(
            url: APIConfig.Payments.creditsTopupCheckout,
            body: CreateCreditsTopupCheckoutBody(
                provider: provider,
                productCode: productCode,
                paymentMethod: paymentMethod,
                currency: currency,
                discountCode: ""
            )
        )
    }

    // MARK: - Feedback

    func submitFeedback(content: String, phone: String?, email: String?) async throws {
        let _: MessageResponse = try await post(
            url: APIConfig.Feedback.submit,
            body: FeedbackSubmitRequest(content: content, phone: phone, email: email)
        )
    }

    // MARK: - HotWords (词典)

    func listHotWords(page: Int = 1, pageSize: Int = 50, search: String = "") async throws -> HotWordListResponse {
        var query = "?page=\(page)&page_size=\(pageSize)"
        if !search.isEmpty, let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&search=\(encoded)"
        }
        return try await get(url: APIConfig.HotWords.list + query)
    }

    func createHotWord(word: String) async throws -> HotWordItem {
        return try await post(
            url: APIConfig.HotWords.list,
            body: HotWordCreateBody(word: word)
        )
    }

    func updateHotWord(id: String, word: String) async throws -> HotWordItem {
        return try await put(
            url: APIConfig.HotWords.item(id),
            body: HotWordUpdateBody(word: word)
        )
    }

    func deleteHotWord(id: String) async throws {
        let _: MessageResponse = try await delete(url: APIConfig.HotWords.item(id))
    }

    // MARK: - Personas (人设)

    func listPersonas() async throws -> [PersonaItem] {
        let resp: PersonaListResponse = try await get(url: APIConfig.Personas.list)
        return resp.personas
    }

    func createPersona(name: String, description: String?, prompts: PersonaPrompts) async throws -> PersonaItem {
        return try await post(
            url: APIConfig.Personas.list,
            body: PersonaCreateBody(name: name, description: description, prompts: prompts)
        )
    }

    func updatePersona(id: String, name: String?, description: String?, prompts: PersonaPrompts?) async throws -> PersonaItem {
        return try await put(
            url: APIConfig.Personas.item(id),
            body: PersonaUpdateBody(name: name, description: description, prompts: prompts)
        )
    }

    func deletePersona(id: String) async throws {
        let _: MessageResponse = try await delete(url: APIConfig.Personas.item(id))
    }

    func activatePersona(id: String) async throws -> PersonaItem {
        return try await postEmpty(url: APIConfig.Personas.activate(id))
    }

    func deactivateAllPersonas() async throws {
        let _: MessageResponse = try await postEmpty(url: APIConfig.Personas.deactivateAll)
    }

    // MARK: - Logs

    /// 上报日志条目（由 LogReporter 调用，复用统一请求管道）
    func uploadLogs(appVersion: String, osVersion: String, entries: [LogEntry]) async throws {
        let _: EmptyResponse = try await post(
            url: APIConfig.Logs.report,
            body: LogReportBody(app_version: appVersion, os_version: osVersion, entries: entries)
        )
    }

    // MARK: - Private Helpers

    private func get<Response: Decodable>(url: String, requiresAuth: Bool = true) async throws -> Response {
        let request = try buildRequest(url: url, method: "GET", requiresAuth: requiresAuth)
        return try await perform(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        url: String,
        body: Body,
        requiresAuth: Bool = true,
        timeout: TimeInterval = APIClient.interactiveTimeout
    ) async throws -> Response {
        var request = try buildRequest(url: url, method: "POST", requiresAuth: requiresAuth, timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func postEmpty<Response: Decodable>(url: String) async throws -> Response {
        let request = try buildRequest(url: url, method: "POST")
        return try await perform(request)
    }

    private func put<Body: Encodable, Response: Decodable>(
        url: String,
        body: Body
    ) async throws -> Response {
        var request = try buildRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func delete<Response: Decodable>(url: String) async throws -> Response {
        let request = try buildRequest(url: url, method: "DELETE")
        return try await perform(request)
    }

    /// 会话失效统一处理：后端登录态为 15 天滑动续期，任何携带登录凭证的业务请求
    /// 收到 401 即代表服务端判定会话已过期（Session expired），此时统一强制清除本地
    /// 登录态，UI 会随 isLoggedIn 自动切回登录界面。
    /// 仅在请求确实携带 Authorization 时触发，登录/验证码等公开接口的 401 不受影响。
    private static func handleSessionExpired(for request: URLRequest) {
        guard request.value(forHTTPHeaderField: "Authorization") != nil else { return }
        Task { @MainActor in
            guard AuthStore.shared.isLoggedIn else { return }
            DebugTrace.log("APIClient: 401 with credentials, session expired, forcing logout")
            AuthStore.shared.logout()
        }
    }

    private func buildRequest(
        url urlString: String,
        method: String,
        requiresAuth: Bool = true,
        timeout: TimeInterval = APIClient.interactiveTimeout
    ) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout

        if requiresAuth, let token = AuthStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(APIConfig.appVariant, forHTTPHeaderField: "X-App-Variant")
        request.setValue("macos", forHTTPHeaderField: "X-Client-Platform")
        let languageCode = LanguageManager.shared.current.rawValue
        request.setValue(languageCode, forHTTPHeaderField: "Accept-Language")
        request.setValue(languageCode, forHTTPHeaderField: "X-Accept-Language")
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 {
            Self.handleSessionExpired(for: request)
            throw APIError.unauthorized
        }
        if http.statusCode == 403 {
            let errResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            if errResp?.code == "USER_BANNED" { throw APIError.userBanned }
        }
        guard (200..<300).contains(http.statusCode) else {
            let errResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            let errMsg = errResp?.message ?? "Unknown error"
            throw APIError.httpError(http.statusCode, errMsg, errResp)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func performAudioProcessStream(
        _ request: URLRequest,
        streamCallbacks: AudioProcessStreamCallbacks
    ) async throws -> AudioProcessResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 {
            Self.handleSessionExpired(for: request)
            throw APIError.unauthorized
        }
        if http.statusCode == 403 { throw APIError.httpError(http.statusCode, "Forbidden", nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpError(http.statusCode, "Stream request failed", nil)
        }

        var currentEvent = ""
        var dataLines: [String] = []
        var searchStreamStarted = false

        func consumeEvent() async throws -> AudioProcessResponse? {
            guard !currentEvent.isEmpty || !dataLines.isEmpty else { return nil }
            let event = currentEvent
            let data = dataLines.joined(separator: "\n")
            currentEvent = ""
            dataLines.removeAll(keepingCapacity: true)

            guard let payload = data.data(using: .utf8) else { return nil }
            if event == "search_start" {
                searchStreamStarted = true
                if let onSearchStart = streamCallbacks.onSearchStart {
                    await onSearchStart()
                }
                return nil
            }
            if event == "delta" {
                guard searchStreamStarted else {
                    DebugTrace.log("APIClient ignored stream delta before search_start")
                    return nil
                }
                if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                   let text = obj["text"] as? String {
                    if let onSearchDelta = streamCallbacks.onSearchDelta {
                        await onSearchDelta(text)
                    }
                }
                return nil
            }
            if event == "final" {
                return try decodeAudioProcessResponse(payload, context: "stream final")
            }
            if event == "error" {
                let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
                let message = (obj?["message"] as? String) ?? "Stream request failed"
                throw APIError.httpError(http.statusCode, message, nil)
            }
            return nil
        }

        for try await line in bytes.lines {
            if line.isEmpty {
                if let final = try await consumeEvent() {
                    return final
                }
                continue
            }
            if line.hasPrefix("event:") {
                if !currentEvent.isEmpty || !dataLines.isEmpty {
                    if let final = try await consumeEvent() {
                        return final
                    }
                }
                currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        if let final = try await consumeEvent() {
            return final
        }
        throw APIError.networkError(URLError(.badServerResponse))
    }

    private func decodeAudioProcessResponse(_ data: Data, context: String) throws -> AudioProcessResponse {
        do {
            return try JSONDecoder().decode(AudioProcessResponse.self, from: data)
        } catch {
            // 响应体可能包含用户语音转写/LLM 结果等敏感内容，绝不写入磁盘日志；
            // 仅记录错误类型与字节数用于诊断。
            DebugTrace.log("APIClient \(context) decode failed: \(error); payloadBytes=\(data.count)")
            throw APIError.decodingError(error)
        }
    }

    private func buildMultipartBody(
        fileURL: URL,
        operation: String,
        selectedText: String?,
        clipboardHistory: [String]?,
        clipboardItems: [ClipboardContextItem]?,
        openclawStatus: String?,
        openclawSessionActive: Bool,
        fastMode: Bool,
        boundary: String
    ) throws -> Data {
        var body = Data()
        let crlf = "\r\n"
        let fileName = fileURL.lastPathComponent.isEmpty ? "audio.wav" : fileURL.lastPathComponent
        let mimeType = Self.mimeType(for: fileURL)

        func appendField(_ name: String, value: String) {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(value)\(crlf)".data(using: .utf8)!)
        }

        appendField("operation", value: operation)
        if let text = selectedText { appendField("selected_text", value: text) }

        if let clips = clipboardHistory, !clips.isEmpty {
            if let json = try? JSONSerialization.data(withJSONObject: clips),
               let jsonStr = String(data: json, encoding: .utf8) {
                appendField("clipboard_history", value: jsonStr)
            }
        }

        if let items = clipboardItems, !items.isEmpty {
            if let json = try? JSONEncoder().encode(items),
               let jsonStr = String(data: json, encoding: .utf8) {
                appendField("clipboard_items", value: jsonStr)
            }
        }

        if let status = openclawStatus {
            appendField("openclaw_status", value: status)
        }
        appendField("openclaw_session_active", value: openclawSessionActive ? "true" : "false")
        if fastMode {
            appendField("fast_mode", value: "true")
        }

        // 音频文件读取失败时直接抛错，让上层快速失败，而不是发出缺少 file 部件的残缺请求
        // 让后端返回一个与真实原因（本地文件读不到）无关的参数错误。
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(fileData)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }

    private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "flac":
            return "audio/flac"
        case "m4a":
            return "audio/m4a"
        default:
            return "application/octet-stream"
        }
    }
}

// 用于忽略响应体的占位类型
private struct EmptyResponse: Decodable {}

/// 空 JSON 请求体（编码为 `{}`）
private struct EmptyJSONBody: Encodable {}

/// 服务端登出响应（{"ok": true}）
private struct LogoutResponse: Decodable {
    let ok: Bool
}

/// 通用消息响应（后端 {"message": "..."} 格式）
struct MessageResponse: Decodable {
    let message: String
}

private struct FeedbackSubmitRequest: Encodable {
    let content: String
    let phone: String?
    let email: String?
}

// MARK: - Log 上报共享类型（供 LogReporter 使用）

struct LogEntry: Encodable {
    let level: String
    let tag: String
    let message: String
    let extra: [String: String]?
    let timestamp: String
}

private struct LogReportBody: Encodable {
    let app_version: String
    let os_version: String
    let entries: [LogEntry]
}

// MARK: - 错误格式化工具

/// 将 API 调用错误转为可展示的本地化文案。
/// APIError 优先用其 errorDescription；其它错误使用系统默认描述。
func apiErrorMessage(_ error: Error) -> String {
    (error as? APIError)?.errorDescription ?? error.localizedDescription
}
