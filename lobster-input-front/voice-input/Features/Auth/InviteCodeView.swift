/// InviteCodeView.swift
/// 新用户邀请码填写页面，与 DIY 分支保持相同的业务架构。
/// 仅当 verify 返回 require_invite=true 时展示，完成后直接登录进入主界面。
import SwiftUI
import Combine

struct InviteCodeView: View {

    @StateObject private var vm: InviteCodeViewModel
    @ObservedObject private var lang = LanguageManager.shared

    init(email: String, onBack: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: InviteCodeViewModel(email: email, onBack: onBack))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            CyberDivider()
            form
            Spacer().frame(height: 24)
        }
        .padding(.top, 48)
        .padding(.horizontal, 40)
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Cyber.accent)

            Text(L10n.invitePageSubtitle)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Cyber.textBright)

            Text(L10n.invitePageTitle)
                .font(.system(size: 12))
                .foregroundStyle(Cyber.textDim)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 28)
    }

    private var form: some View {
        VStack(spacing: 20) {
            inviteInfoCard
            inviteInputSection
        }
        .padding(.vertical, 24)
    }

    private var inviteInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Cyber.accent)
                Text(L10n.inviteWelcomeHeading)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Cyber.accent)
            }

            Text(L10n.inviteBodyLine1)
                .font(.system(size: 13))
                .foregroundStyle(Cyber.textDim)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.inviteBodyLine2)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Cyber.warning.opacity(0.7))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Cyber.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
        .overlay(
            RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                .stroke(Cyber.accent.opacity(0.2), lineWidth: 0.8)
        )
    }

    private var inviteInputSection: some View {
        VStack(spacing: 16) {
            TextField(L10n.inviteCodePlaceholder, text: $vm.inviteCode)
                .textFieldStyle(CyberTextFieldStyle(accent: Cyber.accent))
                .onChange(of: vm.inviteCode) { _, v in
                    // 提取纯字母数字（最多8位），再格式化为 XXXX-XXXX
                    let raw = v.uppercased().filter { "ABCDEFGHJKMNPQRSTUVWXYZ23456789".contains($0) }
                    let clamped = String(raw.prefix(8))
                    if clamped.count > 4 {
                        vm.inviteCode = "\(clamped.prefix(4))-\(clamped.dropFirst(4))"
                    } else {
                        vm.inviteCode = clamped
                    }
                }
                .disabled(vm.isLoading)

            if let err = vm.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
                    Text(err).font(.system(size: 13))
                }
                .foregroundStyle(Cyber.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await vm.submitInviteCode() }
            } label: {
                Group {
                    if vm.isLoading {
                        ProgressView().controlSize(.small).tint(Cyber.accent)
                    } else {
                        Text(L10n.inviteSubmitBtn).frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(vm.isLoading || vm.rawInviteCode.count != 8)

            Button {
                vm.goBack()
            } label: {
                Text(L10n.inviteBackBtn)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.textGhost)
            }
            .buttonStyle(.plain)
            .disabled(vm.isLoading)
        }
    }
}

// MARK: - InviteCodeViewModel

@MainActor
final class InviteCodeViewModel: ObservableObject {

    @Published var inviteCode = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// 去掉连字符后的纯8位码，用于校验和提交
    var rawInviteCode: String {
        inviteCode.filter { "ABCDEFGHJKMNPQRSTUVWXYZ23456789".contains($0) }
    }

    let email: String
    private let onBack: () -> Void
    private let authStore = AuthStore.shared

    init(email: String, onBack: @escaping () -> Void) {
        self.email = email
        self.onBack = onBack
    }

    func submitInviteCode() async {
        let code = rawInviteCode
        guard code.count == 8 else { return }
        isLoading = true
        errorMessage = nil
        do {
            let deviceId = DeviceIdentity.deviceID()
            let fingerprint = DeviceIdentity.hardwareFingerprint()
            let resp = try await APIClient.shared.verifyInvite(
                email: email,
                inviteCode: code,
                deviceId: deviceId,
                hardwareFingerprint: fingerprint
            )
            authStore.clearPendingInvite()
            authStore.save(resp)
            RecordingResultStore.shared.clear()
            Task { await AppDelegate.fetchRecordingConfig() }
            Task { await AppDelegate.fetchUserPlanInfo() }
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
    }

    func goBack() {
        authStore.clearPendingInvite()
        onBack()
    }
}
