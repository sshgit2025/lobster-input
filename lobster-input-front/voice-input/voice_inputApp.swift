/// voice_inputApp.swift
/// App 入口 + AppDelegate。
/// 职责: 根据登录态切换主界面/登录界面、菜单栏图标管理、
/// 窗口关闭拦截（隐藏而非退出）、App Nap 防护。
///
/// 激活策略设计（参考 Multi/Raycast 方案）：
///   - Info.plist 设 LSUIElement=YES → 进程级 agent，完全不触发 App 激活
///   - WillFinish: .prohibited → 启动时绝不激活其他 App
///   - DidFinish:  .accessory  → 正常后台运行，菜单栏图标存在，无 Dock 图标
///   - 显示主窗口时临时切为 .regular，关闭后立即 NSApp.hide() + .accessory
///   - 浮窗（NSPanel + .nonactivatingPanel）在 .accessory 策略下永远不激活 App
import SwiftUI
import AppKit
import Darwin
import os.log
import Sparkle

private let appLog = Logger(subsystem: "ssh2026.voice-input", category: "AppDelegate")

@main
struct voice_inputApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var authStore = AuthStore.shared

    var body: some Scene {
        WindowGroup {
            RootContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: CyberLayout.windowW, height: CyberLayout.windowH)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.menuCheckUpdate) {
                    appDelegate.checkForUpdates()
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出龙虾输入法") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            // 主菜单栏"人设"快捷切换入口
            CommandMenu(L10n.menuPersona) {
                if !authStore.isLoggedIn || personaStore.personas.isEmpty {
                    Button(L10n.personaMenuEmpty) {}
                        .disabled(true)
                } else {
                    Button((personaStore.activePersona == nil ? "✓ " : "") + L10n.personaMenuNone) {
                        Task { @MainActor in
                            _ = await PersonaStore.shared.deactivateAll()
                        }
                    }
                    Divider()
                    ForEach(personaStore.personas) { persona in
                        Button((persona.isActive ? "✓ " : "") + persona.name) {
                            Task { @MainActor in
                                _ = await PersonaStore.shared.activate(id: persona.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RootContentView: View {
    @ObservedObject private var authStore = AuthStore.shared
    @ObservedObject private var onboardingManager = OnboardingManager.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        Group {
            if authStore.isLoggedIn {
                if onboardingManager.shouldShowOnboarding {
                    OnboardingView {
                        onboardingManager.markCompleted()
                    }
                } else {
                    MainView()
                }
            } else {
                AuthView()
            }
        }
        .onAppear {
            AppDelegate.shared?.onMainViewAppear()
            AppDelegate.shared?.applyMainWindowTheme(themeStore.mode)
        }
        .onChange(of: authStore.isLoggedIn) { _, loggedIn in
            if loggedIn {
                onboardingManager.checkOnboardingNeeded()
            }
            AppDelegate.shared?.applyMainWindowLayoutForCurrentState(resetFrame: true)
        }
        .onChange(of: onboardingManager.shouldShowOnboarding) { _, _ in
            AppDelegate.shared?.applyMainWindowLayoutForCurrentState(resetFrame: true)
        }
        .onChange(of: themeStore.mode) { _, mode in
            AppDelegate.shared?.applyMainWindowTheme(mode)
        }
        .onChange(of: themeStore.accent) { _, _ in
            AppDelegate.shared?.applyMainWindowTheme(themeStore.mode)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    static weak var shared: AppDelegate?

    // 菜单栏图标
    private var statusItem: NSStatusItem?
    // 防止 App Nap 的活动令牌
    private var backgroundActivity: NSObjectProtocol?
    // Sparkle 自动更新控制器（delegate 设为 self，实现失败静默）
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private weak var cachedMainWindow: NSWindow?
    private var recreatedMainWindow: NSWindow?
    private var isShowingMainWindow = false
    private var singleInstanceLockFD: Int32 = -1
    private var titleBarMouseMonitor: Any?
    private let customTitleBarHeight: CGFloat = 28
    private var lastMainWindowLayout: MainWindowLayout?

    // MARK: - 启动

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }
        // 启动时先设为 prohibited，确保进程启动不激活、不抢走任何 App 的焦点
        // 即使 LSUIElement=YES 已处理，这里再加一道保险
        NSApp.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先注册单例，确保 SwiftUI 首个 RootContentView.onAppear 能拿到 delegate。
        AppDelegate.shared = self

        // 单实例检测：若已有同 Bundle ID 的进程在运行，激活它并退出自身
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let otherInstances = runningInstances.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !otherInstances.isEmpty {
            otherInstances.first?.activate(options: .activateIgnoringOtherApps)
            NSApp.terminate(nil)
            return
        }

        CrashReporter.shared.install()
        LaunchAtLoginStore.registerOnFirstLaunchIfNeeded()
        // 处理 macOS 系统生成的真实崩溃报告，并清理旧版误报的 hang 崩溃记录
        CrashReporter.shared.processPendingCrashReports()
        DebugTrace.clear()
        DebugTrace.log("applicationDidFinishLaunching: activationPolicy -> accessory, tracePath=\(DebugTrace.path)")
        // 1. 切换为 accessory：无 Dock 图标、不参与正常焦点激活链
        //    LSUIElement=YES 已在进程级保证，这里是运行时层面的双重保险
        NSApp.setActivationPolicy(.accessory)

        // 1.5 静默注册辅助功能权限（不弹窗）
        //     非沙盒 App 必须调用 AXIsProcessTrustedWithOptions 才能让系统将 App 注册到 TCC 数据库
        //     这样用户在系统设置里才能看到并授权 App
        PermissionManager.shared.checkAccessibilitySilently()
        PermissionManager.shared.refreshStatuses()
        HotKeyManager.shared.startListening { combo in
            AppHotKeyHandler.shared.handle(combo)
        }

        // 2. 禁止 App Nap，确保后台快捷键监听不被系统节流
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "龙虾输入法 needs to listen for global hotkeys at all times"
        )

        // 3. 设置菜单栏图标
        setupStatusItem()

        // 4. 设置窗口代理（拦截关闭事件）
        setupWindowDelegate()
        installTitleBarDoubleClickMonitor()
    }

    private func acquireSingleInstanceLock() -> Bool {
        let rawBundleID = Bundle.main.bundleIdentifier ?? "ssh2026.voice-input"
        let lockName = rawBundleID.replacingOccurrences(of: "/", with: "_")
        let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(lockName).lock")
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            appLog.error("single instance lock open failed")
            return false
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            singleInstanceLockFD = fd
            appLog.info("single instance lock acquired")
            return true
        }
        close(fd)
        appLog.warning("single instance lock already held")
        return false
    }

    private func activateExistingInstance() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != currentPID }?
            .activate(options: .activateIgnoringOtherApps)
    }

    func onMainViewAppear() {
        // refreshStatuses 内部会在辅助功能权限就绪时自动启动快捷键监听
        PermissionManager.shared.refreshStatuses()

        // 启动时拉取 App 全局配置（无需鉴权，用于决定是否显示邀请码界面）
        Task { await Self.fetchStartupConfig() }

        if AuthStore.shared.isLoggedIn {
            OnboardingManager.shared.checkOnboardingNeeded()
            Task { await Self.fetchRecordingConfig() }
            Task { await Self.fetchUserPlanInfo() }
            // 预载人设列表,供主菜单/状态栏快捷切换入口即时展示
            Task { @MainActor in
                await PersonaStore.shared.load()
            }
            // App 启动后 email 已从 UserDefaults 恢复，此时才能正确定位用户数据目录
            Task { @MainActor in
                HistoryStore.shared.reloadForCurrentUser()
                HotKeyManager.shared.reloadForCurrentUser()
            }
            // 启动时上报状态快照，用于远程排查权限和 OpenClaw 问题
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await LogReporter.shared.reportSnapshot(reason: "AppLaunch")
                // 自动上报上次遗留的崩溃报告（静默，不打扰用户）
                await CrashReporter.shared.uploadUnreported()
            }
        }
        configureMainWindowIfNeeded()
        applyMainWindowLayoutForCurrentState(resetFrame: false)
        // 主视图初次出现时激活主窗口（切 regular → 激活 → 显示）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.activateMainWindow()
        }
    }

    // MARK: - 激活主窗口（临时切 regular）

    private func activateMainWindow() {
        let window = ensureMainWindowForActivation()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyMainWindowTheme()
        applyMainWindowLayoutForCurrentState(resetFrame: false)
        window?.makeKeyAndOrderFront(nil)
        DebugTrace.log("MainWindow activate: windowExists=\(window != nil), appWindows=\(NSApp.windows.count)")
        appLog.info("MainWindow activate: windowExists=\(window != nil), appWindows=\(NSApp.windows.count)")
    }

    /// 从后端拉取录音配置并覆盖 AudioRecorder 的默认 maxDuration。
    /// 若后端返回 401/403（用户不存在或被禁用），强制退出登录态。
    static func fetchRecordingConfig() async {
        appLog.info("fetchRecordingConfig: start")
        do {
            let config = try await APIClient.shared.fetchRecordingConfig()
            appLog.info("fetchRecordingConfig: got maxDurationSec=\(config.maxDurationSec)")
            await MainActor.run {
                let before = AudioRecorder.shared.maxDuration
                AudioRecorder.shared.maxDuration = TimeInterval(config.maxDurationSec)
                appLog.info("fetchRecordingConfig: maxDuration \(before) -> \(AudioRecorder.shared.maxDuration)")
            }
        } catch APIError.unauthorized, APIError.userBanned {
            appLog.warning("fetchRecordingConfig: auth rejected, forcing logout")
            await MainActor.run { AuthStore.shared.logout() }
        } catch {
            appLog.error("fetchRecordingConfig failed: \(error.localizedDescription)")
        }
    }

    /// 从后端拉取 App 启动全局配置（无需鉴权），更新邀请码开关等
    static func fetchStartupConfig() async {
        appLog.info("fetchStartupConfig: start")
        do {
            let config = try await APIClient.shared.fetchStartupConfig()
            await MainActor.run {
                AuthStore.shared.updateStartupConfig(config)
                appLog.info("fetchStartupConfig: inviteCodeEnabled=\(config.inviteCodeEnabled)")
            }
        } catch {
            appLog.error("fetchStartupConfig failed: \(error.localizedDescription)")
        }
    }

    /// 从后端拉取当前用户套餐积分信息，同时验证账号有效性。
    /// 若后端返回 401/403（用户不存在或被禁用），强制退出登录态。
    @discardableResult
    static func fetchUserPlanInfo() async -> Bool {
        appLog.info("fetchUserPlanInfo: start")
        do {
            let info = try await APIClient.shared.fetchUserPlanInfo()
            await MainActor.run {
                AuthStore.shared.updatePlanInfo(info)
                appLog.info("fetchUserPlanInfo: remaining=\(info.creditsRemaining)/\(info.creditsTotal)")
            }
            return true
        } catch APIError.unauthorized, APIError.userBanned {
            appLog.warning("fetchUserPlanInfo: auth rejected, forcing logout")
            await MainActor.run { AuthStore.shared.logout() }
            return false
        } catch {
            appLog.error("fetchUserPlanInfo failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Dock 图标点击 → 恢复主窗口（LSUIElement=YES 下不会触发，保留以防政策变化）

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !isShowingMainWindow else { return false }
        showMainWindow()
        return false
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(recording: false)

        // 左键点击显示/隐藏主窗口
        if let btn = statusItem?.button {
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 监听录音状态变化，更新图标
        NotificationCenter.default.addObserver(
            forName: .audioRecorderStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isRecording = notification.userInfo?["recording"] as? Bool ?? false
            self?.updateStatusIcon(recording: isRecording)
        }
    }

    private func updateStatusIcon(recording: Bool) {
        let iconName = recording ? "waveform.circle.fill" : "waveform.circle"
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "龙虾输入法")
            btn.image?.isTemplate = !recording  // 录音中用彩色，否则跟随系统主题
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        showStatusMenu()
    }

    // MARK: - 更新状态机
    enum UpdateCheckState: Int, Equatable {
        case idle = 0
        case checking = 1
        case downloading = 2
        case noUpdate = 3
        case updateFound = 4
        case error = 5
        case devBuild = 6

        var isSpinning: Bool { self == .checking || self == .downloading }
    }

    @objc dynamic var updateCheckStateRaw: Int = 0

    var updateCheckState: UpdateCheckState = .idle {
        didSet { updateCheckStateRaw = updateCheckState.rawValue }
    }

    private enum UpdateState {
        case idle        // 可点击"检查更新"
        case checking    // 检查中，禁用
        case downloading // 下载中，禁用

        var title: String {
            switch self {
            case .idle:        return L10n.menuCheckUpdate
            case .checking:    return L10n.menuChecking
            case .downloading: return L10n.menuDownloading
            }
        }
        var isEnabled: Bool { self == .idle }
    }
    private var updateState: UpdateState = .idle

    // MARK: - 崩溃日志上报状态
    private enum CrashUploadState {
        case idle        // 有未上报日志或无日志，均可点击
        case uploading   // 上报中，禁用
    }
    private var crashUploadState: CrashUploadState = .idle

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.menuShowMain, action: #selector(showMainWindow), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.menuPermissions, action: #selector(openPermissions), keyEquivalent: "")
            .target = self

        menu.addItem(microphoneMenuItem())

        if AuthStore.shared.isLoggedIn {
            menu.addItem(personaMenuItem())
        }

        let updateItem = NSMenuItem(
            title: updateState.title,
            action: updateState.isEnabled ? #selector(checkForUpdates) : nil,
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.isEnabled = updateState.isEnabled
        menu.addItem(updateItem)

        // 崩溃日志上报菜单项（仅有未上报日志时高亮提示）
        let unreportedCount = CrashReporter.shared.loadUnreported().count
        let crashTitle: String
        if crashUploadState == .uploading {
            crashTitle = L10n.menuCrashUploading
        } else if unreportedCount > 0 {
            crashTitle = L10n.menuCrashUpload(unreportedCount)
        } else {
            crashTitle = L10n.menuCrashNoLog
        }
        let crashItem = NSMenuItem(
            title: crashTitle,
            action: (crashUploadState == .idle && unreportedCount > 0) ? #selector(uploadCrashLogs) : nil,
            keyEquivalent: ""
        )
        crashItem.target = self
        crashItem.isEnabled = crashUploadState == .idle && unreportedCount > 0
        menu.addItem(crashItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.menuQuit, action: #selector(quitApp), keyEquivalent: "q")
            .target = self
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func microphoneMenuItem() -> NSMenuItem {
        let manager = MicrophoneDeviceManager.shared
        manager.refreshDevices()
        let item = NSMenuItem(title: L10n.microphoneMenuTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let defaultItem = NSMenuItem(title: manager.defaultSelectionTitle, action: #selector(selectDefaultMicrophone), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = manager.selectedDeviceUID == nil ? .on : .off
        submenu.addItem(defaultItem)

        if !manager.devices.isEmpty {
            submenu.addItem(.separator())
        }
        for device in manager.devices {
            let deviceItem = NSMenuItem(title: device.name + (device.isDefault ? L10n.microphoneCurrentDefaultSuffix : ""), action: #selector(selectMicrophoneDevice(_:)), keyEquivalent: "")
            deviceItem.target = self
            deviceItem.representedObject = device.id
            deviceItem.state = manager.selectedDeviceUID == device.id ? .on : .off
            submenu.addItem(deviceItem)
        }

        item.submenu = submenu
        return item
    }

    /// 状态栏"人设"快捷切换子菜单:列出全部人设,支持一键激活/取消激活
    private func personaMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.menuPersona, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let personas = PersonaStore.shared.personas
        if personas.isEmpty {
            // 首次打开时后台拉取,下次展开即可见列表
            Task { @MainActor in
                await PersonaStore.shared.load()
            }
            let empty = NSMenuItem(title: L10n.personaMenuEmpty, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            let none = NSMenuItem(title: L10n.personaMenuNone, action: #selector(deactivateAllPersonas), keyEquivalent: "")
            none.target = self
            none.state = PersonaStore.shared.activePersona == nil ? .on : .off
            submenu.addItem(none)
            submenu.addItem(.separator())
            for persona in personas {
                let personaItem = NSMenuItem(title: persona.name, action: #selector(activatePersona(_:)), keyEquivalent: "")
                personaItem.target = self
                personaItem.representedObject = persona.id
                personaItem.state = persona.isActive ? .on : .off
                submenu.addItem(personaItem)
            }
        }
        item.submenu = submenu
        return item
    }

    @objc private func activatePersona(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { @MainActor in
            _ = await PersonaStore.shared.activate(id: id)
        }
    }

    @objc private func deactivateAllPersonas() {
        Task { @MainActor in
            _ = await PersonaStore.shared.deactivateAll()
        }
    }

    @objc private func selectDefaultMicrophone() {
        MicrophoneDeviceManager.shared.selectDefault()
    }

    @objc private func selectMicrophoneDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        MicrophoneDeviceManager.shared.selectDevice(uid: uid)
    }

    @objc private func uploadCrashLogs() {
        guard crashUploadState == .idle else { return }
        guard AuthStore.shared.isLoggedIn else {
            showMainWindow()
            let count = CrashReporter.shared.loadUnreported().count
            showCrashUploadResult(CrashUploadResult(
                attempted: count, succeeded: 0, failed: count, isAuthenticated: false
            ))
            return
        }
        crashUploadState = .uploading
        Task { @MainActor in
            let result = await CrashReporter.shared.uploadUnreported()
            self.crashUploadState = .idle
            if result.succeeded > 0 {
                appLog.info("Crash logs uploaded: \(result.succeeded)")
            }
            self.showCrashUploadResult(result)
        }
    }

    private func showCrashUploadResult(_ result: CrashUploadResult) {
        let alert = NSAlert()
        alert.messageText = L10n.appNameFull
        alert.addButton(withTitle: L10n.btnDone)
        alert.alertStyle = result.failed == 0 && result.isAuthenticated ? .informational : .warning
        if !result.isAuthenticated {
            alert.informativeText = L10n.crashUploadLoginRequired
        } else if result.failed == 0 {
            alert.informativeText = L10n.crashUploadSuccess(result.succeeded)
        } else if result.succeeded > 0 {
            alert.informativeText = L10n.crashUploadPartial(result.succeeded, result.failed)
        } else {
            alert.informativeText = L10n.crashUploadFailed(result.failed)
        }
        alert.runModal()
    }

    @objc func checkForUpdates() {
        NSLog("[UpdateCheck] checkForUpdates called")
        // 开发版（updater 未安装 Sparkle appcast）直接给出提示，不触发网络请求
        let isDevBuild = !updaterController.updater.sessionInProgress &&
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil
        NSLog("[UpdateCheck] isDevBuild=\(isDevBuild), SUFeedURL=\(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "nil")")
        if isDevBuild {
            updateCheckState = .devBuild
            resetUpdateCheckStateAfterDelay()
            return
        }
        updateCheckState = .checking
        updateState = .checking
        updaterController.checkForUpdates(nil)
    }

    private func resetUpdateCheckStateAfterDelay(_ delay: Double = 3.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.updateCheckState = .idle
        }
    }

    @objc func showMainWindow() {
        guard !isShowingMainWindow else { return }
        isShowingMainWindow = true
        activateMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isShowingMainWindow = false
        }
    }

    func applyMainWindowTheme(_ mode: AppThemeMode = ThemeStore.shared.mode) {
        DispatchQueue.main.async { [weak self] in
            self?.updateMainWindowTheme(mode)
        }
    }

    private func toggleMainWindow() {
        if let win = mainWindow, win.isVisible {
            hideMainWindow()
        } else {
            activateMainWindow()
        }
    }

    /// 隐藏主窗口，调用 NSApp.hide() 让 App 完全退出 active 状态，并切回 accessory
    private func hideMainWindow() {
        // NSApp.hide(nil) 会连带隐藏 App 的所有窗口（含常驻结果浮窗、录音中浮窗）。
        // 先记录此刻可见的非激活浮窗，hide 后再把它们重新前置，保证关闭主窗口不误伤浮窗。
        let visiblePanels = NSApp.windows.filter { $0 is NSPanel && $0.isVisible }
        mainWindow?.orderOut(nil)
        // NSApp.hide() 确保 App 彻底释放 active 状态，避免后续输入焦点被主程序占用。
        NSApp.hide(nil)
        NSApp.setActivationPolicy(.accessory)
        // 重新前置浮窗：nonactivatingPanel 不会让 App 重新变为 active，不影响焦点归还。
        for panel in visiblePanels {
            panel.orderFrontRegardless()
        }
    }

    @objc private func openPermissions() {
        showMainWindow()
        // 稍微延迟，等主窗口显示后再弹权限面板
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            PermissionWindowManager.shared.show()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 窗口代理（拦截关闭）

    private func setupWindowDelegate() {
        // 延迟等窗口创建完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.configureMainWindowIfNeeded()
        }
    }

    private func installTitleBarDoubleClickMonitor() {
        guard titleBarMouseMonitor == nil else { return }
        titleBarMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  event.clickCount >= 2,
                  let window = event.window,
                  window === self.mainWindow,
                  self.isPointInCustomTitleBar(event.locationInWindow, window: window) else {
                return event
            }
            DebugTrace.log("MainWindow: custom title bar double click -> performZoom")
            window.performZoom(nil)
            return nil
        }
    }

    private func isPointInCustomTitleBar(_ point: NSPoint, window: NSWindow) -> Bool {
        let contentHeight = window.contentView?.bounds.height ?? window.frame.height
        return point.y >= max(0, contentHeight - customTitleBarHeight)
    }

    private func configureMainWindowIfNeeded() {
        guard let window = mainWindow else { return }
        cachedMainWindow = window
        window.delegate = self
        window.isReleasedWhenClosed = false
        updateMainWindowTheme(ThemeStore.shared.mode)
        applyMainWindowLayoutForCurrentState(resetFrame: false)
        closeDuplicateMainWindows(keeping: window)
    }

    @MainActor
    private func ensureMainWindowForActivation() -> NSWindow? {
        if let window = mainWindow {
            configureMainWindowIfNeeded()
            return window
        }

        DebugTrace.log("MainWindow missing before activation; recreating fallback window")
        appLog.warning("MainWindow missing before activation; recreating fallback window")

        let layout = MainWindowLayout.current()
        let window = NSWindow(
            contentRect: layout.centeredFrame(on: NSScreen.main),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.appNameFull
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RootContentView())
        recreatedMainWindow = window
        cachedMainWindow = window
        configureMainWindowIfNeeded()
        return window
    }

    private var mainWindow: NSWindow? {
        if let cachedMainWindow, NSApp.windows.contains(cachedMainWindow) {
            return cachedMainWindow
        }
        return NSApp.windows.first(where: isMainWindowCandidate)
    }

    private func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), window.contentView != nil else { return false }
        // 优先用稳定 identifier 排除反馈窗/权限窗：本地化标题会随运行时切换语言改变，
        // 仅靠标题会在切语言后把已打开的反馈窗误判为重复主窗口而强制关闭。
        if let identifier = window.identifier?.rawValue,
           identifier == FeedbackWindowController.windowIdentifier || identifier == PermissionWindowManager.windowIdentifier {
            return false
        }
        guard window.title != "权限设置", window.title != L10n.feedbackTitle else { return false }
        return window.styleMask.contains(.titled)
    }

    private func closeDuplicateMainWindows(keeping keptWindow: NSWindow) {
        for window in NSApp.windows where window !== keptWindow && isMainWindowCandidate(window) {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
    }

    private func updateMainWindowTheme(_ mode: AppThemeMode) {
        guard let window = mainWindow else { return }
        let isDark = mode == .sandDark
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.backgroundColor = NSColor(Cyber.bgTop)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.contentView?.appearance = window.appearance
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor(Cyber.bgTop).cgColor
    }

    @MainActor
    func applyMainWindowLayoutForCurrentState(resetFrame: Bool) {
        guard let window = mainWindow else { return }
        let layout = MainWindowLayout.current()
        let changed = lastMainWindowLayout != layout
        lastMainWindowLayout = layout

        window.styleMask.insert(.resizable)
        window.minSize = layout.minSize
        window.maxSize = layout.maxSize(for: window.screen)
        window.contentMinSize = layout.minSize
        window.contentMaxSize = window.maxSize

        let shouldReset = resetFrame || changed || layout.shouldReset(frame: window.frame, on: window.screen)
        if shouldReset {
            window.setFrame(layout.centeredFrame(on: window.screen), display: true, animate: false)
        }
    }

    private func standardFrameForCurrentLayout(window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let layout = MainWindowLayout.current()
        switch layout {
        case .auth:
            return layout.centeredFrame(on: window.screen)
        case .onboarding, .main:
            return layout.zoomedFrame(on: window.screen, fallback: defaultFrame)
        }
    }
}

// MARK: - NSWindowDelegate（拦截关闭 → 隐藏）

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 点 X 只隐藏，不退出进程；同时彻底释放 App active 状态
        hideMainWindow()
        return false
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        standardFrameForCurrentLayout(window: window, defaultFrame: newFrame)
    }
}

private enum MainWindowLayout: Equatable {
    case auth
    case onboarding
    case main

    static func current() -> MainWindowLayout {
        if !AuthStore.shared.isLoggedIn {
            return .auth
        }
        if OnboardingManager.shared.shouldShowOnboarding {
            return .onboarding
        }
        return .main
    }

    var defaultSize: NSSize {
        switch self {
        case .auth:
            return NSSize(width: 640, height: 620)
        case .onboarding, .main:
            return NSSize(width: CyberLayout.windowW, height: CyberLayout.windowH)
        }
    }

    var minSize: NSSize {
        switch self {
        case .auth:
            return NSSize(width: 520, height: 520)
        case .onboarding, .main:
            return NSSize(width: 900, height: 640)
        }
    }

    func maxSize(for screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSSize(
            width: max(minSize.width, visible.width - 32),
            height: max(minSize.height, visible.height - 32)
        )
    }

    func centeredFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxSize = maxSize(for: screen)
        let size = NSSize(
            width: min(defaultSize.width, maxSize.width),
            height: min(defaultSize.height, maxSize.height)
        )
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    func zoomedFrame(on screen: NSScreen?, fallback: NSRect) -> NSRect {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let visible else { return fallback }
        let maxSize = maxSize(for: screen)
        let size = NSSize(
            width: min(visible.width, maxSize.width),
            height: min(visible.height, maxSize.height)
        )
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    func shouldReset(frame: NSRect, on screen: NSScreen?) -> Bool {
        let maxSize = maxSize(for: screen)
        return frame.width > maxSize.width + 1
            || frame.height > maxSize.height + 1
            || frame.width < minSize.width - 1
            || frame.height < minSize.height - 1
    }
}

// MARK: - SPUUpdaterDelegate（更新状态管理 + 失败静默）

extension AppDelegate: SPUUpdaterDelegate {

    // 无新版本可用（已是最新）→ 恢复 idle，静默不弹窗
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateState = .idle
        updateCheckState = .noUpdate
        resetUpdateCheckStateAfterDelay(3.0)
    }

    // 找到新版本，准备下载 → 切换到 downloading 状态（Sparkle 自己弹更新对话框）
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        updateState = .downloading
        updateCheckState = .updateFound
    }

    // 下载完成，Sparkle 接管安装/重启流程 → 保持 downloading 禁用，防止重复触发
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {}

    // 检查/网络失败 → 恢复 idle，静默不弹窗，用户可手动重试
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateState = .idle
        updateCheckState = .error
        resetUpdateCheckStateAfterDelay(3.0)
    }

    // 下载失败 → 恢复 idle，静默不弹窗
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        updateState = .idle
        updateCheckState = .error
        resetUpdateCheckStateAfterDelay(3.0)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let audioRecorderStateChanged = Notification.Name("audioRecorderStateChanged")
    /// 录音达到最大时长（60秒），由 AudioRecorder 发出
    static let recordingMaxDurationReached = Notification.Name("recordingMaxDurationReached")
    /// 用户在录音中点击浮窗关闭按钮，放弃本次录音
    static let overlayDismissedDuringRecording = Notification.Name("overlayDismissedDuringRecording")
    /// 用户在识别中点击浮窗关闭按钮，取消等待识别结果
    static let overlayDismissedDuringProcessing = Notification.Name("overlayDismissedDuringProcessing")
    /// 用户在实时识别中点击浮窗关闭按钮，放弃本次流式识别
    static let realtimeOverlayDismissedDuringStreaming = Notification.Name("realtimeOverlayDismissedDuringStreaming")
}
