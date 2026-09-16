import Foundation
import Combine
import CryptoKit
import UIKit

@MainActor
final class AuthStore: ObservableObject {

    static let shared = AuthStore()

    private let defaults: UserDefaults

    private init() {
        let defaults = UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard
        self.defaults = defaults

        // 从未上线、一直是测试版，不迁移老数据：清除旧版残留的明文 token，
        // token 不在共享 Keychain 中即处于登出态，重新登录即可。
        defaults.removeObject(forKey: Keys.token)
        self._token = Published(wrappedValue: KeychainTokenStore.get())
        self._email = Published(wrappedValue: defaults.string(forKey: Keys.email))
        self._tier = Published(wrappedValue: defaults.string(forKey: Keys.tier) ?? "none")
        self._planName = Published(wrappedValue: defaults.string(forKey: Keys.planName) ?? "")
        self._creditsTotal = Published(wrappedValue: defaults.integer(forKey: Keys.creditsTotal))
        self._creditsUsed = Published(wrappedValue: defaults.integer(forKey: Keys.creditsUsed))
        self._creditsRemaining = Published(wrappedValue: defaults.integer(forKey: Keys.creditsRemaining))
        self._creditsResetAt = Published(wrappedValue: defaults.string(forKey: Keys.creditsResetAt))
        self._planExpiresAt = Published(wrappedValue: defaults.string(forKey: Keys.planExpiresAt))
        self._subscriptionExpiresAt = Published(wrappedValue: defaults.string(forKey: Keys.subscriptionExpiresAt))
        self._autoRenew = Published(wrappedValue: defaults.bool(forKey: Keys.autoRenew))
        self._nextRenewalAt = Published(wrappedValue: defaults.string(forKey: Keys.nextRenewalAt))
        self._renewalCancellable = Published(wrappedValue: defaults.bool(forKey: Keys.renewalCancellable))
        self._registrationEnabled = Published(wrappedValue: defaults.object(forKey: Keys.registrationEnabled) as? Bool ?? true)
        self._inviteCodeEnabled = Published(wrappedValue: defaults.bool(forKey: Keys.inviteCodeEnabled))
        self._showInviteCodesEnabled = Published(wrappedValue: defaults.bool(forKey: Keys.showInviteCodesEnabled))
    }

    private enum Keys {
        static let token = "auth_token"
        static let email = "auth_email"
        static let tier  = "auth_tier"
        static let planName = "auth_plan_name"
        static let creditsTotal = "credits_total"
        static let creditsUsed = "credits_used"
        static let creditsRemaining = "credits_remaining"
        static let creditsResetAt = "credits_reset_at"
        static let planExpiresAt = "plan_expires_at"
        static let subscriptionExpiresAt = "subscription_expires_at"
        static let autoRenew = "auto_renew"
        static let nextRenewalAt = "next_renewal_at"
        static let renewalCancellable = "renewal_cancellable"
        static let registrationEnabled = "registration_enabled"
        static let inviteCodeEnabled = "invite_code_enabled"
        static let showInviteCodesEnabled = "show_invite_codes_enabled"
        static let deviceFallback = "device_fallback_id"
    }

    @Published private(set) var token: String? {
        // token 持久化到共享 Keychain（而非明文 App Group UserDefaults）。
        // 内存中由 @Published 缓存，键盘扩展通过同一共享 Keychain access group 读取。
        didSet { KeychainTokenStore.set(token) }
    }

    @Published private(set) var email: String? {
        didSet { defaults.set(email, forKey: Keys.email) }
    }

    @Published private(set) var tier: String = "none" {
        didSet { defaults.set(tier, forKey: Keys.tier) }
    }
    /// 后端本地化套餐名(套餐文案统一后端管理);切换语言后 refreshPlanInfo 会更新
    @Published private(set) var planName: String = "" {
        didSet { defaults.set(planName, forKey: Keys.planName) }
    }

    @Published var creditsTotal: Int = 0 {
        didSet { defaults.set(creditsTotal, forKey: Keys.creditsTotal) }
    }

    @Published var creditsUsed: Int = 0 {
        didSet { defaults.set(creditsUsed, forKey: Keys.creditsUsed) }
    }

    @Published var creditsRemaining: Int = 0 {
        didSet { defaults.set(creditsRemaining, forKey: Keys.creditsRemaining) }
    }

    /// 下次积分重置时间（UTC ISO8601 字符串）
    @Published var creditsResetAt: String? = nil {
        didSet { defaults.set(creditsResetAt, forKey: Keys.creditsResetAt) }
    }

    /// 当前套餐到期时间（UTC ISO8601 字符串），免费/永久套餐为空
    @Published var planExpiresAt: String? = nil {
        didSet { defaults.set(planExpiresAt, forKey: Keys.planExpiresAt) }
    }

    /// 当前订阅到期时间（UTC ISO8601 字符串），免费套餐可能为空
    @Published var subscriptionExpiresAt: String? = nil {
        didSet { defaults.set(subscriptionExpiresAt, forKey: Keys.subscriptionExpiresAt) }
    }

    /// 订阅是否处于自动续费状态
    @Published var autoRenew: Bool = false {
        didSet { defaults.set(autoRenew, forKey: Keys.autoRenew) }
    }

    /// 下次自动续费时间（UTC ISO8601 字符串），非自动续费为空
    @Published var nextRenewalAt: String? = nil {
        didSet { defaults.set(nextRenewalAt, forKey: Keys.nextRenewalAt) }
    }

    /// 是否可在客户端内取消自动续费（Apple IAP 订阅恒为 false）
    @Published var renewalCancellable: Bool = false {
        didSet { defaults.set(renewalCancellable, forKey: Keys.renewalCancellable) }
    }

    @Published var registrationEnabled: Bool = true {
        didSet { defaults.set(registrationEnabled, forKey: Keys.registrationEnabled) }
    }

    @Published var inviteCodeEnabled: Bool = false {
        didSet { defaults.set(inviteCodeEnabled, forKey: Keys.inviteCodeEnabled) }
    }

    @Published var showInviteCodesEnabled: Bool = false {
        didSet { defaults.set(showInviteCodesEnabled, forKey: Keys.showInviteCodesEnabled) }
    }

    var isLoggedIn: Bool { token != nil && email != nil }

    var deviceId: String {
        sha256Hex(rawDeviceIdentifier)
    }

    var hardwareFingerprint: String {
        let device = UIDevice.current
        let raw = [
            rawDeviceIdentifier,
            device.systemName,
            device.systemVersion,
            device.model,
            device.localizedModel,
        ].joined(separator: "|")
        return sha256Hex(raw)
    }

    func login(response: AuthResponse) {
        token = response.token
        email = response.email
        tier  = response.tier
    }

    func logout() {
        token = nil
        email = nil
        tier  = "none"
        planName = ""
        creditsTotal = 0
        creditsUsed = 0
        creditsRemaining = 0
        creditsResetAt = nil
        planExpiresAt = nil
        subscriptionExpiresAt = nil
        autoRenew = false
        nextRenewalAt = nil
        renewalCancellable = false
    }

    func updatePlan(_ plan: UserPlanInfo) {
        tier = plan.tier
        planName = plan.planName
        creditsTotal = plan.creditsTotal
        creditsUsed = plan.creditsUsed
        creditsRemaining = plan.creditsRemaining
        creditsResetAt = plan.creditsResetAt
        planExpiresAt = plan.planExpiresAt
        subscriptionExpiresAt = plan.subscriptionExpiresAt
        autoRenew = plan.autoRenew
        nextRenewalAt = plan.nextRenewalAt
        renewalCancellable = plan.renewalCancellable
        registrationEnabled = plan.registrationEnabled
        inviteCodeEnabled = plan.inviteCodeEnabled
        showInviteCodesEnabled = plan.showInviteCodesEnabled
    }

    /// 主动拉取最新套餐/积分信息并写入。设置页出现、登录成功后调用，
    /// 修复"设置页总积分一直为 0（会话内登录错过冷启动拉取）"的问题。
    /// 失败静默忽略，不打断 UI（保留已有缓存值）。
    func refreshPlanInfo() async {
        guard isLoggedIn else { return }
        if let plan = try? await APIClient.shared.fetchPlanInfo() {
            updatePlan(plan)
        }
    }

    // MARK: - 日期格式化

    /// 下次积分重置日期（本地化，仅年月日），无则返回 nil
    func formattedResetDate(locale: Locale = .current) -> String? {
        Self.formatServerDate(creditsResetAt, locale: locale)
    }

    /// 当前套餐/订阅有效期（本地化，仅年月日）。
    /// 优先订阅到期时间，回退套餐到期时间；均为空表示永久有效，返回 nil。
    func formattedExpiryDate(locale: Locale = .current) -> String? {
        Self.formatServerDate(subscriptionExpiresAt ?? planExpiresAt, locale: locale)
    }

    /// 将 ISO8601 UTC 字符串（带/不带小数秒，或多种回退格式）格式化为本地化日期字符串
    static func formatServerDate(_ raw: String?, locale: Locale = .current) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
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

    func updateStartupConfig(_ config: AppStartupConfig) {
        registrationEnabled = config.registrationEnabled
        inviteCodeEnabled = config.inviteCodeEnabled
        showInviteCodesEnabled = config.showInviteCodesEnabled
    }

    private var rawDeviceIdentifier: String {
        if let id = UIDevice.current.identifierForVendor?.uuidString {
            return id
        }
        if let stored = defaults.string(forKey: Keys.deviceFallback) {
            return stored
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Keys.deviceFallback)
        return generated
    }

    private func sha256Hex(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

}
