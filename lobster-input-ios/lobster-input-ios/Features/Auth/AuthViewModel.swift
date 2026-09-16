import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {

    @Published var email = "" {
        didSet { if email != oldValue { refreshCooldown() } }
    }
    @Published var code = ""
    @Published var inviteCode = ""
    @Published var isLoading = false
    @Published var showInviteCode = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var codeCooldown = 0

    private var cooldownTimer: Timer?
    private var pendingEmail = ""

    // 验证码发送冷却持久化：记录最近发码邮箱与到期时间戳，退出 APP 重进仍可恢复倒计时
    private let cooldownSeconds = 60
    private let cooldownEmailKey = "auth_send_code_email"
    private let cooldownExpiresKey = "auth_send_code_expires_at"

    init() {
        // 冷启动时若最近发码邮箱仍在冷却期内，预填邮箱并恢复倒计时
        if let pending = pendingCooldownEmail() {
            email = pending
        }
        startCooldown(from: remainingCooldownSeconds(for: email))
    }

    func sendCode() async {
        guard !email.isEmpty, codeCooldown <= 0 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await APIClient.shared.sendCode(email: email)
            persistCooldown()
            startCooldown(from: cooldownSeconds)
        } catch {
            showErrorAlert(error.localizedDescription)
        }
    }

    func login() async {
        guard !email.isEmpty, !code.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await APIClient.shared.verify(email: email, code: code)
            if response.isNewUser && response.requireInvite {
                pendingEmail = email
                showInviteCode = true
            } else {
                AuthStore.shared.login(response: response)
                // 登录成功后立即拉取套餐/积分，避免会话内登录错过冷启动拉取导致总积分为 0
                await AuthStore.shared.refreshPlanInfo()
            }
        } catch {
            showErrorAlert(error.localizedDescription)
        }
    }

    func submitInviteCode() async {
        guard !inviteCode.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        let deviceId = AuthStore.shared.deviceId
        do {
            let response = try await APIClient.shared.verifyInvite(
                email: pendingEmail, inviteCode: inviteCode, deviceId: deviceId
            )
            AuthStore.shared.login(response: response)
        } catch {
            showErrorAlert(error.localizedDescription)
        }
    }

    /// 依据当前邮箱的本地持久化时间戳，恢复/刷新发码倒计时
    func refreshCooldown() {
        startCooldown(from: remainingCooldownSeconds(for: email))
    }

    private func startCooldown(from seconds: Int) {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        guard seconds > 0 else {
            codeCooldown = 0
            return
        }
        codeCooldown = seconds
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.codeCooldown -= 1
                if self.codeCooldown <= 0 {
                    self.cooldownTimer?.invalidate()
                    self.cooldownTimer = nil
                }
            }
        }
    }

    private func persistCooldown() {
        let defaults = UserDefaults.standard
        defaults.set(email, forKey: cooldownEmailKey)
        defaults.set(Date().timeIntervalSince1970 + Double(cooldownSeconds), forKey: cooldownExpiresKey)
    }

    private func remainingCooldownSeconds(for email: String) -> Int {
        guard !email.isEmpty else { return 0 }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: cooldownEmailKey) == email else { return 0 }
        let expires = defaults.double(forKey: cooldownExpiresKey)
        let remaining = expires - Date().timeIntervalSince1970
        return remaining > 0 ? Int(ceil(remaining)) : 0
    }

    private func pendingCooldownEmail() -> String? {
        let defaults = UserDefaults.standard
        guard let saved = defaults.string(forKey: cooldownEmailKey),
              remainingCooldownSeconds(for: saved) > 0 else { return nil }
        return saved
    }

    private func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}
