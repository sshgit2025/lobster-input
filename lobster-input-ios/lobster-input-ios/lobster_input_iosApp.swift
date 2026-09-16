import SwiftUI

@main
struct LobsterInputApp: App {

    @StateObject private var authStore = AuthStore.shared
    @StateObject private var languageStore = MobileLanguageStore.shared
    @StateObject private var keyboardVoiceSession = KeyboardVoiceSessionController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if authStore.isLoggedIn {
                    MainTabView()
                } else {
                    AuthView()
                }
            }
            .environmentObject(languageStore)
            .environmentObject(keyboardVoiceSession)
            .task {
                keyboardVoiceSession.configure()
                // 尽早挂载 StoreKit 交易监听,避免漏掉续订/离线补偿交易
                _ = IAPManager.shared
                await loadStartupConfig()
                if !KeyboardVoiceSessionBridge.isEnabled {
                    await keyboardVoiceSession.setEnabled(true)
                } else {
                    await keyboardVoiceSession.startIfEnabled()
                }
            }
            .onChange(of: scenePhase) {
                let phase = scenePhase
                guard phase == .active || phase == .background else { return }
                Task {
                    if phase == .active {
                        await MainActor.run {
                            keyboardVoiceSession.processPendingCommandIfNeeded()
                        }
                    }
                    await keyboardVoiceSession.startIfEnabled()
                }
            }
            .onOpenURL { url in
                guard url.scheme == "lobster-input" else { return }
                if url.host == "activate-voice-session" {
                    Task {
                        if !KeyboardVoiceSessionBridge.isEnabled {
                            await keyboardVoiceSession.setEnabled(true)
                        } else {
                            await keyboardVoiceSession.startIfEnabled()
                        }
                        await MainActor.run {
                            keyboardVoiceSession.processPendingCommandIfNeeded()
                        }
                    }
                }
            }
        }
    }

    private func loadStartupConfig() async {
        do {
            let config = try await APIClient.shared.fetchStartupConfig()
            await MainActor.run { authStore.updateStartupConfig(config) }
        } catch {}

        if authStore.isLoggedIn {
            do {
                let plan = try await APIClient.shared.fetchPlanInfo()
                await MainActor.run { authStore.updatePlan(plan) }
            } catch {}

            do {
                let config = try await APIClient.shared.fetchRecordingConfig()
                await MainActor.run {
                    AudioRecorder.shared.maxDuration = TimeInterval(config.maxDurationSec)
                }
            } catch {}
        }
    }
}
