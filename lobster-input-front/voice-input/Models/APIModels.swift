/// APIModels.swift
/// API 请求/响应数据模型定义。
/// 包含认证（验证码登录）、音频处理、错误响应三组模型。
/// CodingKeys 用于 snake_case ↔ camelCase 转换。
import Foundation

// MARK: - 认证

/// 发送验证码请求
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
        case deviceId            = "device_id"
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

/// 新用户提交邀请码请求体
struct VerifyInviteRequest: Encodable {
    let email: String
    let inviteCode: String
    let deviceId: String
    let hardwareFingerprint: String

    enum CodingKeys: String, CodingKey {
        case email
        case inviteCode          = "invite_code"
        case deviceId            = "device_id"
        case hardwareFingerprint = "hardware_fingerprint"
    }
}

/// 单条邀请码信息（后端无 id 字段，用 code 作为唯一标识）
struct InviteCodeItem: Decodable, Identifiable {
    var id: String { code }
    let code: String
    let isUsed: Bool
    let usedBy: String?
    let usedAt: String?

    enum CodingKeys: String, CodingKey {
        case code
        case isUsed  = "is_used"
        case usedBy  = "used_by"
        case usedAt  = "used_at"
    }
}

struct MyInviteCodesResponse: Decodable {
    let inviteCodes: [InviteCodeItem]

    enum CodingKeys: String, CodingKey {
        case inviteCodes = "invite_codes"
    }
}

// MARK: - 套餐积分

/// 有效积分明细项
struct CreditBalanceItem: Decodable, Identifiable {
    let id: String
    let type: String
    let source: String
    let label: String
    let creditsTotal: Int
    let creditsUsed: Int
    let creditsRemaining: Int
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, source, label
        case creditsTotal = "credits_total"
        case creditsUsed = "credits_used"
        case creditsRemaining = "credits_remaining"
        case expiresAt = "expires_at"
    }
}

/// 用户套餐积分信息
struct UserPlanInfo: Decodable {
    let tier: String
    /// 后端本地化套餐展示名（按 X-Accept-Language 返回）；为空时客户端回退本地翻译
    let planName: String
    let creditsTotal: Int
    let creditsUsed: Int
    let creditsRemaining: Int
    let creditItems: [CreditBalanceItem]
    /// 下次积分重置时间（UTC ISO8601 字符串）
    let creditsResetAt: String?
    /// 注册总开关（关闭后新用户无法注册，老用户登录不受影响）
    let registrationEnabled: Bool
    /// 邀请码注册功能是否开启（控制注册流程）
    let inviteCodeEnabled: Bool
    /// 客户端是否显示邀请码查看入口（独立于注册开关）
    let showInviteCodesEnabled: Bool
    let showSubscriptionModuleEnabled: Bool
    /// 订阅是否处于自动续费状态
    let autoRenew: Bool
    /// 下次自动续费时间（UTC ISO8601 字符串，autoRenew 时为订阅到期时间）
    let nextRenewalAt: String?
    /// 是否可在客户端内取消自动续费（false 表示由订阅设备的应用商店管理）
    let renewalCancellable: Bool

    enum CodingKeys: String, CodingKey {
        case tier
        case planName               = "plan_name"
        case creditsTotal           = "credits_total"
        case creditsUsed            = "credits_used"
        case creditsRemaining       = "credits_remaining"
        case creditItems            = "credit_items"
        case creditsResetAt         = "credits_reset_at"
        case registrationEnabled    = "registration_enabled"
        case inviteCodeEnabled      = "invite_code_enabled"
        case showInviteCodesEnabled = "show_invite_codes_enabled"
        case showSubscriptionModuleEnabled = "show_subscription_module_enabled"
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
        creditItems             = (try? c.decode([CreditBalanceItem].self, forKey: .creditItems)) ?? []
        creditsResetAt          = try? c.decode(String.self, forKey: .creditsResetAt)
        registrationEnabled     = (try? c.decode(Bool.self, forKey: .registrationEnabled)) ?? true
        inviteCodeEnabled       = (try? c.decode(Bool.self, forKey: .inviteCodeEnabled)) ?? false
        showInviteCodesEnabled  = (try? c.decode(Bool.self, forKey: .showInviteCodesEnabled)) ?? false
        showSubscriptionModuleEnabled = (try? c.decode(Bool.self, forKey: .showSubscriptionModuleEnabled)) ?? true
        autoRenew               = (try? c.decode(Bool.self, forKey: .autoRenew)) ?? false
        nextRenewalAt           = try? c.decode(String.self, forKey: .nextRenewalAt)
        renewalCancellable      = (try? c.decode(Bool.self, forKey: .renewalCancellable)) ?? false
    }
}

// MARK: - App 启动配置

/// App 启动时拉取的全局配置（无需鉴权）
struct AppStartupConfig: Decodable {
    let registrationEnabled: Bool
    let inviteCodeEnabled: Bool
    let showInviteCodesEnabled: Bool
    let showSubscriptionModuleEnabled: Bool
    let registrationLimitEnabled: Bool
    let registrationLimitCount: Int

    enum CodingKeys: String, CodingKey {
        case registrationEnabled     = "registration_enabled"
        case inviteCodeEnabled        = "invite_code_enabled"
        case showInviteCodesEnabled   = "show_invite_codes_enabled"
        case showSubscriptionModuleEnabled = "show_subscription_module_enabled"
        case registrationLimitEnabled = "registration_limit_enabled"
        case registrationLimitCount   = "registration_limit_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        registrationEnabled     = (try? c.decode(Bool.self, forKey: .registrationEnabled)) ?? true
        inviteCodeEnabled        = (try? c.decode(Bool.self, forKey: .inviteCodeEnabled)) ?? true
        showInviteCodesEnabled   = (try? c.decode(Bool.self, forKey: .showInviteCodesEnabled)) ?? false
        showSubscriptionModuleEnabled = (try? c.decode(Bool.self, forKey: .showSubscriptionModuleEnabled)) ?? true
        registrationLimitEnabled = (try? c.decode(Bool.self, forKey: .registrationLimitEnabled)) ?? false
        registrationLimitCount   = (try? c.decode(Int.self, forKey: .registrationLimitCount)) ?? 1000
    }
}

// MARK: - Payments

struct PaymentCatalogResponse: Decodable {
    let activeProvider: String
    let providers: [PaymentProvider]
    let paymentMethods: [PaymentMethod]
    let subscriptionModule: SubscriptionModuleState
    let currentPlan: PaymentCurrentPlan
    let subscriptions: [PaymentSubscriptionPlan]
    let creditsTopup: PaymentCreditsTopup
    let discount: PaymentDiscount

    enum CodingKeys: String, CodingKey {
        case providers, subscriptions, discount
        case activeProvider = "active_provider"
        case paymentMethods = "payment_methods"
        case subscriptionModule = "subscription_module"
        case currentPlan = "current_plan"
        case creditsTopup = "credits_topup"
    }
}

struct PaymentProvider: Decodable, Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let status: String?
}

struct PaymentMethod: Decodable, Identifiable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    let description: String?
    let enabled: Bool?
    let sortOrder: Int?
    let currencies: [String]?

    enum CodingKeys: String, CodingKey {
        case code, name, description, enabled, currencies
        case sortOrder = "sort_order"
    }
}

struct SubscriptionModuleState: Decodable {
    let enabled: Bool
}

struct PaymentCurrentPlan: Decodable {
    let planCode: String
    let billingCycle: String?
    let planCreditsTotal: Int
    let planCreditsUsed: Int
    let planCreditsRemaining: Int
    let paid: Bool
    let paidTopupEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case paid
        case planCode = "plan_code"
        case billingCycle = "billing_cycle"
        case planCreditsTotal = "plan_credits_total"
        case planCreditsUsed = "plan_credits_used"
        case planCreditsRemaining = "plan_credits_remaining"
        case paidTopupEnabled = "paid_topup_enabled"
    }
}

struct PaymentSubscriptionPlan: Decodable, Identifiable {
    var id: String { planCode }
    let type: String
    let planCode: String
    let name: String
    let credits: Int
    let rank: Int
    let billingOptions: [PaymentBillingOption]

    enum CodingKeys: String, CodingKey {
        case type, name, credits, rank
        case planCode = "plan_code"
        case billingOptions = "billing_options"
    }
}

struct PaymentBillingOption: Decodable, Identifiable {
    var id: String { cycle }
    let cycle: String
    let productCode: String?
    let priceCents: Int
    let payablePriceCents: Int?
    let settlementMode: String?
    let upgradeCreditCents: Int?
    let purchasable: Bool?
    let blockedReason: String?
    let currency: String?
    let paymentMethods: [PaymentMethod]?
    let durationPeriod: String?
    let durationCount: Int

    enum CodingKeys: String, CodingKey {
        case cycle, currency, purchasable
        case paymentMethods = "payment_methods"
        case productCode = "product_code"
        case priceCents = "price_cents"
        case payablePriceCents = "payable_price_cents"
        case settlementMode = "settlement_mode"
        case upgradeCreditCents = "upgrade_credit_cents"
        case blockedReason = "blocked_reason"
        case durationPeriod = "duration_period"
        case durationCount = "duration_count"
    }

    /// 实际应付金额(升级时为补差价),旧后端无此字段时回退目录价
    var effectivePriceCents: Int { payablePriceCents ?? priceCents }
    /// 是否为补差价升级选项
    var isProratedUpgrade: Bool {
        settlementMode == "prorated_difference" && effectivePriceCents < priceCents
    }
}

struct PaymentCreditsTopup: Decodable {
    let type: String
    let provider: String
    let productCode: String?
    let enabled: Bool
    let available: Bool
    let amount: Int?
    let priceCents: Int?
    let currency: String?
    let paymentMethods: [PaymentMethod]?
    let blockedReason: String?

    enum CodingKeys: String, CodingKey {
        case type, provider, enabled, available, amount, currency
        case paymentMethods = "payment_methods"
        case productCode = "product_code"
        case priceCents = "price_cents"
        case blockedReason = "blocked_reason"
    }
}

struct PaymentDiscount: Decodable {
    let supported: Bool
    let defaultEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case supported
        case defaultEnabled = "default_enabled"
    }
}

struct CreateSubscriptionCheckoutBody: Encodable {
    let planCode: String
    let billingCycle: String
    let autoRenew: Bool
    let provider: String
    let productCode: String
    let paymentMethod: String
    let currency: String
    let settlementMode: String
    let discountCode: String

    enum CodingKeys: String, CodingKey {
        case provider
        case planCode = "plan_code"
        case billingCycle = "billing_cycle"
        case autoRenew = "auto_renew"
        case productCode = "product_code"
        case paymentMethod = "payment_method"
        case currency
        case settlementMode = "settlement_mode"
        case discountCode = "discount_code"
    }
}

struct CreateCreditsTopupCheckoutBody: Encodable {
    let provider: String
    let productCode: String
    let paymentMethod: String
    let currency: String
    let discountCode: String

    enum CodingKeys: String, CodingKey {
        case provider, currency
        case productCode = "product_code"
        case paymentMethod = "payment_method"
        case discountCode = "discount_code"
    }
}

/// 取消订阅自动续费响应
struct SubscriptionCancelRenewalResponse: Decodable {
    /// cancelled / already_cancelled / apple_managed
    let status: String
    /// 取消后套餐仍可使用至该时间（UTC ISO8601 字符串）
    let effectiveUntil: String?

    enum CodingKeys: String, CodingKey {
        case status
        case effectiveUntil = "effective_until"
    }
}

struct PaymentCheckoutResponse: Decodable {
    let provider: String
    let requestId: String?
    let checkoutId: String?
    let checkoutURL: String
    let status: String?

    enum CodingKeys: String, CodingKey {
        case provider, status
        case requestId = "request_id"
        case checkoutId = "checkout_id"
        case checkoutURL = "checkout_url"
    }
}

// MARK: - 音频处理

/// 后端返回的操作类型，客户端据此决定如何消费 result 字段
enum ActionType: String, Decodable {
    case paste = "paste"                    // 写入剪贴板 + 自动粘贴到目标输入框
    case clarify = "clarify"                // LLM 意图不明，显示询问浮窗，result 为原选中文本不变
    case showMarkdown = "show_markdown"     // 拉起悬浮窗展示 Markdown 格式内容（搜索结果等），不写入输入框
    case tip = "tip"                        // 居中下方短暂 tip 提示（4秒自动消失），result 为提示文案
    // OpenClaw 系列：
    case openclawExecute = "openclaw_execute"              // 自然语言任务 → Gateway RPC sessions.send
    case openclawSlashCommand = "openclaw_slash_command"   // slash 命令（/stop 等）→ Gateway RPC / sessions.abort
    case openclawCliCommand = "openclaw_cli_command"       // 无交互 CLI 命令 → 复用 openclaw 专属终端
    case openclawInteractive = "openclaw_interactive"      // 交互式 CLI 命令 → 新建独立终端（用户交互）
    // 预留扩展:
    // case replace = "replace"             // 替换选中文本
    // case execute = "execute"             // 执行系统命令
    // case navigate = "navigate"           // 打开 URL
}

/// 后端配置变更通知，客户端收到后覆盖本地缓存
struct ConfigUpdatePayload: Decodable {
    let maxDurationSec: Int?

    enum CodingKeys: String, CodingKey {
        case maxDurationSec = "max_duration_sec"
    }
}

/// 音频处理接口响应体
struct AudioProcessResponse: Decodable {
    let operation: String
    let actionType: ActionType
    let transcript: String
    let result: String
    let modelProvider: String?
    let modelName: String?
    let warning: String?
    let configUpdate: ConfigUpdatePayload?
    let clarifyQuestion: String?  // 仅 actionType == .clarify 时有值，LLM 生成的询问文案
    let creditsRemaining: Int?    // 本次操作后的剩余积分
    let asrResolutionSource: String?
    let agentIntent: String?

    enum CodingKeys: String, CodingKey {
        case operation, transcript, result, warning
        case actionType = "action_type"
        case modelProvider = "model_provider"
        case modelName = "model_name"
        case configUpdate = "config_update"
        case clarifyQuestion = "clarify_question"
        case creditsRemaining = "credits_remaining"
        case asrResolutionSource = "asr_resolution_source"
        case agentIntent = "agent_intent"
    }
}

/// v2 文本处理请求：客户端实时 ASR 完成后把最终文本交给后端业务管线。
struct TextProcessRequest: Encodable {
    let operation: String
    let text: String
    let clientASRText: String?
    let asrSessionID: String?
    let selectedText: String?
    let clipboardHistory: [String]?
    let clipboardItems: [ClipboardContextItem]?
    let provider: String?
    let model: String?
    let openclawStatus: String?
    let openclawSessionActive: Bool
    let fastMode: Bool
    let transcriptLanguage: String?

    enum CodingKeys: String, CodingKey {
        case operation, text, provider, model
        case clientASRText = "client_asr_text"
        case asrSessionID = "asr_session_id"
        case selectedText = "selected_text"
        case clipboardHistory = "clipboard_history"
        case clipboardItems = "clipboard_items"
        case openclawStatus = "openclaw_status"
        case openclawSessionActive = "openclaw_session_active"
        case fastMode = "fast_mode"
        case transcriptLanguage = "transcript_language"
    }
}

// MARK: - 错误处理

/// 后端错误响应体（用于解析错误消息和附带数据）
struct APIErrorResponse: Decodable {
    let code: String
    let message: String
    let configUpdate: ConfigUpdatePayload?

    enum CodingKeys: String, CodingKey {
        case code, message
        case configUpdate = "config_update"
    }
}

/// API 调用错误枚举，提供本地化错误描述
enum APIError: LocalizedError {
    case httpError(Int, String, APIErrorResponse?)
    case decodingError(Error)
    case networkError(Error)
    case unauthorized
    case userBanned

    var errorDescription: String? {
        switch self {
        case .httpError(_, _, let resp):
            guard let code = resp?.code else { return L10n.errorUnknown }
            return L10n.errorForCode(code)
        case .decodingError: return L10n.errorDecode
        case .networkError: return L10n.errorNetwork
        case .unauthorized: return L10n.errorUnauthorized
        case .userBanned: return L10n.errorForCode("USER_BANNED")
        }
    }

    /// 后端错误码（如 DURATION_EXCEEDED），用于客户端判断错误类型
    var errorCode: String? {
        if case .httpError(_, _, let resp) = self { return resp?.code }
        return nil
    }

    /// 错误响应中附带的配置变更
    var configUpdate: ConfigUpdatePayload? {
        if case .httpError(_, _, let resp) = self { return resp?.configUpdate }
        return nil
    }

    /// 是否为不可重试的前置校验错误（如时长超限）
    var isNonRetryable: Bool {
        errorCode == "DURATION_EXCEEDED"
    }

    var isCreditsExhausted: Bool {
        errorCode == "CREDITS_EXHAUSTED"
    }

    /// 是否需要强制退出登录（401 未授权 或 403 用户被禁用）
    var requiresLogout: Bool {
        switch self {
        case .unauthorized, .userBanned: return true
        default: return false
        }
    }
}

// MARK: - 录音配置

/// 后端返回的录音相关配置
struct RecordingConfigResponse: Decodable {
    let maxDurationSec: Int

    enum CodingKeys: String, CodingKey {
        case maxDurationSec = "max_duration_sec"
    }
}

// MARK: - 词典（热词）

/// 热词条目（专有名词表，只需标准词）
struct HotWordItem: Codable, Identifiable {
    let id: String
    var word: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, word
        case createdAt = "created_at"
    }
}

struct HotWordCreateBody: Encodable {
    let word: String
}

struct HotWordUpdateBody: Encodable {
    let word: String
}

struct HotWordListResponse: Decodable {
    let hotwords: [HotWordItem]
    let total: Int
    let page: Int
    let pageSize: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case hotwords, total, page
        case pageSize = "page_size"
        case hasMore  = "has_more"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotwords = try c.decode([HotWordItem].self, forKey: .hotwords)
        total    = (try? c.decode(Int.self, forKey: .total))    ?? 0
        page     = (try? c.decode(Int.self, forKey: .page))     ?? 1
        pageSize = (try? c.decode(Int.self, forKey: .pageSize)) ?? 50
        hasMore  = (try? c.decode(Bool.self, forKey: .hasMore)) ?? false
    }
}

// MARK: - 人设配置

/// 人设字段最大长度（与后端保持一致）
let personaPromptMaxLength  = 4000
let personaNameMaxLength    = 60
let personaDescMaxLength    = 200
let personaMaxCount         = 10

/// 三模块提示词配置（嵌套在 PersonaItem 中）
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
        rewritePrompt: String? = nil,    rewriteEnabled: Bool = false,
        intentHint: String? = nil,       intentEnabled: Bool = false
    ) {
        self.transcribePrompt  = transcribePrompt
        self.transcribeEnabled = transcribeEnabled
        self.rewritePrompt     = rewritePrompt
        self.rewriteEnabled    = rewriteEnabled
        self.intentHint        = intentHint
        self.intentEnabled     = intentEnabled
    }
}

/// 单条人设完整数据
struct PersonaItem: Codable, Identifiable {
    let id: String
    var name: String
    var description: String?
    var isActive: Bool
    var isBuiltin: Bool
    var prompts: PersonaPrompts

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case name, description, prompts
        case isActive = "is_active"
        case isBuiltin = "is_builtin"
    }

    init(
        id: String = UUID().uuidString,
        name: String = "",
        description: String? = nil,
        isActive: Bool = false,
        isBuiltin: Bool = false,
        prompts: PersonaPrompts = PersonaPrompts()
    ) {
        self.id          = id
        self.name        = name
        self.description = description
        self.isActive    = isActive
        self.isBuiltin   = isBuiltin
        self.prompts     = prompts
    }
}

struct PersonaListResponse: Decodable {
    let personas: [PersonaItem]
}

/// 新建人设请求体
struct PersonaCreateBody: Encodable {
    let name: String
    let description: String?
    let prompts: PersonaPrompts
}

/// 更新人设请求体（所有字段可选）
struct PersonaUpdateBody: Encodable {
    let name: String?
    let description: String?
    let prompts: PersonaPrompts?
}
