import Foundation

// MARK: - 认证

struct SendCodeRequest: Encodable {
    let email: String
}

struct LoginRequest: Encodable {
    let email: String
    let code: String
    let deviceId: String
    let hardwareFingerprint: String

    enum CodingKeys: String, CodingKey {
        case email, code
        case deviceId = "device_id"
        case hardwareFingerprint = "hardware_fingerprint"
    }
}

struct AuthResponse: Decodable {
    let token: String
    let email: String
    let tier: String
    let isNewUser: Bool
    let requireInvite: Bool

    enum CodingKeys: String, CodingKey {
        case token, email, tier
        case isNewUser     = "is_new_user"
        case requireInvite = "require_invite"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token         = try c.decode(String.self, forKey: .token)
        email         = try c.decode(String.self, forKey: .email)
        tier          = (try? c.decode(String.self, forKey: .tier)) ?? "trial"
        isNewUser     = (try? c.decode(Bool.self, forKey: .isNewUser)) ?? false
        requireInvite = (try? c.decode(Bool.self, forKey: .requireInvite)) ?? false
    }
}

struct VerifyInviteRequest: Encodable {
    let email: String
    let inviteCode: String
    let deviceId: String
    let hardwareFingerprint: String

    enum CodingKeys: String, CodingKey {
        case email
        case inviteCode = "invite_code"
        case deviceId   = "device_id"
        case hardwareFingerprint = "hardware_fingerprint"
    }
}

struct InviteCodeItem: Decodable, Identifiable {
    var id: String { code }
    let code: String
    let isUsed: Bool
    let usedBy: String?
    let usedAt: String?

    enum CodingKeys: String, CodingKey {
        case code
        case isUsed = "is_used"
        case usedBy = "used_by"
        case usedAt = "used_at"
    }
}

struct MyInviteCodesResponse: Decodable {
    let inviteCodes: [InviteCodeItem]

    enum CodingKeys: String, CodingKey {
        case inviteCodes = "invite_codes"
    }
}

// MARK: - 套餐积分

struct UserPlanInfo: Decodable {
    let tier: String
    /// 后端按 X-Accept-Language 返回的本地化套餐名(套餐文案统一后端管理);优先展示,空则回退本地
    let planName: String
    let creditsTotal: Int
    let creditsUsed: Int
    let creditsRemaining: Int
    let creditsResetAt: String?
    /// 当前套餐到期时间（UTC ISO8601），免费/永久套餐为空
    let planExpiresAt: String?
    /// 当前订阅到期时间（UTC ISO8601），免费套餐可能为空
    let subscriptionExpiresAt: String?
    let registrationEnabled: Bool
    let inviteCodeEnabled: Bool
    let showInviteCodesEnabled: Bool
    /// 订阅是否处于自动续费状态
    let autoRenew: Bool
    /// 下次自动续费时间（UTC ISO8601），非自动续费为空
    let nextRenewalAt: String?
    /// 是否可在客户端内取消自动续费（Apple IAP 订阅后端恒为 false，取消走系统「管理订阅」）
    let renewalCancellable: Bool

    enum CodingKeys: String, CodingKey {
        case tier
        case planName               = "plan_name"
        case creditsTotal           = "credits_total"
        case creditsUsed            = "credits_used"
        case creditsRemaining       = "credits_remaining"
        case creditsResetAt         = "credits_reset_at"
        case planExpiresAt          = "plan_expires_at"
        case subscriptionExpiresAt  = "subscription_expires_at"
        case registrationEnabled    = "registration_enabled"
        case inviteCodeEnabled      = "invite_code_enabled"
        case showInviteCodesEnabled = "show_invite_codes_enabled"
        case autoRenew              = "auto_renew"
        case nextRenewalAt          = "next_renewal_at"
        case renewalCancellable     = "renewal_cancellable"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier                    = (try? c.decode(String.self, forKey: .tier)) ?? "none"
        planName                = (try? c.decode(String.self, forKey: .planName)) ?? ""
        creditsTotal            = (try? c.decode(Int.self, forKey: .creditsTotal)) ?? 0
        creditsUsed             = (try? c.decode(Int.self, forKey: .creditsUsed)) ?? 0
        creditsRemaining        = (try? c.decode(Int.self, forKey: .creditsRemaining)) ?? 0
        creditsResetAt          = try? c.decode(String.self, forKey: .creditsResetAt)
        planExpiresAt           = try? c.decode(String.self, forKey: .planExpiresAt)
        subscriptionExpiresAt   = try? c.decode(String.self, forKey: .subscriptionExpiresAt)
        registrationEnabled     = (try? c.decode(Bool.self, forKey: .registrationEnabled)) ?? true
        inviteCodeEnabled       = (try? c.decode(Bool.self, forKey: .inviteCodeEnabled)) ?? false
        showInviteCodesEnabled  = (try? c.decode(Bool.self, forKey: .showInviteCodesEnabled)) ?? false
        autoRenew               = (try? c.decode(Bool.self, forKey: .autoRenew)) ?? false
        nextRenewalAt           = try? c.decode(String.self, forKey: .nextRenewalAt)
        renewalCancellable      = (try? c.decode(Bool.self, forKey: .renewalCancellable)) ?? false
    }
}

/// POST /api/v1/subscription/cancel-renewal 响应
struct CancelRenewalResponse: Decodable {
    /// "cancelled" | "already_cancelled" | "apple_managed"
    let status: String
    /// 取消后套餐仍可使用至的时间（UTC ISO8601），可能为空
    let effectiveUntil: String?

    enum CodingKeys: String, CodingKey {
        case status
        case effectiveUntil = "effective_until"
    }
}

// MARK: - App 启动配置

struct AppStartupConfig: Decodable {
    let registrationEnabled: Bool
    let inviteCodeEnabled: Bool
    let showInviteCodesEnabled: Bool
    let registrationLimitEnabled: Bool
    let registrationLimitCount: Int

    enum CodingKeys: String, CodingKey {
        case registrationEnabled     = "registration_enabled"
        case inviteCodeEnabled        = "invite_code_enabled"
        case showInviteCodesEnabled   = "show_invite_codes_enabled"
        case registrationLimitEnabled = "registration_limit_enabled"
        case registrationLimitCount   = "registration_limit_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        registrationEnabled     = (try? c.decode(Bool.self, forKey: .registrationEnabled)) ?? true
        inviteCodeEnabled        = (try? c.decode(Bool.self, forKey: .inviteCodeEnabled)) ?? true
        showInviteCodesEnabled   = (try? c.decode(Bool.self, forKey: .showInviteCodesEnabled)) ?? false
        registrationLimitEnabled = (try? c.decode(Bool.self, forKey: .registrationLimitEnabled)) ?? false
        registrationLimitCount   = (try? c.decode(Int.self, forKey: .registrationLimitCount)) ?? 1000
    }
}

// MARK: - 音频处理

/// iOS 端支持的 ActionType（无 OpenClaw 系列）
enum ActionType: String, Decodable {
    case paste = "paste"
    case clarify = "clarify"
    case showMarkdown = "show_markdown"
    case tip = "tip"
}

struct ConfigUpdatePayload: Decodable {
    let maxDurationSec: Int?

    enum CodingKeys: String, CodingKey {
        case maxDurationSec = "max_duration_sec"
    }
}

struct AudioProcessResponse: Decodable {
    let operation: String
    let actionType: ActionType
    let transcript: String
    let result: String
    let modelProvider: String?
    let modelName: String?
    let warning: String?
    let configUpdate: ConfigUpdatePayload?
    let clarifyQuestion: String?
    let creditsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case operation, transcript, result, warning
        case actionType       = "action_type"
        case modelProvider    = "model_provider"
        case modelName        = "model_name"
        case configUpdate     = "config_update"
        case clarifyQuestion  = "clarify_question"
        case creditsRemaining = "credits_remaining"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation       = try c.decode(String.self, forKey: .operation)
        transcript      = try c.decode(String.self, forKey: .transcript)
        result          = try c.decode(String.self, forKey: .result)
        modelProvider   = try? c.decode(String.self, forKey: .modelProvider)
        modelName       = try? c.decode(String.self, forKey: .modelName)
        warning         = try? c.decode(String.self, forKey: .warning)
        configUpdate    = try? c.decode(ConfigUpdatePayload.self, forKey: .configUpdate)
        clarifyQuestion = try? c.decode(String.self, forKey: .clarifyQuestion)
        creditsRemaining = try? c.decode(Int.self, forKey: .creditsRemaining)
        let rawAction   = (try? c.decode(String.self, forKey: .actionType)) ?? "paste"
        actionType      = ActionType(rawValue: rawAction) ?? .paste
    }
}

struct TextProcessRequest: Encodable {
    let operation: String
    let text: String
    let clientASRText: String
    let asrSessionID: String
    let selectedText: String?
    let clipboardHistory: [String]?
    let provider: String?
    let model: String?
    let openclawStatus: String?
    let fastMode: Bool
    let transcriptLanguage: String?

    enum CodingKeys: String, CodingKey {
        case operation, text
        case clientASRText = "client_asr_text"
        case asrSessionID = "asr_session_id"
        case selectedText = "selected_text"
        case clipboardHistory = "clipboard_history"
        case provider, model
        case openclawStatus = "openclaw_status"
        case fastMode = "fast_mode"
        case transcriptLanguage = "transcript_language"
    }
}

enum MobileQuickAction: String, Codable, CaseIterable {
    case format
    case polish
    case concise
    case bullets
}

struct MobileQuickActionRequest: Encodable {
    let action: MobileQuickAction
    let text: String
    let sourceOperation: String?

    enum CodingKeys: String, CodingKey {
        case action, text
        case sourceOperation = "source_operation"
    }
}

struct TextQuickActionResponse: Decodable {
    let operation: String
    let actionType: ActionType
    let inputText: String
    let result: String
    let modelProvider: String?
    let modelName: String?
    let creditsRemaining: Int?
    let transcript: String?

    enum CodingKeys: String, CodingKey {
        case operation, result, transcript
        case actionType = "action_type"
        case inputText = "input_text"
        case modelProvider = "model_provider"
        case modelName = "model_name"
        case creditsRemaining = "credits_remaining"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = try c.decode(String.self, forKey: .operation)
        inputText = try c.decode(String.self, forKey: .inputText)
        result = try c.decode(String.self, forKey: .result)
        modelProvider = try? c.decode(String.self, forKey: .modelProvider)
        modelName = try? c.decode(String.self, forKey: .modelName)
        creditsRemaining = try? c.decode(Int.self, forKey: .creditsRemaining)
        transcript = try? c.decode(String.self, forKey: .transcript)
        let rawAction = (try? c.decode(String.self, forKey: .actionType)) ?? "paste"
        actionType = ActionType(rawValue: rawAction) ?? .paste
    }
}

// MARK: - 错误处理

struct APIErrorResponse: Decodable {
    let code: String
    let message: String
    let configUpdate: ConfigUpdatePayload?

    enum CodingKeys: String, CodingKey {
        case code, message
        case configUpdate = "config_update"
    }
}

enum APIError: LocalizedError {
    case httpError(Int, String, APIErrorResponse?)
    case decodingError(Error)
    case networkError(Error)
    case unauthorized
    case userBanned
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .httpError(_, _, let resp):
            if let code = resp?.code {
                return L10n.errorForCode(code) ?? resp?.message ?? L10n.errorUnknown
            }
            return resp?.message ?? L10n.errorUnknown
        case .decodingError: return L10n.errorDecoding
        case .networkError: return L10n.errorNetwork
        case .unauthorized: return L10n.errorUnauthorized
        case .userBanned: return L10n.errorUserBanned
        case .notLoggedIn: return L10n.errorNotLoggedIn
        }
    }

    var errorCode: String? {
        if case .httpError(_, _, let resp) = self { return resp?.code }
        return nil
    }

    var configUpdate: ConfigUpdatePayload? {
        if case .httpError(_, _, let resp) = self { return resp?.configUpdate }
        return nil
    }

    var isCreditsExhausted: Bool { errorCode == "CREDITS_EXHAUSTED" }
    var isNonRetryable: Bool { errorCode == "DURATION_EXCEEDED" }
}

struct EmptyResponse: Decodable {}

// MARK: - 录音配置

struct RecordingConfigResponse: Decodable {
    let maxDurationSec: Int

    enum CodingKeys: String, CodingKey {
        case maxDurationSec = "max_duration_sec"
    }
}

// MARK: - 词典（热词）

struct HotWordItem: Codable, Identifiable {
    let id: String
    var word: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, word
        case createdAt = "created_at"
    }
}

struct HotWordCreateBody: Encodable { let word: String }
struct HotWordUpdateBody: Encodable { let word: String }
struct HotWordListResponse: Decodable { let hotwords: [HotWordItem] }

// MARK: - 人设配置

let personaPromptMaxLength = 4000
let personaNameMaxLength   = 60
let personaDescMaxLength   = 200
let personaMaxCount        = 10

struct PersonaPrompts: Codable {
    var transcribePrompt: String?
    var transcribeEnabled: Bool
    var rewritePrompt: String?
    var rewriteEnabled: Bool
    var intentHint: String?
    var intentEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case transcribePrompt  = "transcribe_prompt"
        case transcribeEnabled = "transcribe_enabled"
        case rewritePrompt     = "rewrite_prompt"
        case rewriteEnabled    = "rewrite_enabled"
        case intentHint        = "intent_hint"
        case intentEnabled     = "intent_enabled"
    }

    init(
        transcribePrompt: String? = nil, transcribeEnabled: Bool = false,
        rewritePrompt: String? = nil, rewriteEnabled: Bool = false,
        intentHint: String? = nil, intentEnabled: Bool = false
    ) {
        self.transcribePrompt  = transcribePrompt
        self.transcribeEnabled = transcribeEnabled
        self.rewritePrompt     = rewritePrompt
        self.rewriteEnabled    = rewriteEnabled
        self.intentHint        = intentHint
        self.intentEnabled     = intentEnabled
    }
}

struct PersonaItem: Codable, Identifiable {
    let id: String
    var name: String
    var description: String?
    var isActive: Bool
    var isBuiltin: Bool
    var prompts: PersonaPrompts

    enum CodingKeys: String, CodingKey {
        case id, name, description, prompts
        case isActive = "is_active"
        case isBuiltin = "is_builtin"
    }

    init(
        id: String = UUID().uuidString, name: String = "",
        description: String? = nil, isActive: Bool = false,
        isBuiltin: Bool = false,
        prompts: PersonaPrompts = PersonaPrompts()
    ) {
        self.id = id; self.name = name; self.description = description
        self.isActive = isActive; self.isBuiltin = isBuiltin
        self.prompts = prompts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try? c.decode(String.self, forKey: .description)
        isActive = (try? c.decode(Bool.self, forKey: .isActive)) ?? false
        isBuiltin = (try? c.decode(Bool.self, forKey: .isBuiltin)) ?? false
        prompts = (try? c.decode(PersonaPrompts.self, forKey: .prompts)) ?? PersonaPrompts()
    }
}

struct PersonaListResponse: Decodable { let personas: [PersonaItem] }
struct PersonaCreateBody: Encodable { let name: String; let description: String?; let prompts: PersonaPrompts }
struct PersonaUpdateBody: Encodable { let name: String?; let description: String?; let prompts: PersonaPrompts? }

// MARK: - 协议

struct AgreementItem: Decodable, Identifiable {
    let id: String
    let type: String
    let title: String
    let content: String
    let version: String
}

struct AgreementsResponse: Decodable {
    let agreements: [AgreementItem]
}
