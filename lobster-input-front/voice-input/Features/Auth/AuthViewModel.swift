/// AuthViewModel.swift
/// 登录界面的视图模型，封装验证码发送、校验和邀请码流程逻辑。
/// 登录成功后保存 Token 到 AuthStore，清除旧会话残留状态。
/// 设备标识逻辑统一由 DeviceIdentity 提供。
import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {

    @Published var email = "" {
        didSet { if email != oldValue { refreshCooldown() } }
    }
    @Published var code = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var codeSent = false
    /// 发送验证码剩余冷却秒数（0 表示可发送），基于本地持久化时间戳，退出 APP 重进仍生效
    @Published var codeCooldown = 0

    /// 新用户进入邀请码填写步骤
    @Published var showInviteStep = false

    private let authStore = AuthStore.shared

    // 验证码发送冷却持久化：记录最近发码邮箱与到期时间戳
    private let cooldownSeconds = 60
    private let cooldownEmailKey = "auth_send_code_email"
    private let cooldownExpiresKey = "auth_send_code_expires_at"
    private var cooldownTimer: Timer?

    init() {
        startCooldown(from: remainingCooldownSeconds(for: email))
    }

    func sendCode() async {
        guard !email.isEmpty else { errorMessage = L10n.enterEmail; return }
        guard codeCooldown <= 0 else { return }
        isLoading = true
        errorMessage = nil
        do {
            try await APIClient.shared.sendCode(email: email)
            persistCooldown()
            startCooldown(from: cooldownSeconds)
            codeSent = true
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
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

    func verify() async {
        guard !code.isEmpty else { errorMessage = L10n.enterCode; return }
        isLoading = true
        errorMessage = nil
        do {
            let resp = try await APIClient.shared.verify(email: email, code: code)
            if resp.requireInvite {
                authStore.pendingInviteEmail = email
                showInviteStep = true
            } else {
                authStore.save(resp)
                RecordingResultStore.shared.clear()
                Task { await AppDelegate.fetchRecordingConfig() }
                Task { await AppDelegate.fetchUserPlanInfo() }
            }
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
    }

    func resetCode() {
        code = ""
        codeSent = false
        errorMessage = nil
        showInviteStep = false
    }
}
