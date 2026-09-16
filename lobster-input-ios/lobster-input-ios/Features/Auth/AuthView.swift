import SwiftUI

struct AuthView: View {

    @StateObject private var viewModel = AuthViewModel()
    @StateObject private var authStore = AuthStore.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 12) {
                    Image("LobsterClaw")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)
                        .padding(20)
                        .background(LobsterWaterPalette.accentGradient, in: Circle())
                        .shadow(color: LobsterWaterPalette.accentColor.opacity(0.28), radius: 16, y: 8)
                    Text(L10n.appName)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(LobsterWaterPalette.textColor)
                    Text(L10n.appTagline)
                        .font(.subheadline)
                        .foregroundStyle(LobsterWaterPalette.mutedColor)
                }

                if viewModel.showInviteCode {
                    inviteCodeSection
                } else {
                    loginSection
                }

                Spacer()

                NavigationLink(L10n.agreementTitle) {
                    AgreementView()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(LobsterWaterPalette.accentColor)
            }
            .padding(24)
            .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
            .alert(L10n.authAlertTitle, isPresented: $viewModel.showError) {
                Button(L10n.btnDone) {}
            } message: {
                Text(viewModel.errorMessage)
            }
        }
    }

    private var loginSection: some View {
        VStack(spacing: 16) {
            TextField(L10n.authEmailPlaceholder, text: $viewModel.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                TextField(L10n.authCodePlaceholder, text: $viewModel.code)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await viewModel.sendCode() }
                } label: {
                    Text(viewModel.codeCooldown > 0
                         ? "\(viewModel.codeCooldown)s"
                         : L10n.authSendCode)
                        .font(.subheadline.weight(.medium))
                }
                .disabled(viewModel.email.isEmpty || viewModel.codeCooldown > 0 || viewModel.isLoading)
                .buttonStyle(.bordered)
                .tint(LobsterWaterPalette.accentColor)
            }

            Button {
                Task { await viewModel.login() }
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(L10n.authLogin)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LobsterWaterPalette.accentColor)
            .controlSize(.large)
            .disabled(viewModel.email.isEmpty || viewModel.code.isEmpty || viewModel.isLoading)
        }
        .lobsterCard()
    }

    private var inviteCodeSection: some View {
        VStack(spacing: 16) {
            Text(L10n.authInviteTitle)
                .font(.headline)
                .foregroundStyle(LobsterWaterPalette.textColor)

            TextField(L10n.authInvitePlaceholder, text: $viewModel.inviteCode)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await viewModel.submitInviteCode() }
            } label: {
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(L10n.authInviteSubmit)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LobsterWaterPalette.accentColor)
            .controlSize(.large)
            .disabled(viewModel.inviteCode.isEmpty || viewModel.isLoading)
        }
        .lobsterCard()
    }
}
