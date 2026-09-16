import Foundation

enum KeyboardActionType: String, Decodable {
    case paste
    case clarify
    case showMarkdown = "show_markdown"
    case tip
}

enum KeyboardQuickAction: String, Encodable, CaseIterable {
    case format
    case polish
    case concise
    case bullets
}

struct KeyboardAudioResponse: Decodable {
    let operation: String
    let actionType: KeyboardActionType
    let transcript: String
    let result: String
    let warning: String?
    let configUpdate: KeyboardConfigUpdate?
    let clarifyQuestion: String?
    let creditsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case operation, transcript, result, warning
        case actionType = "action_type"
        case configUpdate = "config_update"
        case clarifyQuestion = "clarify_question"
        case creditsRemaining = "credits_remaining"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(String.self, forKey: .operation)
        transcript = try container.decode(String.self, forKey: .transcript)
        result = try container.decode(String.self, forKey: .result)
        warning = try? container.decode(String.self, forKey: .warning)
        configUpdate = try? container.decode(KeyboardConfigUpdate.self, forKey: .configUpdate)
        clarifyQuestion = try? container.decode(String.self, forKey: .clarifyQuestion)
        creditsRemaining = try? container.decode(Int.self, forKey: .creditsRemaining)
        let rawAction = (try? container.decode(String.self, forKey: .actionType)) ?? "paste"
        actionType = KeyboardActionType(rawValue: rawAction) ?? .paste
    }
}

struct KeyboardQuickActionRequest: Encodable {
    let action: KeyboardQuickAction
    let text: String
    let sourceOperation: String?

    enum CodingKeys: String, CodingKey {
        case action, text
        case sourceOperation = "source_operation"
    }
}

struct KeyboardQuickActionResponse: Decodable {
    let operation: String
    let actionType: KeyboardActionType
    let inputText: String
    let result: String
    let creditsRemaining: Int?
    let transcript: String?

    enum CodingKeys: String, CodingKey {
        case operation, result, transcript
        case actionType = "action_type"
        case inputText = "input_text"
        case creditsRemaining = "credits_remaining"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(String.self, forKey: .operation)
        inputText = try container.decode(String.self, forKey: .inputText)
        result = try container.decode(String.self, forKey: .result)
        creditsRemaining = try? container.decode(Int.self, forKey: .creditsRemaining)
        transcript = try? container.decode(String.self, forKey: .transcript)
        let rawAction = (try? container.decode(String.self, forKey: .actionType)) ?? "paste"
        actionType = KeyboardActionType(rawValue: rawAction) ?? .paste
    }
}

struct KeyboardPlanResponse: Decodable {
    let creditsRemaining: Int

    enum CodingKeys: String, CodingKey {
        case creditsRemaining = "credits_remaining"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        creditsRemaining = (try? c.decode(Int.self, forKey: .creditsRemaining)) ?? 0
    }
}

struct KeyboardConfigUpdate: Decodable {
    let maxDurationSec: Int?

    enum CodingKeys: String, CodingKey {
        case maxDurationSec = "max_duration_sec"
    }
}

struct KeyboardPromptSettings: Codable {
    var transcribePrompt: String?
    var transcribeEnabled: Bool
    var rewritePrompt: String?
    var rewriteEnabled: Bool
    var intentHint: String?
    var intentEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case transcribePrompt = "transcribe_prompt"
        case transcribeEnabled = "transcribe_enabled"
        case rewritePrompt = "rewrite_prompt"
        case rewriteEnabled = "rewrite_enabled"
        case intentHint = "intent_hint"
        case intentEnabled = "intent_enabled"
    }
}

struct KeyboardPersona: Codable, Identifiable {
    let id: String
    let name: String
    let description: String?
    var isActive: Bool
    let isBuiltin: Bool
    var prompts: KeyboardPromptSettings

    enum CodingKeys: String, CodingKey {
        case id, name, description, prompts
        case isActive = "is_active"
        case isBuiltin = "is_builtin"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try? c.decode(String.self, forKey: .description)
        isActive = (try? c.decode(Bool.self, forKey: .isActive)) ?? false
        isBuiltin = (try? c.decode(Bool.self, forKey: .isBuiltin)) ?? false
        prompts = (try? c.decode(KeyboardPromptSettings.self, forKey: .prompts)) ?? KeyboardPromptSettings(
            transcribePrompt: nil,
            transcribeEnabled: false,
            rewritePrompt: nil,
            rewriteEnabled: false,
            intentHint: nil,
            intentEnabled: false
        )
    }
}

struct KeyboardPersonaListResponse: Decodable {
    let personas: [KeyboardPersona]
}

struct KeyboardPersonaUpdateBody: Encodable {
    let name: String?
    let description: String?
    let prompts: KeyboardPromptSettings?
}

struct KeyboardAPIErrorResponse: Decodable {
    let code: String?
    let message: String?
    let configUpdate: KeyboardConfigUpdate?

    enum CodingKeys: String, CodingKey {
        case code, message
        case configUpdate = "config_update"
    }
}

enum KeyboardBlockedReason {
    case loginRequired
    case creditsExhausted
}

final class KeyboardInputUnavailableError: LocalizedError {
    let reason: KeyboardBlockedReason
    private let message: String

    init(reason: KeyboardBlockedReason, message: String) {
        self.reason = reason
        self.message = message
    }

    var errorDescription: String? { message }
}

enum KeyboardAPIClient {

    private static let processURL = URL(string: APIConfig.Audio.process)!
    private static let planURL = URL(string: APIConfig.Config.plan)!
    private static let personasURL = URL(string: APIConfig.Personas.list)!
    private static let deactivatePersonasURL = URL(string: APIConfig.Personas.deactivateAll)!
    private static let quickActionURL = URL(string: APIConfig.Text.quickAction)!

    static func getPlan(token: String) async throws -> KeyboardPlanResponse {
        var request = URLRequest(url: planURL)
        request.httpMethod = "GET"
        applyHeaders(&request, token: token)
        return try await decode(request)
    }

    static func processAudio(
        fileURL: URL,
        token: String,
        operation: String,
        selectedText: String? = nil,
        clipboardHistory: String? = nil,
        fastMode: Bool = false
    ) async throws -> KeyboardAudioResponse {
        var request = URLRequest(url: processURL)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendField(&body, boundary: boundary, name: "operation", value: operation)
        appendField(&body, boundary: boundary, name: "fast_mode", value: fastMode ? "true" : "false")
        if let text = selectedText, !text.isEmpty {
            appendField(&body, boundary: boundary, name: "selected_text", value: text)
        }
        if let history = clipboardHistory, !history.isEmpty {
            appendField(&body, boundary: boundary, name: "clipboard_history", value: history)
        }

        let filename = fileURL.lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        return try await decode(request)
    }

    static func quickAction(
        token: String,
        action: KeyboardQuickAction,
        text: String,
        sourceOperation: String?
    ) async throws -> KeyboardQuickActionResponse {
        var request = URLRequest(url: quickActionURL)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(KeyboardQuickActionRequest(
            action: action,
            text: text,
            sourceOperation: sourceOperation
        ))
        return try await decode(request)
    }

    static func getPersonas(token: String) async throws -> [KeyboardPersona] {
        var request = URLRequest(url: personasURL)
        request.httpMethod = "GET"
        applyHeaders(&request, token: token)
        let response: KeyboardPersonaListResponse = try await decode(request)
        return response.personas
    }

    static func activatePersona(token: String, id: String) async throws -> KeyboardPersona {
        var request = URLRequest(url: URL(string: APIConfig.Personas.activate(id))!)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        return try await decode(request)
    }

    static func deactivatePersonas(token: String) async throws {
        var request = URLRequest(url: deactivatePersonasURL)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let _: KeyboardEmptyResponse = try await decode(request)
    }

    static func updatePersonaModules(token: String, id: String, prompts: KeyboardPromptSettings) async throws -> KeyboardPersona {
        var request = URLRequest(url: URL(string: APIConfig.Personas.item(id))!)
        request.httpMethod = "PUT"
        applyHeaders(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(KeyboardPersonaUpdateBody(name: nil, description: nil, prompts: prompts))
        return try await decode(request)
    }

    private static func applyHeaders(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(APIConfig.clientPlatform, forHTTPHeaderField: "X-Client-Platform")
        request.setValue(MobileStrings.language.rawValue, forHTTPHeaderField: "X-Accept-Language")
    }

    private static func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "KeyboardAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: MobileStrings.processFailed()])
        }

        if (200...299).contains(http.statusCode) {
            if T.self == KeyboardEmptyResponse.self {
                return KeyboardEmptyResponse() as! T
            }
            return try JSONDecoder().decode(T.self, from: data)
        }

        let apiError = try? JSONDecoder().decode(KeyboardAPIErrorResponse.self, from: data)
        if http.statusCode == 401 || apiError?.code == "USER_BANNED" {
            // 集中清除共享 Keychain 中已失效的 token:后端 session 为活跃滑动续期,
            // 401 仅出现在 session 真正过期/被撤销时。这里统一清除,保证所有键盘接口
            // (含人设面板等未单独处理 loginRequired 的调用点)失效后回到"请登录"状态。
            KeychainTokenStore.delete()
            throw KeyboardInputUnavailableError(reason: .loginRequired, message: MobileStrings.sessionExpired())
        }
        if apiError?.code == "CREDITS_EXHAUSTED" {
            throw KeyboardInputUnavailableError(reason: .creditsExhausted, message: MobileStrings.creditsExhausted())
        }
        throw NSError(
            domain: "KeyboardAPI",
            code: http.statusCode,
            userInfo: [NSLocalizedDescriptionKey: apiError?.message ?? MobileStrings.requestFailed(http.statusCode)]
        )
    }

    private static func appendField(_ body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }
}

private struct KeyboardEmptyResponse: Decodable {}
