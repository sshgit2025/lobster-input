import Foundation

final class APIClient {

    static let shared = APIClient()
    private init() {}

    private let session = URLSession.shared

    // MARK: - Auth

    func sendCode(email: String) async throws {
        let _: EmptyResponse = try await post(
            url: APIConfig.Auth.sendCode,
            body: SendCodeRequest(email: email),
            requiresAuth: false
        )
    }

    func verify(email: String, code: String) async throws -> AuthResponse {
        return try await post(
            url: APIConfig.Auth.verify,
            body: LoginRequest(
                email: email,
                code: code,
                deviceId: AuthStore.shared.deviceId,
                hardwareFingerprint: AuthStore.shared.hardwareFingerprint
            ),
            requiresAuth: false
        )
    }

    func verifyInvite(email: String, inviteCode: String, deviceId: String) async throws -> AuthResponse {
        return try await post(
            url: APIConfig.Auth.verifyInvite,
            body: VerifyInviteRequest(
                email: email,
                inviteCode: inviteCode,
                deviceId: deviceId,
                hardwareFingerprint: AuthStore.shared.hardwareFingerprint
            ),
            requiresAuth: false
        )
    }

    func fetchMyInviteCodes() async throws -> [InviteCodeItem] {
        let resp: MyInviteCodesResponse = try await get(url: APIConfig.Auth.inviteCodes)
        return resp.inviteCodes
    }

    /// 通知服务端退出登录(撤销 session)。
    /// 调用方以 fire-and-forget 方式使用:token 由调用方在清空本地登录态之前捕获传入,
    /// 结果忽略(后端接口幂等,失败不影响本地退出)。
    func logout(token: String) async {
        guard let url = URL(string: APIConfig.Auth.logout) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await session.data(for: request)
    }

    // MARK: - Audio

    func processAudio(
        fileURL: URL,
        operation: String,
        selectedText: String? = nil,
        clipboardHistory: String? = nil,
        fastMode: Bool = false
    ) async throws -> AudioProcessResponse {
        guard let token = AuthStore.shared.token else { throw APIError.notLoggedIn }

        var request = URLRequest(url: URL(string: APIConfig.Audio.process)!)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendFormField(&body, boundary: boundary, name: "operation", value: operation)
        if let text = selectedText, !text.isEmpty {
            appendFormField(&body, boundary: boundary, name: "selected_text", value: text)
        }
        if let history = clipboardHistory, !history.isEmpty {
            appendFormField(&body, boundary: boundary, name: "clipboard_history", value: history)
        }
        appendFormField(&body, boundary: boundary, name: "fast_mode", value: fastMode ? "true" : "false")
        appendFileField(&body, boundary: boundary, name: "file", fileURL: fileURL)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        return try handleResponse(data: data, response: response)
    }

    func processRealtimeText(
        text: String,
        clientASRText: String,
        asrSessionID: String,
        operation: String,
        selectedText: String? = nil,
        clipboardHistory: [String]? = nil,
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
                provider: nil,
                model: nil,
                openclawStatus: nil,
                fastMode: fastMode,
                transcriptLanguage: transcriptLanguage
            )
        )
    }

    func quickAction(action: MobileQuickAction, text: String, sourceOperation: String?) async throws -> TextQuickActionResponse {
        return try await post(
            url: APIConfig.Text.quickAction,
            body: MobileQuickActionRequest(action: action, text: text, sourceOperation: sourceOperation)
        )
    }

    // MARK: - Config

    func fetchStartupConfig() async throws -> AppStartupConfig {
        return try await get(url: APIConfig.Config.startup, requiresAuth: false)
    }

    func fetchPlanInfo() async throws -> UserPlanInfo {
        return try await get(url: APIConfig.Config.plan)
    }

    func fetchRecordingConfig() async throws -> RecordingConfigResponse {
        return try await get(url: APIConfig.Config.recording)
    }

    // MARK: - Subscription

    /// 取消订阅自动续费（仅对后端标记 renewal_cancellable=true 的订阅生效；
    /// Apple IAP 订阅由系统「管理订阅」页负责，后端会返回 status=apple_managed）。
    func cancelSubscriptionRenewal() async throws -> CancelRenewalResponse {
        return try await post(url: APIConfig.Subscription.cancelRenewal, body: EmptyBody())
    }

    // MARK: - Apple IAP

    func fetchAppleIapProducts() async throws -> AppleIapProductsResponse {
        return try await get(url: APIConfig.Payments.appleProducts)
    }

    func verifyAppleTransaction(signedTransaction: String, source: String) async throws -> AppleVerifyResponse {
        return try await post(
            url: APIConfig.Payments.appleVerify,
            body: AppleVerifyRequestBody(signedTransaction: signedTransaction, source: source)
        )
    }

    func restoreApplePurchases(signedTransactions: [String]) async throws -> AppleRestoreResponse {
        return try await post(
            url: APIConfig.Payments.appleRestore,
            body: AppleRestoreRequestBody(signedTransactions: signedTransactions)
        )
    }

    // MARK: - HotWords

    func fetchHotWords() async throws -> [HotWordItem] {
        let resp: HotWordListResponse = try await get(url: APIConfig.HotWords.list)
        return resp.hotwords
    }

    func createHotWord(word: String) async throws -> HotWordItem {
        return try await post(url: APIConfig.HotWords.list, body: HotWordCreateBody(word: word))
    }

    func updateHotWord(id: String, word: String) async throws -> HotWordItem {
        return try await put(url: APIConfig.HotWords.item(id), body: HotWordUpdateBody(word: word))
    }

    func deleteHotWord(id: String) async throws {
        let _: EmptyResponse = try await delete(url: APIConfig.HotWords.item(id))
    }

    // MARK: - Personas

    func fetchPersonas() async throws -> [PersonaItem] {
        let resp: PersonaListResponse = try await get(url: APIConfig.Personas.list)
        return resp.personas
    }

    func createPersona(name: String, description: String?, prompts: PersonaPrompts) async throws -> PersonaItem {
        return try await post(url: APIConfig.Personas.list, body: PersonaCreateBody(name: name, description: description, prompts: prompts))
    }

    func updatePersona(id: String, name: String?, description: String?, prompts: PersonaPrompts?) async throws -> PersonaItem {
        return try await put(url: APIConfig.Personas.item(id), body: PersonaUpdateBody(name: name, description: description, prompts: prompts))
    }

    func deletePersona(id: String) async throws {
        let _: EmptyResponse = try await delete(url: APIConfig.Personas.item(id))
    }

    func activatePersona(id: String) async throws {
        let _: EmptyResponse = try await post(url: APIConfig.Personas.activate(id), body: EmptyBody())
    }

    func deactivateAllPersonas() async throws {
        let _: EmptyResponse = try await post(url: APIConfig.Personas.deactivateAll, body: EmptyBody())
    }

    // MARK: - Agreements

    func fetchAgreements() async throws -> [AgreementItem] {
        let resp: AgreementsResponse = try await get(url: APIConfig.Agreements.get, requiresAuth: false)
        return resp.agreements
    }

    // MARK: - Internal

    private func applyHeaders(_ request: inout URLRequest, token: String? = nil) {
        if let t = token ?? AuthStore.shared.token {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(APIConfig.clientPlatform, forHTTPHeaderField: "X-Client-Platform")
        request.setValue(MobileStrings.language.rawValue, forHTTPHeaderField: "X-Accept-Language")
    }

    private func buildRequest(url: String, method: String, requiresAuth: Bool = true) throws -> URLRequest {
        guard let url = URL(string: url) else { throw APIError.networkError(URLError(.badURL)) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if requiresAuth {
            guard let token = AuthStore.shared.token else { throw APIError.notLoggedIn }
            applyHeaders(&request, token: token)
        } else {
            applyHeaders(&request)
        }
        return request
    }

    private func get<T: Decodable>(url: String, requiresAuth: Bool = true) async throws -> T {
        let request = try buildRequest(url: url, method: "GET", requiresAuth: requiresAuth)
        let (data, response) = try await session.data(for: request)
        return try handleResponse(data: data, response: response, authenticated: requiresAuth)
    }

    private func post<B: Encodable, T: Decodable>(url: String, body: B, requiresAuth: Bool = true) async throws -> T {
        var request = try buildRequest(url: url, method: "POST", requiresAuth: requiresAuth)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        return try handleResponse(data: data, response: response, authenticated: requiresAuth)
    }

    private func put<B: Encodable, T: Decodable>(url: String, body: B) async throws -> T {
        var request = try buildRequest(url: url, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        return try handleResponse(data: data, response: response)
    }

    private func delete<T: Decodable>(url: String) async throws -> T {
        let request = try buildRequest(url: url, method: "DELETE")
        let (data, response) = try await session.data(for: request)
        return try handleResponse(data: data, response: response)
    }

    private func handleResponse<T: Decodable>(data: Data, response: URLResponse, authenticated: Bool = true) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 {
            // 集中处理登录态失效:后端 session 已改为活跃滑动续期,401 仅出现在
            // session 真正过期/被撤销时。带认证的请求收到 401 统一清空本地登录态,
            // isLoggedIn 变化后根视图会自动切回登录界面。
            if authenticated {
                Task { @MainActor in AuthStore.shared.logout() }
            }
            throw APIError.unauthorized
        }
        if http.statusCode == 403 {
            if let errResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
               errResp.code == "USER_BANNED" {
                throw APIError.userBanned
            }
        }
        guard (200...299).contains(http.statusCode) else {
            let errResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(http.statusCode, body, errResp)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func appendFormField(_ body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendFileField(_ body: inout Data, boundary: String, name: String, fileURL: URL) {
        let filename = fileURL.lastPathComponent
        let mime = "audio/wav"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        if let fileData = try? Data(contentsOf: fileURL) { body.append(fileData) }
        body.append("\r\n".data(using: .utf8)!)
    }
}

private struct EmptyBody: Encodable {}
