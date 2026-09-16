/// AuthStore.swift
/// 登录态管理（单例）。JWT Token 存于 Keychain（加密、不进 plist/Time Machine 明文备份），
/// 邮箱、用户等级等非凭证字段仍用 UserDefaults 持久化。
import Foundation
import Combine

final class AuthStore: ObservableObject {

    static let shared = AuthStore()

    /// Keychain 中 token 条目的 account
    private static let tokenKeychainKey = "auth_token"

    private init() {
        // 从未上线、一直是测试版，不做老数据迁移：直接清除旧版残留的明文 token，
        // 老用户 token 不在 Keychain 中即处于登出态，重新登录即可。
        UserDefaults.standard.removeObject(forKey: "auth_token")
        token = KeychainStore.get(Self.tokenKeychainKey)
        email = UserDefaults.standard.string(forKey: "auth_email")
        tier = UserDefaults.standard.string(forKey: "auth_tier") ?? "trial"
        planName = UserDefaults.standard.string(forKey: "auth_plan_name") ?? ""
        creditsTotal     = UserDefaults.standard.integer(forKey: "auth_credits_total")
        creditsUsed      = UserDefaults.standard.integer(forKey: "auth_credits_used")
        creditsRemaining = UserDefaults.standard.integer(forKey: "auth_credits_remaining")
        creditsResetAt   = UserDefaults.standard.string(forKey: "auth_credits_reset_at")
        registrationEnabled = UserDefaults.standard.object(forKey: "app_registration_enabled") as? Bool ?? true
        inviteCodeEnabled = UserDefaults.standard.object(forKey: "app_invite_code_enabled") as? Bool ?? false
        showInviteCodesEnabled = UserDefaults.standard.object(forKey: "app_show_invite_codes_enabled") as? Bool ?? false
        showSubscriptionModuleEnabled = UserDefaults.standard.object(forKey: "app_show_subscription_module_enabled") as? Bool ?? true
    }

    @Published var token: String? {
        didSet { KeychainStore.set(token, for: Self.tokenKeychainKey) }
    }
    @Published var email: String? {
        didSet { UserDefaults.standard.set(email, forKey: "auth_email") }
    }
    @Published var tier: String = "trial" {
        didSet { UserDefaults.standard.set(tier, forKey: "auth_tier") }
    }
    /// 后端本地化套餐展示名（按 X-Accept-Language 返回）；为空回退客户端本地翻译
    @Published var planName: String = "" {
        didSet { UserDefaults.standard.set(planName, forKey: "auth_plan_name") }
    }
    /// 展示用套餐名：优先后端本地化 planName，为空回退客户端本地翻译（套餐文案统一后端管理）
    var displayPlanName: String { planName.isEmpty ? localizedPlanName(tier) : planName }

    /// 套餐总积分额度
    @Published var creditsTotal: Int = 0 {
        didSet { UserDefaults.standard.set(creditsTotal, forKey: "auth_credits_total") }
    }
    /// 当前所有有效积分已使用量
    @Published var creditsUsed: Int = 0 {
        didSet { UserDefaults.standard.set(creditsUsed, forKey: "auth_credits_used") }
    }
    /// 本周期剩余积分
    @Published var creditsRemaining: Int = 0 {
        didSet { UserDefaults.standard.set(creditsRemaining, forKey: "auth_credits_remaining") }
    }
    /// 所有有效积分明细，登录后从服务端刷新。
    @Published var creditItems: [CreditBalanceItem] = []
    /// 下次积分重置时间（ISO8601 UTC 字符串，用于显示到期日期）
    @Published var creditsResetAt: String? = nil {
        didSet { UserDefaults.standard.set(creditsResetAt, forKey: "auth_credits_reset_at") }
    }

    /// 注册总开关（关闭后新用户无法注册，老用户登录不受影响）
    @Published var registrationEnabled: Bool = true {
        didSet { UserDefaults.standard.set(registrationEnabled, forKey: "app_registration_enabled") }
    }

    /// 邀请码注册功能是否开启（控制注册流程是否需要邀请码）
    @Published var inviteCodeEnabled: Bool = false {
        didSet { UserDefaults.standard.set(inviteCodeEnabled, forKey: "app_invite_code_enabled") }
    }

    /// 客户端是否显示邀请码查看入口（独立于注册开关，控制账号面板邀请码按钮）
    @Published var showInviteCodesEnabled: Bool = false {
        didSet { UserDefaults.standard.set(showInviteCodesEnabled, forKey: "app_show_invite_codes_enabled") }
    }

    /// 客户端是否显示订阅模块入口
    @Published var showSubscriptionModuleEnabled: Bool = true {
        didSet { UserDefaults.standard.set(showSubscriptionModuleEnabled, forKey: "app_show_subscription_module_enabled") }
    }

    /// 订阅是否处于自动续费状态（登录后从服务端刷新，不做本地持久化）
    @Published var autoRenew: Bool = false
    /// 下次自动续费时间（ISO8601 UTC 字符串，autoRenew 时为订阅到期时间）
    @Published var nextRenewalAt: String? = nil
    /// 是否可在客户端内取消自动续费（false 表示由订阅设备的应用商店管理）
    @Published var renewalCancellable: Bool = false

    /// 新用户注册中间态：验证码通过但尚未完成邀请码填写，临时保存邮箱
    @Published var pendingInviteEmail: String? = nil

    var isLoggedIn: Bool { token != nil }

    /// 将 ISO8601 UTC 字符串格式化为本地化日期字符串（仅年月日）
    func formattedResetDate(locale: Locale = .current) -> String? {
        guard let raw = creditsResetAt else { return nil }
        return Self.formatUTCDateString(raw, locale: locale)
    }

    /// 将下次自动续费时间格式化为本地化日期字符串（仅年月日）
    func formattedNextRenewalDate(locale: Locale = .current) -> String? {
        guard let raw = nextRenewalAt else { return nil }
        return Self.formatUTCDateString(raw, locale: locale)
    }

    /// 将 ISO8601 / 常见 UTC 日期字符串解析后按本地化格式输出（仅年月日）
    static func formatUTCDateString(_ raw: String, locale: Locale = .current) -> String? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = isoFormatter.date(from: raw)
        if date == nil {
            isoFormatter.formatOptions = [.withInternetDateTime]
            date = isoFormatter.date(from: raw)
        }
        if date == nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
                formatter.dateFormat = format
                date = formatter.date(from: raw)
                if date != nil { break }
            }
        }
        guard let d = date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: d)
    }

    /// 登录成功后调用。账号数据采用异步加载，避免登录后首帧 UI 被历史文件 I/O 阻塞。
    @MainActor
    func save(_ response: AuthResponse) {
        email = response.email.isEmpty ? nil : response.email
        tier = response.tier.isEmpty ? "trial" : response.tier
        HistoryStore.shared.reloadForCurrentUser()
        HotKeyManager.shared.reloadForCurrentUser()
        token = response.token.isEmpty ? nil : response.token
    }

    /// 登录后更新套餐积分信息（含邀请码开关）
    @MainActor
    func updatePlanInfo(_ info: UserPlanInfo) {
        creditsTotal           = info.creditsTotal
        creditsUsed            = info.creditsUsed
        creditsRemaining       = info.creditsRemaining
        creditItems            = info.creditItems
        creditsResetAt         = info.creditsResetAt
        registrationEnabled    = info.registrationEnabled
        inviteCodeEnabled      = info.inviteCodeEnabled
        showInviteCodesEnabled = info.showInviteCodesEnabled
        showSubscriptionModuleEnabled = info.showSubscriptionModuleEnabled
        autoRenew              = info.autoRenew
        nextRenewalAt          = info.nextRenewalAt
        renewalCancellable     = info.renewalCancellable
        if !info.tier.isEmpty {
            tier = info.tier
        }
        planName = info.planName
    }

    /// 更新 app 启动配置
    @MainActor
    func updateStartupConfig(_ config: AppStartupConfig) {
        registrationEnabled    = config.registrationEnabled
        inviteCodeEnabled      = config.inviteCodeEnabled
        showInviteCodesEnabled = config.showInviteCodesEnabled
        showSubscriptionModuleEnabled = config.showSubscriptionModuleEnabled
    }

    /// 退出登录。先同步清空所有账号数据，最后清除 token/email，
    /// 确保 UI 切换到登录界面时已是干净的默认状态。
    @MainActor
    func logout() {
        // 先同步重置所有账号相关状态，再清除 token，UI 切换时已是干净的默认状态
        HistoryStore.shared.clearMemory()
        // 全局快捷键是 App 级生命周期，退出登录和 token 过期不能停止监听。
        // 未登录状态由快捷键处理入口拦截，否则后端 401 会让 Carbon 注册表失效到用户重新设置快捷键才恢复。
        RecordingResultStore.shared.clear()
        token = nil
        email = nil
        tier = "trial"
        creditsTotal = 0
        creditsUsed = 0
        creditsRemaining = 0
        creditItems = []
        creditsResetAt = nil
        autoRenew = false
        nextRenewalAt = nil
        renewalCancellable = false
        pendingInviteEmail = nil
    }

    func clearPendingInvite() {
        pendingInviteEmail = nil
    }
}
