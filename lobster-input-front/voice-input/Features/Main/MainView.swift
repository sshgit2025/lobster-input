/// MainView.swift
/// 应用主界面，采用左侧栏 + 右侧内容区布局。
import SwiftUI
import AppKit

func localizedPlanName(_ code: String) -> String {
    switch code {
    case "trial": return L10n.planTrial
    case "free": return L10n.planFree
    case "weekly": return L10n.planWeekly
    case "monthly": return L10n.planMonthly
    case "yearly": return L10n.planYearly
    case "lite": return L10n.planLite
    case "standard": return L10n.planStandard
    case "pro": return L10n.planPro
    case "none", "": return L10n.tierNone
    default: return code.uppercased()
    }
}

private func localizedCreditItemName(_ item: CreditBalanceItem) -> String {
    switch item.type {
    case "plan": return localizedPlanName(item.source)
    case "bonus": return L10n.creditItemBonus
    case "paid_topup": return L10n.creditItemPaidTopup
    default: return item.label.isEmpty ? item.source : item.label
    }
}

struct MainView: View {

    @ObservedObject private var authStore = AuthStore.shared
    @ObservedObject private var recorder = AudioRecorder.shared
    @ObservedObject private var resultStore = RecordingResultStore.shared
    @ObservedObject private var pm = PermissionManager.shared
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var selectedTab: SidebarTab = .home
    @State private var showPermissionPopover = false
    @State private var showAccountPopover = false
    @State private var showLanguagePopover = false
    @State private var isAccountHover = false

    enum SidebarTab: CaseIterable {
        case home, dictionary, persona, history, settings
        var icon: String {
            switch self {
            case .home: return "house"
            case .dictionary: return "book.closed"
            case .persona: return "person"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
        var label: String {
            switch self {
            case .home: return L10n.sidebarHome
            case .dictionary: return L10n.sidebarDict
            case .persona: return L10n.sidebarPersona
            case .history: return L10n.sidebarHistory
            case .settings: return L10n.sidebarSettings
            }
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Cyber.dividerCol)
                    .frame(width: 1)
                contentArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: CyberLayout.windowW, minHeight: CyberLayout.windowH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Cyber.bgTop)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ZStack {
            Cyber.sidebarBg

            VStack(spacing: 0) {
                // 品牌标识区
                HStack(spacing: 10) {
                    Image("LobsterClaw")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                    Text(L10n.appNameShort)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Cyber.textBright)
                    Text(L10n.envBadge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Cyber.textGhost)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Cyber.borderDim, lineWidth: 1))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 24)

                // 导航列表
                VStack(spacing: 1) {
                    ForEach(SidebarTab.allCases, id: \.self) { tab in
                        SidebarItem(
                            icon: tab.icon, label: tab.label,
                            isSelected: selectedTab == tab
                        ) { selectedTab = tab }
                    }
                }
                .padding(.horizontal, 8)

                Spacer()

                Divider()
                    .background(Cyber.borderDim)
                userFooter
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: CyberLayout.sidebarW)
    }

    private var recordingStatusBadge: some View {
        HStack(spacing: 8) {
            StatusDot(style: recorder.state == .recording ? .accent : .muted)
            Text(recorder.state == .recording ? L10n.statusRec :
                 recorder.state == .processing ? L10n.statusProc : L10n.statusIdle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Cyber.textGhost)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionStatusButton: some View {
        Button {
            pm.refreshStatuses()
            showPermissionPopover = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: pm.allGranted ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(pm.allGranted ? Cyber.success.opacity(0.7) : Cyber.warning)
                    .frame(width: 28, height: 28)
                    .background(
                        (pm.allGranted ? Cyber.success : Cyber.warning).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke((pm.allGranted ? Cyber.success : Cyber.warning).opacity(0.25), lineWidth: 1)
                    )
                if !pm.allGranted {
                    Circle()
                        .fill(Cyber.warning)
                        .frame(width: 7, height: 7)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(pm.allGranted ? L10n.permManage : L10n.permUnauthorized)
        .popover(isPresented: $showPermissionPopover, arrowEdge: .trailing) {
            PermissionGateView(onDone: { showPermissionPopover = false }).padding(0)
        }
    }

    private var userFooter: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    let refreshed = await AppDelegate.fetchUserPlanInfo()
                    await MainActor.run {
                        showAccountPopover = refreshed && authStore.isLoggedIn ? !showAccountPopover : false
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Cyber.textGhost)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authStore.email ?? L10n.notLoggedIn)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Cyber.textBright)
                            .lineLimit(1)
                        Text(planDisplayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Cyber.success.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(accountButtonBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(accountButtonBorder)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .onHover { isAccountHover = $0 }
            .help(L10n.accountTitle)
            .popover(isPresented: $showAccountPopover, arrowEdge: .top) {
                AccountPopoverView(onLogout: {
                    showAccountPopover = false
                    // 先在清除本地登录态前捕获 token，fire-and-forget 通知服务端销毁会话
                    //（幂等接口，失败也不阻塞本地登出），再清本地登录态回到登录界面。
                    if let token = authStore.token {
                        Task { try? await APIClient.shared.logout(token: token) }
                    }
                    authStore.logout()
                })
            }
            languagePicker
            appMenuButton
        }
    }

    private var accountButtonBackground: Color {
        (isAccountHover || showAccountPopover) ? Cyber.hoverBg : Color.clear
    }

    private var accountButtonBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(
                (isAccountHover || showAccountPopover) ? Cyber.borderDim : Color.clear,
                lineWidth: 1
            )
    }

    private var languagePicker: some View {
        Button { showLanguagePopover.toggle() } label: {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Cyber.textGhost)
                .frame(width: 26, height: 26)
                .background(Cyber.hoverBg, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(L10n.languageLabel)
        .popover(isPresented: $showLanguagePopover, arrowEdge: .top) {
            VStack(spacing: 4) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        LanguageManager.shared.current = language
                        showLanguagePopover = false
                    } label: {
                        HStack(spacing: 10) {
                            Text(language.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(lang.current == language ? Cyber.accent : Cyber.textDim)
                            Spacer()
                            if lang.current == language {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Cyber.accent)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            lang.current == language ? Cyber.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(width: 210)
            .background(Cyber.panelBg)
        }
    }

    private var appMenuButton: some View {
        Menu {
            Button(L10n.sidebarSettings) { selectedTab = .settings }
            Button(L10n.menuCheckUpdate) { AppDelegate.shared?.checkForUpdates() }
            Divider()
            Button(L10n.menuQuit) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Cyber.textGhost)
                .frame(width: 26, height: 26)
                .background(Cyber.hoverBg, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
    }

    private var planDisplayName: String {
        authStore.displayPlanName
    }

    @ViewBuilder
    private var contentArea: some View {
        Group {
            switch selectedTab {
            case .home: HomeView()
            case .dictionary: DictionaryView()
            case .persona: PersonaView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .id("\(themeStore.mode.rawValue)-\(themeStore.accent.rawValue)")
    }
}

// MARK: - SidebarItem

private struct SidebarItem: View {
    let icon: String, label: String, isSelected: Bool
    let action: () -> Void
    @State private var isHover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: sidebarIcon(base: icon, selected: isSelected))
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 10)
            .background(
                isSelected ? Cyber.activeBg : (isHover ? Cyber.hoverBg : Color.clear),
                in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
            )
            .foregroundStyle(isSelected ? Cyber.textBright : Cyber.textDim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .pointingHandCursor()
        .onHover { isHover = $0 }
    }

    private func sidebarIcon(base: String, selected: Bool) -> String {
        guard selected else { return base }
        let fillName = base + ".fill"
        if NSImage(systemSymbolName: fillName, accessibilityDescription: nil) != nil { return fillName }
        return base
    }
}

// MARK: - AccountPopoverView

private struct AccountPopoverView: View {
    let onLogout: () -> Void
    @ObservedObject private var authStore = AuthStore.shared
    @ObservedObject private var lang = LanguageManager.shared
    @State private var showCreditDetailsPopover = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Cyber.textGhost)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.accountTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Cyber.textBright)
                        tierBadge
                    }
                    Spacer()
                }

                CyberDivider()

                infoRow(label: L10n.accountEmail, value: authStore.email ?? L10n.notLoggedIn)
                infoRow(label: L10n.accountTier, value: tierDisplayName)

                if authStore.tier == "trial" || authStore.creditsTotal > 0 {
                    creditsSection
                }
            }
            .padding(20)

            if authStore.showInviteCodesEnabled {
                CyberDivider()
                inviteCodesEntry
            }

            CyberDivider()

            Button(action: onLogout) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 13))
                    Text(L10n.logout).font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Cyber.danger.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
        .background(Cyber.panelBg)
    }

    private var tierDisplayName: String {
        authStore.displayPlanName
    }

    private var tierBadge: some View {
        Text(tierDisplayName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Cyber.success)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Cyber.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Cyber.success.opacity(0.25), lineWidth: 1))
    }

    private var creditsSection: some View {
        VStack(spacing: 8) {
            CyberDivider()
            creditsProgressRow
            if let resetDate = authStore.formattedResetDate(locale: currentLocale) {
                infoRow(label: L10n.accountCreditsReset, value: L10n.creditsResetDateLabel(resetDate))
            }
        }
    }

    private var creditsProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.accountCredits)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.textGhost)
                Spacer()
                Text("\(authStore.creditsRemaining) / \(authStore.creditsTotal)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Cyber.textBright)
            }
            HStack {
                Text("\(L10n.accountCreditsUsed) \(authStore.creditsUsed)")
                    .font(.system(size: 10))
                    .foregroundStyle(Cyber.textGhost)
                Spacer()
                Text(L10n.accountCreditsDetailsShow)
                    .font(.system(size: 10))
                    .foregroundStyle(Cyber.accent.opacity(0.75))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Cyber.sidebarBg)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Cyber.accent)
                        .frame(width: geo.size.width * creditsRatio, height: 5)
                }
            }
            .frame(height: 5)
        }
        .contentShape(Rectangle())
        .onTapGesture { showCreditDetailsPopover.toggle() }
        .onHover { hovering in
            showCreditDetailsPopover = hovering
        }
        .popover(isPresented: $showCreditDetailsPopover, arrowEdge: .trailing) {
            CreditDetailsPopover()
        }
    }

    private var creditsRatio: CGFloat {
        guard authStore.creditsTotal > 0 else { return 0 }
        return min(1.0, CGFloat(authStore.creditsRemaining) / CGFloat(authStore.creditsTotal))
    }

    private var currentLocale: Locale {
        lang.current.locale
    }

    @State private var showInviteCodes = false
    private var inviteCodesEntry: some View {
        Button {
            showInviteCodes = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .font(.system(size: 12))
                    .foregroundStyle(Cyber.textGhost)
                Text(L10n.myInviteCodesBtn)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.textGhost)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInviteCodes, arrowEdge: .trailing) {
            MyInviteCodesView(onDismiss: { showInviteCodes = false })
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Cyber.textGhost)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Cyber.textBright)
                .textSelection(.enabled)
        }
    }
}

#Preview { MainView() }
