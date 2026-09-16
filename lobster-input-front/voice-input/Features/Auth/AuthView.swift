/// AuthView.swift
/// 邮箱验证码登录/注册界面 — 沙棕极简风格。
/// 新用户验证码通过后若后端返回 require_invite=true，则跳转邀请码填写页。
import SwiftUI

struct AuthView: View {

    @StateObject private var vm = AuthViewModel()
    @ObservedObject private var lang = LanguageManager.shared
    @State private var showLanguagePicker = false
    @State private var agreementType: AgreementType? = nil

    var body: some View {
        if vm.showInviteStep, let pendingEmail = AuthStore.shared.pendingInviteEmail {
            ZStack {
                Cyber.bgTop
                InviteCodeView(email: pendingEmail) {
                    vm.resetCode()
                }
            }
            .frame(maxWidth: CyberLayout.authW)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loginForm
        }
    }

    private var loginForm: some View {
        ZStack {
            Cyber.bgTop

            VStack(spacing: 0) {
                header
                form
                Spacer()
                authLanguagePicker
                    .padding(.bottom, 16)
                agreementLinks
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: CyberLayout.authW, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $agreementType) { type in
            AgreementView(type: type)
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image("LobsterClaw")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)

            Text(L10n.appNameFull)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Cyber.textBright)

            Text(vm.codeSent ? L10n.authSubtitle : "使用邮箱登录或注册")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Cyber.textGhost)
        }
        .padding(.top, 52)
        .padding(.bottom, 36)
        .padding(.horizontal, 48)
    }

    private var form: some View {
        VStack(spacing: 14) {
            TextField(L10n.emailPlaceholder, text: $vm.email)
                .textFieldStyle(CyberTextFieldStyle())
                .textContentType(.emailAddress)
                .disabled(vm.codeSent)

            if vm.codeSent {
                VStack(spacing: 10) {
                    TextField(L10n.codePlaceholder, text: $vm.code)
                        .textFieldStyle(CyberTextFieldStyle())
                    Button(vm.codeCooldown > 0 ? "\(L10n.resendCode) (\(vm.codeCooldown)s)" : L10n.resendCode) { vm.resetCode() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(vm.codeCooldown > 0 ? Cyber.textGhost : Cyber.accent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(vm.codeCooldown > 0)
                }
            }

            if let err = vm.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                    Text(err).font(.system(size: 13))
                }
                .foregroundStyle(Cyber.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }

            if !vm.codeSent {
                Button {
                    Task { await vm.sendCode() }
                } label: {
                    Group {
                        if vm.isLoading {
                            ProgressView().controlSize(.small).tint(Cyber.accentForeground)
                        } else {
                            Text(vm.codeCooldown > 0 ? "\(L10n.sendCode) (\(vm.codeCooldown)s)" : L10n.sendCode)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(height: 40)
                .disabled(vm.isLoading || vm.email.isEmpty || vm.codeCooldown > 0)
            } else {
                Button {
                    Task { await vm.verify() }
                } label: {
                    Group {
                        if vm.isLoading {
                            ProgressView().controlSize(.small).tint(Cyber.accentForeground)
                        } else {
                            Text(L10n.verifyAccess)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(height: 40)
                .disabled(vm.isLoading || vm.code.isEmpty)
            }
        }
        .padding(.horizontal, 44)
    }

    private var agreementLinks: some View {
        HStack(spacing: 4) {
            Text(L10n.continueToAgree)
                .font(.system(size: 11))
                .foregroundStyle(Cyber.textGhost)
            Button(L10n.agreementTerms) {
                agreementType = .terms
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Cyber.textDim)
            .underline()
            Text(L10n.agreementAnd)
                .font(.system(size: 11))
                .foregroundStyle(Cyber.textGhost)
            Button(L10n.agreementPrivacy) {
                agreementType = .privacy
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Cyber.textDim)
            .underline()
        }
    }

    private var authLanguagePicker: some View {
        Button { showLanguagePicker.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                Text(lang.current.displayName)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(Cyber.textDim)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Cyber.hoverBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Cyber.borderDim, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showLanguagePicker, arrowEdge: .top) {
            VStack(spacing: 4) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        lang.current = language
                        showLanguagePicker = false
                    } label: {
                        HStack(spacing: 10) {
                            Text(language.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(
                                    lang.current == language ? Cyber.accent : Cyber.textDim
                                )
                            Spacer()
                            if lang.current == language {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Cyber.accent)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            lang.current == language ? Cyber.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(width: 200)
            .background(Cyber.panelBg)
        }
    }
}

#Preview { AuthView() }
