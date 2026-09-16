/// SettingsView.swift
/// 设置界面 — 沙棕极简风格
import SwiftUI
import Carbon
import AppKit
import Combine
import ServiceManagement

enum TranscribeFastModeStore {
    private static let key = "transcribe_fast_mode_enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum LaunchAtLoginStore {
    private static let firstLaunchRegistrationKey = "launch_at_login_first_launch_registration_done"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func registerOnFirstLaunchIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: firstLaunchRegistrationKey) else { return }
        UserDefaults.standard.set(true, forKey: firstLaunchRegistrationKey)
        do {
            try setEnabled(true)
            DebugTrace.log("LaunchAtLoginStore: first launch registration completed")
        } catch {
            DebugTrace.log("LaunchAtLoginStore: first launch registration failed: \(error.localizedDescription)")
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

struct SettingsView: View {

    @ObservedObject private var authStore = AuthStore.shared
    @ObservedObject private var permissionManager = PermissionManager.shared
    @ObservedObject private var hotKeyManager = HotKeyManager.shared
    @ObservedObject private var micManager = MicrophoneDeviceManager.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var recordingCombo: HotKeyCombo? = nil
    @State private var hotKeyConflictMessage: String? = nil
    @ObservedObject private var lang = LanguageManager.shared
    @State private var clipboardEnabled: Bool = ClipboardHistoryReader.isEnabled
    @State private var transcribeFastModeEnabled: Bool = TranscribeFastModeStore.isEnabled
    @State private var realtimeRecognitionEnabled: Bool = RealtimeRecognitionStore.isEnabled
    @State private var screenshotConfirmationEnabled: Bool = ScreenshotConfirmationStore.isEnabled
    @State private var screenshotScrollingEnabled: Bool = ScreenshotScrollingStore.isEnabled
    @State private var launchAtLoginEnabled: Bool = LaunchAtLoginStore.isEnabled
    @State private var launchAtLoginErrorMessage: String?
    @State private var showCreditDetailsPopover = false
    @State private var showSubscriptionPage = false

    var body: some View {
        ZStack {
            Cyber.bgTop
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.pageSettings)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Cyber.textBright)
                    Spacer()
                }
                .padding(.horizontal, CyberLayout.padH).padding(.vertical, CyberLayout.padV)
                CyberDivider()
                if showSubscriptionPage {
                    SubscriptionSettingsPage(onBack: { showSubscriptionPage = false })
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            accountCreditSection
                            if authStore.showSubscriptionModuleEnabled {
                                subscriptionSection
                            }
                            appearanceSection
                            systemSection
                            microphoneSection
                            hotKeySection
                            screenshotSection
                            permissionSection
                            privacySection
                            tutorialSection
                            feedbackSection
                            languageSection
                            softwareUpdateSection
                        }
                        .frame(maxWidth: CyberLayout.readingMaxW, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, CyberLayout.padH)
                        .padding(.vertical, 32)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            permissionManager.refreshStatuses()
            micManager.refreshDevices()
            transcribeFastModeEnabled = TranscribeFastModeStore.isEnabled
            realtimeRecognitionEnabled = RealtimeRecognitionStore.isEnabled
            screenshotConfirmationEnabled = ScreenshotConfirmationStore.isEnabled
            screenshotScrollingEnabled = ScreenshotScrollingStore.isEnabled
            launchAtLoginEnabled = LaunchAtLoginStore.isEnabled
        }
        .onDisappear {
            if recordingCombo != nil {
                cancelHotKeyRecording()
            }
        }
    }

    private var accountCreditSection: some View {
        SettingsSection(icon: "person.text.rectangle", title: L10n.accountCredits) {
            creditSummaryCard
        }
    }

    private var creditSummaryCard: some View {
        VStack(spacing: 12) {
            creditHeaderRow
            creditProgressBar
            creditDetailsHint
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .neonCard()
        .contentShape(Rectangle())
        .onTapGesture { showCreditDetailsPopover.toggle() }
        .onHover { hovering in showCreditDetailsPopover = hovering }
        .popover(isPresented: $showCreditDetailsPopover, arrowEdge: .trailing) {
            CreditDetailsPopover()
        }
    }

    private var creditHeaderRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(authStore.displayPlanName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text("\(L10n.accountCreditsUsed) \(authStore.creditsUsed)")
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Text("\(authStore.creditsRemaining) / \(authStore.creditsTotal)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Cyber.textBright)
        }
    }

    private var creditProgressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Cyber.sidebarBg).frame(height: 8)
                RoundedRectangle(cornerRadius: 4).fill(Cyber.accent)
                    .frame(width: geo.size.width * creditsRatio, height: 8)
            }
        }
        .frame(height: 8)
    }

    private var creditDetailsHint: some View {
        HStack {
            Text(L10n.accountCreditsDetailsShow)
                .font(.system(size: 11))
                .foregroundStyle(Cyber.accent.opacity(0.75))
            Spacer()
        }
    }

    private var appearanceSection: some View {
        SettingsSection(icon: "gearshape", title: L10n.themeSwitch) {
            VStack(spacing: 0) {
                themePickerCard
                CyberDivider()
                    .padding(.leading, 18)
                accentPickerRow
            }
            .neonCard()
        }
    }

    private var subscriptionSection: some View {
        SettingsSection(icon: "creditcard", title: L10n.subscriptionSettingsSection) {
            Button {
                showSubscriptionPage = true
            } label: {
                HStack(spacing: 16) {
                    SettingsRowIcon("rectangle.stack.badge.plus")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.subscriptionEntryTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Cyber.textBright)
                        Text(L10n.subscriptionEntryDesc)
                            .font(.system(size: 11))
                            .foregroundStyle(Cyber.textGhost)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Cyber.textGhost)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .neonCard()
            }
            .buttonStyle(.plain)
        }
    }

    private var themePickerCard: some View {
        HStack(spacing: 16) {
            SettingsRowIcon("circle.lefthalf.filled")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.themeSwitch)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(themeStore.mode.label)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { themeStore.mode == .sandDark },
                set: { themeStore.mode = $0 ? .sandDark : .sandLight }
            ))
            .toggleStyle(.switch)
            .tint(Cyber.accent)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var accentPickerRow: some View {
        HStack(spacing: 16) {
            SettingsRowIcon("paintpalette")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.themeAccent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(themeStore.accent.label)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(AppAccent.allCases) { accent in
                    Button {
                        themeStore.accent = accent
                    } label: {
                        ZStack {
                            Circle()
                                .fill(accent.color(for: themeStore.mode))
                                .frame(width: 24, height: 24)
                            if themeStore.accent == accent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(accent == .mono && themeStore.mode == .sandDark ? Color.black : Color.white)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .background(Color.clear, in: Circle())
                        .overlay(Circle().stroke(themeStore.accent == accent ? Cyber.accentRing : Cyber.borderDim, lineWidth: themeStore.accent == accent ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(accent.label)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var creditsRatio: CGFloat {
        guard authStore.creditsTotal > 0 else { return 0 }
        return min(1.0, CGFloat(authStore.creditsRemaining) / CGFloat(authStore.creditsTotal))
    }

    private var hotKeySection: some View {
        SettingsSection(icon: "keyboard", title: L10n.sectionHotkeys) {
            VStack(spacing: 0) {
                HotKeyRow(combo: .transcribe, icon: "waveform", title: L10n.hotkeyVoiceInput, subtitle: L10n.hotkeyVoiceInputDesc,
                    config: hotKeyManager.configs[.transcribe], isRecording: recordingCombo == .transcribe,
                    onTap: { toggleRecording(.transcribe) }, onClear: { clearHotKey(.transcribe) })
                CyberDivider().padding(.leading, 18)
                HotKeyRow(combo: .rewrite, icon: "pencil.line", title: L10n.hotkeyRewriteTitle, subtitle: L10n.hotkeyRewriteDesc,
                    config: hotKeyManager.configs[.rewrite], isRecording: recordingCombo == .rewrite,
                    onTap: { toggleRecording(.rewrite) }, onClear: { clearHotKey(.rewrite) })
                CyberDivider().padding(.leading, 18)
                HotKeyRow(combo: .agent, icon: "sparkles", title: L10n.hotkeyAgentTitle, subtitle: L10n.hotkeyAgentDesc,
                    config: hotKeyManager.configs[.agent], isRecording: recordingCombo == .agent,
                    onTap: { toggleRecording(.agent) }, onClear: { clearHotKey(.agent) })
                CyberDivider().padding(.leading, 18)
                HotKeyRow(combo: .screenshot, icon: "viewfinder", title: L10n.hotkeyScreenshotTitle, subtitle: L10n.hotkeyScreenshotDesc,
                    config: hotKeyManager.configs[.screenshot], isRecording: recordingCombo == .screenshot,
                    onTap: { toggleRecording(.screenshot) }, onClear: { clearHotKey(.screenshot) })
            }.neonCard()
            if recordingCombo != nil {
                Text(L10n.pressNewHotkey)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.warning)
                    .padding(.top, 6)
            }
            if let conflictMessage = hotKeyConflictMessage {
                Text(conflictMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.danger)
                    .padding(.top, 6)
            }
        }
        .background(
            KeyCaptureView(isActive: recordingCombo != nil) { kc, m, fn in applyNewHotKey(keyCode: kc, modifiers: m, requiresFn: fn) }
                onEscape: { cancelHotKeyRecording() }
        )
    }

    private var microphoneSection: some View {
        SettingsSection(icon: "mic", title: L10n.settingsMicrophoneSection) {
            VStack(spacing: 0) {
                MicrophoneDeviceRow(manager: micManager)
                CyberDivider().padding(.leading, 18)
                TranscribeFastModeRow(isOn: $transcribeFastModeEnabled)
                CyberDivider().padding(.leading, 18)
                RealtimeRecognitionRow(isOn: $realtimeRecognitionEnabled)
            }
            .neonCard()
        }
    }

    private var screenshotSection: some View {
        SettingsSection(icon: "viewfinder", title: L10n.hotkeyScreenshotTitle) {
            // 二次确认与长图模式互斥：打开任一个都会自动关闭另一个，不允许两个同时开启
            ScreenshotConfirmationRow(isOn: $screenshotConfirmationEnabled, onEnabled: {
                screenshotScrollingEnabled = false
                ScreenshotScrollingStore.isEnabled = false
            })
                .neonCard()
            ScrollingScreenshotRow(isOn: $screenshotScrollingEnabled, onEnabled: {
                screenshotConfirmationEnabled = false
                ScreenshotConfirmationStore.isEnabled = false
            })
                .neonCard()
        }
    }

    private var systemSection: some View {
        SettingsSection(icon: "desktopcomputer", title: L10n.settingsSystemSection) {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    SettingsRowIcon("power")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.launchAtLoginTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Cyber.textBright)
                        Text(launchAtLoginErrorMessage ?? L10n.launchAtLoginDesc)
                            .font(.system(size: 11))
                            .foregroundStyle(launchAtLoginErrorMessage == nil ? Cyber.textGhost : Cyber.warning)
                    }
                    Spacer()
                    Toggle("", isOn: $launchAtLoginEnabled)
                        .toggleStyle(.switch)
                        .tint(Cyber.accent)
                        .onChange(of: launchAtLoginEnabled) { _, newValue in
                            updateLaunchAtLogin(newValue)
                        }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .neonCard()
        }
    }

    private var permissionSection: some View {
        SettingsSection(icon: "lock.shield", title: L10n.sectionPermissions) {
            VStack(spacing: 0) {
                PermissionRow(icon: "mic", iconColor: Cyber.warning, title: L10n.permMicrophone, status: permissionManager.microphoneStatus,
                    onAction: { if permissionManager.microphoneStatus == .notDetermined { Task { await permissionManager.requestMicrophone() } } else { permissionManager.openMicrophoneSettings() } })
                CyberDivider().padding(.leading, 18)
                PermissionRow(icon: "figure.wave", iconColor: Cyber.accent, title: L10n.permAccessibility, status: permissionManager.accessibilityStatus,
                    onAction: { permissionManager.requestAccessibilityIfNeeded(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { permissionManager.openAccessibilitySettings() } })
                CyberDivider().padding(.leading, 18)
                PermissionRow(icon: "camera.viewfinder", iconColor: Cyber.accent, title: L10n.permScreenCapture, status: permissionManager.screenCaptureStatus,
                    onAction: { if !permissionManager.requestScreenCaptureIfNeeded() { permissionManager.openScreenCaptureSettings() } },
                    detail: L10n.permissionOptional)
            }.neonCard()
        }
    }

    private var privacySection: some View {
        SettingsSection(icon: "lock", title: L10n.sectionPrivacy) {
            HStack(spacing: 16) {
                SettingsRowIcon("doc.on.doc")
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.clipboardAccessTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Cyber.textBright)
                    Text(L10n.clipboardAccessDesc)
                        .font(.system(size: 11))
                        .foregroundStyle(Cyber.textGhost)
                }
                Spacer()
                Toggle("", isOn: $clipboardEnabled)
                    .toggleStyle(.switch)
                    .tint(Cyber.accent)
                    .onChange(of: clipboardEnabled) { _, newValue in
                        ClipboardHistoryReader.isEnabled = newValue
                    }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .neonCard()
        }
    }

    private var languageSection: some View {
        SettingsSection(icon: "globe", title: L10n.languageLabel) {
            HStack(spacing: 16) {
                SettingsRowIcon("globe")
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.languageLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Cyber.textBright)
                    Text(lang.current.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(Cyber.textGhost)
                }
                Spacer()
                Menu {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                LanguageManager.shared.current = language
                            }
                        } label: {
                            HStack {
                                Text(language.displayName)
                                if lang.current == language {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(lang.current.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Cyber.textBright)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Cyber.textGhost)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 160, height: 30)
                    .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
                    .overlay(
                        RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                            .stroke(Cyber.lineStrong, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .neonCard()
        }
    }

    private var tutorialSection: some View {
        SettingsSection(icon: "graduationcap", title: L10n.settingsTutorialSection) {
            Button {
                OnboardingManager.shared.replay()
            } label: {
                HStack(spacing: 16) {
                    SettingsRowIcon("play.circle")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tutorialReplayTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Cyber.textBright)
                        Text(L10n.tutorialReplayDesc)
                            .font(.system(size: 11))
                            .foregroundStyle(Cyber.textGhost)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Cyber.textGhost)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .neonCard()
            }
            .buttonStyle(.plain)
        }
    }

    private var feedbackSection: some View {
        SettingsSection(icon: "bubble.left", title: L10n.settingsFeedbackSection) {
            Button {
                FeedbackWindowController.shared.show()
            } label: {
                HStack(spacing: 16) {
                    SettingsRowIcon("paperplane")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.feedbackTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Cyber.textBright)
                        Text(L10n.feedbackSettingsDesc)
                            .font(.system(size: 11))
                            .foregroundStyle(Cyber.textGhost)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Cyber.textGhost)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .neonCard()
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleRecording(_ combo: HotKeyCombo) {
        hotKeyConflictMessage = nil
        if recordingCombo == combo {
            cancelHotKeyRecording()
        } else {
            hotKeyManager.stopListening()
            recordingCombo = combo
        }
    }

    private func cancelHotKeyRecording() {
        recordingCombo = nil
        restartHotKeyListening()
    }

    private func clearHotKey(_ combo: HotKeyCombo) {
        hotKeyConflictMessage = nil
        hotKeyManager.configs[combo] = nil
        hotKeyManager.markComboCustomized(combo)
        hotKeyManager.markComboDisabled(combo)
        hotKeyManager.saveConfigs()
        restartHotKeyListening()
    }

    private func applyNewHotKey(keyCode: Int, modifiers: NSEvent.ModifierFlags, requiresFn: Bool) {
        guard let combo = recordingCombo else { return }
        let normalized = modifiers.intersection([.control, .option, .shift, .command])
        let normalizedRequiresFn = requiresFn || modifiers.contains(.function)
        let candidate = HotKeyConfig(
            modifiers: Int(normalized.rawValue),
            keyCode: keyCode,
            requiresFn: normalizedRequiresFn
        )

        // 冲突检测:重复/系统保留 → 阻止保存并提示;符号热键冲突 → 保存但警告
        let conflicts = HotKeyValidator.validate(candidate: candidate, for: combo, existing: hotKeyManager.configs)
        if case .duplicate(let other)? = conflicts.first(where: { if case .duplicate = $0 { return true }; return false }) {
            hotKeyConflictMessage = String(format: L10n.hotkeyConflictDuplicate, comboDisplayName(other))
            DebugTrace.log("HotKey CONFLICT: \(combo.rawValue) rejected, duplicate of \(other.rawValue), candidate=\(candidate.displayString)")
            recordingCombo = nil
            restartHotKeyListening()
            return
        }
        if conflicts.contains(.systemReserved) {
            hotKeyConflictMessage = L10n.hotkeyConflictSystemReserved
            DebugTrace.log("HotKey CONFLICT: \(combo.rawValue) rejected, system reserved, candidate=\(candidate.displayString)")
            recordingCombo = nil
            restartHotKeyListening()
            return
        }
        hotKeyConflictMessage = conflicts.contains(.systemShortcut) ? L10n.hotkeyConflictSystemWarning : nil

        hotKeyManager.configs[combo] = candidate
        hotKeyManager.markComboCustomized(combo)
        hotKeyManager.markComboEnabled(combo)
        hotKeyManager.saveConfigs(); recordingCombo = nil
        DebugTrace.log("HotKey CONFIG: \(combo.rawValue) set to \(candidate.displayString) by user")
        restartHotKeyListening()
    }

    private func comboDisplayName(_ combo: HotKeyCombo) -> String {
        switch combo {
        case .transcribe: return L10n.hotkeyVoiceInput
        case .rewrite: return L10n.hotkeyRewriteTitle
        case .agent: return L10n.hotkeyAgentTitle
        case .screenshot: return L10n.hotkeyScreenshotTitle
        }
    }

    private func restartHotKeyListening() {
        hotKeyManager.stopListening()
        hotKeyManager.startListening { c in AppHotKeyHandler.shared.handle(c) }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginStore.setEnabled(enabled)
            launchAtLoginErrorMessage = nil
            launchAtLoginEnabled = LaunchAtLoginStore.isEnabled
        } catch {
            launchAtLoginErrorMessage = L10n.launchAtLoginError
            launchAtLoginEnabled = LaunchAtLoginStore.isEnabled
        }
    }

    private var softwareUpdateSection: some View {
        SettingsSection(icon: "arrow.down.circle", title: L10n.settingsSoftwareUpdateSection) {
            UpdateCheckRow()
        }
    }
}

// MARK: - SubscriptionSettingsPage

@MainActor
private final class SubscriptionSettingsViewModel: ObservableObject {
    @Published var catalog: PaymentCatalogResponse?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var checkoutInProgress: String?
    @Published var showCancelRenewalConfirm = false
    @Published var cancelRenewalInProgress = false
    @Published var cancelRenewalError: String?

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            catalog = try await APIClient.shared.fetchPaymentCatalog()
        } catch {
            errorMessage = L10n.subscriptionLoadFailed
        }
        isLoading = false
    }

    func beginSubscribe(plan: PaymentSubscriptionPlan, option: PaymentBillingOption) {
        Task { await subscribe(plan: plan, option: option) }
    }

    func beginTopup(_ topup: PaymentCreditsTopup) {
        Task { await createTopupCheckout(topup) }
    }

    func beginCancelRenewal() {
        Task { await cancelRenewal() }
    }

    /// 取消自动续费。cancelled / already_cancelled 均视为成功，刷新套餐信息后
    /// UI 随 AuthStore.autoRenew 变化自然回到「仅显示到期时间」状态。
    private func cancelRenewal() async {
        cancelRenewalInProgress = true
        cancelRenewalError = nil
        do {
            let result = try await APIClient.shared.cancelSubscriptionRenewal()
            switch result.status {
            case "cancelled", "already_cancelled", "apple_managed":
                // apple_managed 表示订阅由应用商店托管：同样刷新套餐信息，UI 按最新状态展示
                await AppDelegate.fetchUserPlanInfo()
            default:
                cancelRenewalError = L10n.subscriptionCancelRenewalFailed
            }
        } catch {
            cancelRenewalError = L10n.subscriptionCancelRenewalFailed
        }
        cancelRenewalInProgress = false
    }

    private func subscribe(plan: PaymentSubscriptionPlan, option: PaymentBillingOption) async {
        guard let provider = catalog?.activeProvider, !provider.isEmpty else {
            errorMessage = L10n.subscriptionCheckoutFailed
            return
        }
        checkoutInProgress = "\(plan.planCode):\(option.cycle)"
        errorMessage = nil
        do {
            let checkout = try await APIClient.shared.createSubscriptionCheckout(
                provider: provider,
                productCode: option.productCode ?? "\(plan.planCode)_\(option.cycle)",
                paymentMethod: "",
                currency: option.currency ?? "",
                planCode: plan.planCode,
                billingCycle: option.cycle
            )
            openCheckout(checkout.checkoutURL)
            Task { await refreshAfterCheckout() }
        } catch {
            errorMessage = L10n.subscriptionCheckoutFailed
        }
        checkoutInProgress = nil
    }

    private func createTopupCheckout(_ topup: PaymentCreditsTopup) async {
        guard let provider = catalog?.activeProvider, !provider.isEmpty else {
            errorMessage = L10n.subscriptionCheckoutFailed
            return
        }
        checkoutInProgress = "topup"
        errorMessage = nil
        do {
            let checkout = try await APIClient.shared.createCreditsTopupCheckout(
                provider: provider,
                productCode: topup.productCode ?? "credits_topup",
                paymentMethod: "",
                currency: topup.currency ?? ""
            )
            openCheckout(checkout.checkoutURL)
            Task { await refreshAfterCheckout() }
        } catch {
            errorMessage = L10n.subscriptionCheckoutFailed
        }
        checkoutInProgress = nil
    }

    private func openCheckout(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshAfterCheckout() async {
        for delay in [3, 5, 8, 13, 21, 34] {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            _ = await AppDelegate.fetchUserPlanInfo()
            do {
                catalog = try await APIClient.shared.fetchPaymentCatalog()
            } catch {
                errorMessage = L10n.subscriptionLoadFailed
            }
        }
    }
}

private struct SubscriptionSettingsPage: View {
    let onBack: () -> Void
    @StateObject private var vm = SubscriptionSettingsViewModel()
    @ObservedObject private var authStore = AuthStore.shared
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if vm.isLoading && vm.catalog == nil {
                    loadingRow
                }
                if let message = vm.errorMessage {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cyber.warning)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Cyber.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
                }
                if let catalog = vm.catalog {
                    currentPlanBlock(catalog)
                    plansBlock(catalog)
                }
            }
            .frame(maxWidth: CyberLayout.readingMaxW, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CyberLayout.padH)
            .padding(.vertical, 32)
        }
        .task {
            await vm.load()
            // 刷新套餐信息，保证自动续费状态为最新
            await AppDelegate.fetchUserPlanInfo()
        }
        .alert(L10n.subscriptionCancelRenewalConfirmTitle, isPresented: $vm.showCancelRenewalConfirm) {
            Button(L10n.subscriptionCancelRenewalConfirm, role: .destructive) {
                vm.beginCancelRenewal()
            }
            Button(L10n.subscriptionCancelRenewalKeep, role: .cancel) {}
        } message: {
            Text(L10n.subscriptionCancelRenewalConfirmMessage(renewalDateText))
        }
    }

    /// 自动续费/到期日期的本地化展示文本（优先下次续费时间，缺失时回退积分重置时间）
    private var renewalDateText: String {
        authStore.formattedNextRenewalDate() ?? authStore.formattedResetDate() ?? "--"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text(L10n.pageSettings)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Cyber.textGhost)
            }
            .buttonStyle(.plain)

            Text(L10n.subscriptionPageTitle)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Cyber.textBright)
            Text(L10n.subscriptionPageSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(Cyber.textGhost)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.7)
            Text(L10n.subscriptionLoading)
                .font(.system(size: 12))
                .foregroundStyle(Cyber.textGhost)
        }
        .padding(.vertical, 12)
    }

    private func currentPlanBlock(_ catalog: PaymentCatalogResponse) -> some View {
        SettingsSection(icon: "person.crop.circle.badge.checkmark", title: L10n.subscriptionCurrentPlan) {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    SettingsRowIcon("gauge.with.dots.needle.50percent")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localizedPlanName(catalog.currentPlan.planCode))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Cyber.textBright)
                        Text("\(catalog.currentPlan.planCreditsRemaining) / \(catalog.currentPlan.planCreditsTotal)")
                            .font(.system(size: 11))
                            .foregroundStyle(Cyber.textGhost)
                    }
                    Spacer()
                    Text(L10n.subscriptionCredits(catalog.currentPlan.planCreditsRemaining))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Cyber.textBright)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                if authStore.autoRenew {
                    CyberDivider().padding(.leading, 18)
                    autoRenewRow
                }

                CyberDivider().padding(.leading, 18)
                topupRow(catalog.creditsTopup)
            }
            .neonCard()
        }
    }

    /// 自动续费状态行：
    /// - 可取消（renewalCancellable）：显示下次续费日期 + 「取消自动续费」按钮
    /// - 不可取消：仅显示一行说明（在订阅设备的应用商店中管理）
    private var autoRenewRow: some View {
        HStack(spacing: 16) {
            SettingsRowIcon("arrow.triangle.2.circlepath")
            VStack(alignment: .leading, spacing: 4) {
                if authStore.renewalCancellable {
                    Text(L10n.subscriptionAutoRenewOn(renewalDateText))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Cyber.textBright)
                    if let message = vm.cancelRenewalError {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(Cyber.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(L10n.subscriptionAutoRenewManaged)
                        .font(.system(size: 12))
                        .foregroundStyle(Cyber.textGhost)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if authStore.renewalCancellable {
                Button {
                    vm.showCancelRenewalConfirm = true
                } label: {
                    checkoutButtonLabel(
                        title: L10n.subscriptionCancelRenewalAction,
                        isLoading: vm.cancelRenewalInProgress
                    )
                }
                .buttonStyle(.plain)
                .disabled(vm.cancelRenewalInProgress)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func topupRow(_ topup: PaymentCreditsTopup) -> some View {
        HStack(spacing: 16) {
            SettingsRowIcon("plus.circle")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.subscriptionTopupTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(topup.available ? L10n.subscriptionTopupDesc : L10n.subscriptionTopupUnavailable)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Button {
                vm.beginTopup(topup)
            } label: {
                checkoutButtonLabel(
                    title: topupButtonTitle(topup),
                    isLoading: vm.checkoutInProgress == "topup"
                )
            }
            .buttonStyle(.plain)
            .disabled(!topup.available || vm.checkoutInProgress != nil)
            .opacity(topup.available ? 1 : 0.45)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func topupButtonTitle(_ topup: PaymentCreditsTopup) -> String {
        let credits = topup.amount.map { L10n.subscriptionCredits($0) } ?? L10n.subscriptionTopupAction
        guard let price = paymentPriceText(topup.priceCents, currency: topup.currency) else { return credits }
        return "\(credits) - \(price)"
    }

    private func plansBlock(_ catalog: PaymentCatalogResponse) -> some View {
        SettingsSection(icon: "rectangle.stack", title: L10n.subscriptionAvailablePlans) {
            VStack(spacing: 10) {
                ForEach(catalog.subscriptions) { plan in
                    SubscriptionPlanRow(
                        plan: plan,
                        checkoutInProgress: vm.checkoutInProgress,
                        purchaseState: { option in
                            purchaseState(for: option, plan: plan, in: catalog)
                        },
                        onSubscribe: { option in
                            vm.beginSubscribe(plan: plan, option: option)
                        }
                    )
                }
            }
        }
    }

    /// 按账期选项判定可购状态:同套餐更长账期可补差价升级，年付不可降级(与后端闸门一致)
    private func purchaseState(for option: PaymentBillingOption, plan: PaymentSubscriptionPlan, in catalog: PaymentCatalogResponse) -> SubscriptionPlanPurchaseState {
        guard catalog.currentPlan.paid else { return .available }
        let isCurrentPlan = plan.planCode == catalog.currentPlan.planCode
        // 新版后端逐选项下发 purchasable/blocked_reason，以服务端判定为准
        if let purchasable = option.purchasable {
            if purchasable {
                if option.isProratedUpgrade || isCurrentPlan { return .upgrade }
                return .available
            }
            switch option.blockedReason {
            case "duplicate_purchase":
                return .current
            default:
                return .lowerTier
            }
        }
        // 旧版后端回退:套餐级判定(同套餐视为当前，低等级禁购)
        if isCurrentPlan {
            return .current
        }
        let currentRank = catalog.subscriptions.first(where: { $0.planCode == catalog.currentPlan.planCode })?.rank
        if let currentRank, plan.rank <= currentRank {
            return .lowerTier
        }
        return .available
    }

    @ViewBuilder
    private func checkoutButtonLabel(title: String, isLoading: Bool) -> some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Cyber.textBright)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Cyber.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
        .overlay(
            RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                .stroke(Cyber.accent.opacity(0.35), lineWidth: 1)
        )
    }
}

private enum SubscriptionPlanPurchaseState {
    case available
    case upgrade
    case current
    case lowerTier

    var isDisabled: Bool {
        switch self {
        case .available, .upgrade:
            return false
        case .current, .lowerTier:
            return true
        }
    }

    var actionTitle: String {
        switch self {
        case .available:
            return L10n.subscriptionSubscribe
        case .upgrade:
            return L10n.subscriptionUpgradeAction
        case .current:
            return L10n.subscriptionCurrentPlanAction
        case .lowerTier:
            return L10n.subscriptionLowerPlanAction
        }
    }
}

private func paymentPriceText(_ cents: Int?, currency: String?) -> String? {
    guard let cents else { return nil }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = (currency?.isEmpty == false ? currency : "USD")
    formatter.maximumFractionDigits = cents % 100 == 0 ? 0 : 2
    return formatter.string(from: NSNumber(value: Double(cents) / 100.0)) ?? "$\(cents / 100)"
}

private struct SubscriptionPlanRow: View {
    let plan: PaymentSubscriptionPlan
    let checkoutInProgress: String?
    let purchaseState: (PaymentBillingOption) -> SubscriptionPlanPurchaseState
    let onSubscribe: (PaymentBillingOption) -> Void
    @State private var selectedCycle: String?

    private var sortedOptions: [PaymentBillingOption] {
        plan.billingOptions.sorted { lhs, rhs in
            billingCycleRank(lhs.cycle) < billingCycleRank(rhs.cycle)
        }
    }

    private var selectedOption: PaymentBillingOption? {
        if let selectedCycle, let option = sortedOptions.first(where: { $0.cycle == selectedCycle }) {
            return option
        }
        // 默认优先选中可购选项(如当前套餐的补差价升年付)，否则回退月付
        if let purchasableOption = sortedOptions.first(where: { !purchaseState($0).isDisabled }) {
            return purchasableOption
        }
        return sortedOptions.first(where: { $0.cycle == "monthly" }) ?? sortedOptions.first
    }

    private var allOptionsDisabled: Bool {
        sortedOptions.allSatisfy { purchaseState($0).isDisabled }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            SettingsRowIcon("sparkles")
            VStack(alignment: .leading, spacing: 6) {
                Text(localizedPlanName(plan.planCode))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.subscriptionCredits(plan.credits))
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            if let option = selectedOption {
                let optionState = purchaseState(option)
                let isDisabled = optionState.isDisabled || checkoutInProgress != nil
                VStack(alignment: .trailing, spacing: 6) {
                    if sortedOptions.count > 1 {
                        Picker("", selection: Binding(
                            get: { selectedCycle ?? option.cycle },
                            set: { selectedCycle = $0 }
                        )) {
                            ForEach(sortedOptions) { item in
                                Text(billingCycleTitle(item.cycle)).tag(item.cycle)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: min(190, CGFloat(sortedOptions.count) * 76))
                    }
                    Text(billingPriceTitle(option))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(optionState.isDisabled ? Cyber.textGhost : Cyber.textBright)
                    if option.isProratedUpgrade, optionState == .upgrade {
                        Text(L10n.subscriptionUpgradeCreditNote)
                            .font(.system(size: 10))
                            .foregroundStyle(Cyber.textGhost)
                    }
                    Button {
                        onSubscribe(option)
                    } label: {
                        HStack(spacing: 6) {
                            if checkoutInProgress == "\(plan.planCode):\(option.cycle)" {
                                ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                            }
                            Text(optionState.actionTitle)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(optionState.isDisabled ? Cyber.textGhost : Cyber.textBright)
                        .padding(.horizontal, 14)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: 30)
                        .background((optionState.isDisabled ? Cyber.panelBg.opacity(0.55) : Cyber.panelBg), in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
                        .overlay(
                            RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                                .stroke(optionState.isDisabled ? Cyber.lineStrong.opacity(0.55) : Cyber.lineStrong, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .opacity(allOptionsDisabled ? 0.72 : 1)
        .neonCard()
        .onAppear {
            if selectedCycle == nil {
                selectedCycle = selectedOption?.cycle
            }
        }
    }

    private func billingPriceTitle(_ option: PaymentBillingOption) -> String {
        let price = paymentPriceText(option.effectivePriceCents, currency: option.currency) ?? "$0"
        if option.cycle == "monthly" {
            return L10n.subscriptionPriceMonthly(price)
        }
        return "\(price) / \(billingCycleTitle(option.cycle))"
    }
}

private func billingCycleRank(_ cycle: String) -> Int {
    switch cycle {
    case "weekly": return 10
    case "monthly": return 20
    case "quarterly": return 30
    case "yearly", "annual": return 40
    default: return 100
    }
}

private func billingCycleTitle(_ cycle: String) -> String {
    switch cycle {
    case "weekly": return L10n.planWeekly
    case "monthly": return L10n.subscriptionBillingMonthly
    case "quarterly": return "Quarterly"
    case "yearly", "annual": return L10n.planYearly
    default: return cycle
    }
}

// MARK: - SettingsSection

private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Cyber.textGhost)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Cyber.textGhost)
                    .tracking(0.8)
            }
            content()
        }
    }
}

private struct SettingsRowIcon: View {
    let systemName: String

    init(_ systemName: String) {
        self.systemName = systemName
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Cyber.textDim)
            .frame(width: 20)
    }
}

// MARK: - UpdateCheckRow

@MainActor
private final class UpdateCheckViewModel: ObservableObject {
    @Published var checkState: AppDelegate.UpdateCheckState = .idle
    private var kvoToken: NSKeyValueObservation?

    func attach() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        checkState = delegate.updateCheckState
        kvoToken = delegate.observe(\.updateCheckStateRaw, options: [.new]) { [weak self] d, _ in
            DispatchQueue.main.async {
                self?.checkState = AppDelegate.UpdateCheckState(rawValue: d.updateCheckStateRaw) ?? .idle
            }
        }
    }

    func detach() { kvoToken = nil }
}

private struct UpdateCheckRow: View {
    @StateObject private var vm = UpdateCheckViewModel()
    @ObservedObject private var lang = LanguageManager.shared

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "-"
        let b = info?["CFBundleVersion"] as? String ?? "-"
        return "v\(v) (Build \(b)) · \(L10n.envBadge)"
    }

    private var btnLabel: String {
        switch vm.checkState {
        case .idle:        return L10n.settingsCheckUpdate
        case .checking, .downloading: return L10n.settingsUpdateChecking
        case .noUpdate:    return L10n.settingsUpdateNoUpdate
        case .updateFound: return L10n.settingsUpdateFound
        case .error:       return L10n.settingsUpdateError
        case .devBuild:    return L10n.settingsUpdateDevBuild
        }
    }

    private var btnColor: Color {
        switch vm.checkState {
        case .noUpdate:             return Cyber.success
        case .updateFound:          return Cyber.accent
        case .error, .devBuild:     return Cyber.warning
        default:                    return Cyber.textBright
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowIcon("arrow.clockwise")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.settingsSoftwareUpdateSection)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(versionText)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Button {
                NSLog("[UpdateCheck] button tapped, state=\(vm.checkState.rawValue)")
                AppDelegate.shared?.checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    if vm.checkState.isSpinning {
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 12, height: 12)
                    }
                    Text(btnLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(btnColor)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 14)
                .frame(minWidth: 110)
                .frame(height: 30)
                .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
                .overlay(
                    RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                        .stroke(Cyber.lineStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(vm.checkState.isSpinning)
            .animation(.easeInOut(duration: 0.15), value: vm.checkState)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .neonCard()
        .onAppear { vm.attach() }
        .onDisappear { vm.detach() }
    }
}

// MARK: - HotKeyRow

private struct HotKeyRow: View {
    let combo: HotKeyCombo; let icon: String; let title: String; let subtitle: String; let config: HotKeyConfig?
    let isRecording: Bool; let onTap: () -> Void; let onClear: () -> Void
    @ObservedObject private var lang = LanguageManager.shared
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    SettingsRowIcon(icon)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Cyber.textBright)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
                    .padding(.leading, 28)
            }
            Spacer()
            Button(action: onTap) {
                Text(isRecording ? L10n.pressHotkeyHint : (config?.displayString ?? L10n.hotkeyNotSet))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isRecording ? Cyber.warning : Cyber.accent)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(
                        (isRecording ? Cyber.warning : Cyber.accent).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke((isRecording ? Cyber.warning : Cyber.accent).opacity(0.3), lineWidth: 1)
                    )
            }.buttonStyle(.plain).frame(minWidth: 100)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Cyber.textGhost)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }
}

// MARK: - TranscribeFastModeRow

private struct TranscribeFastModeRow: View {
    @Binding var isOn: Bool
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowIcon("bolt")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.transcribeFastModeTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.transcribeFastModeDesc)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Cyber.accent)
                .onChange(of: isOn) { _, newValue in
                    TranscribeFastModeStore.isEnabled = newValue
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

// MARK: - RealtimeRecognitionRow

private struct RealtimeRecognitionRow: View {
    @Binding var isOn: Bool
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowIcon("dot.radiowaves.left.and.right")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.realtimeRecognitionTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.realtimeRecognitionDesc)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Cyber.accent)
                .onChange(of: isOn) { _, newValue in
                    RealtimeRecognitionStore.isEnabled = newValue
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

// MARK: - ScreenshotConfirmationRow

private struct ScreenshotConfirmationRow: View {
    @Binding var isOn: Bool
    var onEnabled: (() -> Void)? = nil
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowIcon("camera.viewfinder")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.screenshotConfirmationTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.screenshotConfirmationDesc)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Cyber.accent)
                .onChange(of: isOn) { _, newValue in
                    ScreenshotConfirmationStore.isEnabled = newValue
                    if newValue { onEnabled?() }
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

// MARK: - ScrollingScreenshotRow

private struct ScrollingScreenshotRow: View {
    @Binding var isOn: Bool
    var onEnabled: (() -> Void)? = nil
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowIcon("arrow.up.and.down.text.horizontal")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.screenshotScrollingTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.screenshotScrollingDesc)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Cyber.accent)
                .onChange(of: isOn) { _, newValue in
                    ScreenshotScrollingStore.isEnabled = newValue
                    if newValue { onEnabled?() }
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

// MARK: - MicrophoneDeviceRow

private struct MicrophoneDeviceRow: View {
    @ObservedObject var manager: MicrophoneDeviceManager
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowIcon("mic")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.microphoneInputTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.microphoneInputDesc)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Menu {
                Button(manager.defaultSelectionTitle) { manager.selectDefault() }
                if !manager.devices.isEmpty {
                    Divider()
                }
                ForEach(manager.devices) { device in
                    Button(device.name + (device.isDefault ? L10n.microphoneCurrentDefaultSuffix : "")) {
                        manager.selectDevice(uid: device.id)
                    }
                }
                Divider()
                Button(L10n.microphoneRefreshDevices) { manager.refreshDevices() }
            } label: {
                HStack(spacing: 8) {
                    Text(manager.selectedDeviceName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cyber.textBright)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Cyber.textGhost)
                }
                .padding(.horizontal, 10)
                .frame(width: 200, height: 30)
                .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
                .overlay(RoundedRectangle(cornerRadius: CyberLayout.cornerSm).stroke(Cyber.lineStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

// MARK: - PermissionRow

private struct PermissionRow: View {
    let icon: String; let iconColor: Color; let title: String; let status: PermissionStatus; let onAction: () -> Void
    var detail: String? = nil
    @ObservedObject private var lang = LanguageManager.shared
    var body: some View {
        HStack(spacing: 16) {
            SettingsRowIcon(icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Cyber.textGhost)
                }
            }
            Spacer()
            statusLabel
            Button(status == .granted ? L10n.manage : L10n.permGoAuth, action: onAction)
                .buttonStyle(NeonButtonStyle(color: status == .granted ? Cyber.textGhost : Cyber.accent))
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }
    private var statusLabel: some View {
        Group {
            switch status {
            case .granted:
                HStack(spacing: 5) {
                    Circle().fill(Cyber.success).frame(width: 6, height: 6)
                    Text(L10n.statusOk)
                }.foregroundStyle(Cyber.success)
            case .denied:
                HStack(spacing: 5) {
                    Circle().fill(Cyber.danger).frame(width: 6, height: 6)
                    Text(L10n.statusDenied)
                }.foregroundStyle(Cyber.danger)
            case .notDetermined:
                HStack(spacing: 5) {
                    Circle().fill(Cyber.warning).frame(width: 6, height: 6)
                    Text(L10n.statusPending)
                }.foregroundStyle(Cyber.warning)
            }
        }.font(.system(size: 12, weight: .medium))
    }
}

// MARK: - KeyCaptureView

private let kVK_FnKey: Int = 63

private struct KeyCaptureView: NSViewRepresentable {
    let isActive: Bool; let onKey: (Int, NSEvent.ModifierFlags, Bool) -> Void; let onEscape: () -> Void
    func makeNSView(context: Context) -> KeyCaptureNSView { let v = KeyCaptureNSView(); v.onKey = onKey; v.onEscape = onEscape; return v }
    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKey = onKey; nsView.onEscape = onEscape
        if isActive && !nsView.isActive { nsView.isActive = true; nsView.installMonitors(); DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) } }
        else if !isActive && nsView.isActive { nsView.isActive = false; nsView.removeMonitors() }
    }
}

final class KeyCaptureNSView: NSView {
    var isActive = false; var onKey: ((Int, NSEvent.ModifierFlags, Bool) -> Void)?; var onEscape: (() -> Void)?
    private var fnDown = false; private var modifierKeyDown: UInt16?
    private var localKeyMonitor: Any?; private var localFlagsMonitor: Any?; private var globalKeyMonitor: Any?; private var globalFlagsMonitor: Any?
    override var acceptsFirstResponder: Bool { true }

    func installMonitors() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in guard let self, self.isActive else { return e }; return self.handleKeyDown(e) ? nil : e }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in guard let self, self.isActive else { return e }; self.handleFlagsChanged(e); return e }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in guard let self, self.isActive else { return }; _ = self.handleKeyDown(e) }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in guard let self, self.isActive else { return }; self.handleFlagsChanged(e) }
    }

    func removeMonitors() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }; if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }; if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        localKeyMonitor = nil; localFlagsMonitor = nil; globalKeyMonitor = nil; globalFlagsMonitor = nil; fnDown = false; modifierKeyDown = nil
    }
    deinit { removeMonitors() }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode); modifierKeyDown = nil
        if code == Int(kVK_Escape) { Task { @MainActor in self.onEscape?() }; return true }
        let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let mods = event.modifierFlags.intersection(relevant); let hasFn = fnDown || event.modifierFlags.contains(.function)
        Task { @MainActor in self.onKey?(code, mods, hasFn) }; return true
    }

    private static let modifierKeyCodes: Set<UInt16> = [56, 60, 59, 62, 58, 61, 55, 54]
    private static func modifierFlag(for kc: UInt16) -> NSEvent.ModifierFlags? {
        switch kc { case 56, 60: return .shift; case 59, 62: return .control; case 58, 61: return .option; case 55, 54: return .command; default: return nil }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let code = event.keyCode
        if code == kVK_FnKey {
            let pressed = event.modifierFlags.contains(.function)
            if pressed && !fnDown { fnDown = true; modifierKeyDown = UInt16(kVK_FnKey) }
            else if !pressed && fnDown { fnDown = false; if modifierKeyDown == UInt16(kVK_FnKey) { modifierKeyDown = nil; Task { @MainActor in self.onKey?(-1, [], true) } } }
            return
        }
        guard Self.modifierKeyCodes.contains(code), let flag = Self.modifierFlag(for: code) else { return }
        let stillPressed = event.modifierFlags.contains(flag)
        // hasFn 取松开瞬间的 fn 实时状态:支持录制 Fn+⇧ 这类"Fn+修饰键"组合(此前写死 false 会丢掉 Fn)
        if stillPressed { modifierKeyDown = code } else if modifierKeyDown == code { let hasFn = fnDown; modifierKeyDown = nil; Task { @MainActor in self.onKey?(-1, flag, hasFn) } }
    }

    override func keyDown(with event: NSEvent) { guard isActive else { super.keyDown(with: event); return }; _ = handleKeyDown(event) }
}
