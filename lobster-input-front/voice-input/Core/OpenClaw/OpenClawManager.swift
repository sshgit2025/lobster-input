/// OpenClawManager.swift
/// 管理 OpenClaw 的安装检测、一键安装、服务状态探活和 Gateway RPC 通信。
/// 对话通信使用 OpenClaw Gateway RPC（sessions.send / sessions.get / sessions.abort），
/// 可以可靠中断同一 session 中正在运行的任务。
import Foundation
import Combine
import AppKit

/// OpenClaw 安装/服务状态
enum OpenClawStatus: Equatable {
    case unknown
    case notInstalled
    case installedServiceDown
    case ready
}

@MainActor
final class OpenClawManager: ObservableObject {

    static let shared = OpenClawManager()

    @Published private(set) var status: OpenClawStatus = .unknown

    /// 客户端本地 OpenClaw agent 语音会话状态。仅保存在当前 App 进程内，重启后自动关闭。
    /// 该状态对应用户口述“开启/关闭大虾”的 agent 意图，不等同于首页 gateway 进程运行状态。
    @Published private(set) var agentSessionActive: Bool = false

    /// 当前语音 OpenClaw 对话使用的 Gateway session key。App 启动即生成新 key，相当于清空历史。
    @Published private(set) var agentSessionKey: String = OpenClawManager.makeAgentSessionKey()

    /// 正在等待 gateway 启动中（用于按钮 loading 状态）
    @Published private(set) var isStartingGateway: Bool = false

    private var checkTimer: Timer?

    /// openclaw 二进制路径缓存。安装路径极少变化，每次使用前仅做 isExecutableFile 快速校验，
    /// 失效（卸载/移动）时自动清空并由下一次慢速解析回填。
    private var cachedBinaryPath: String?

    /// 正在进行的 login-shell 解析任务（并发合并：多处同时请求只 spawn 一个子进程）
    private var shellResolveTask: Task<String?, Never>?

    /// 用于复用 openclaw 专属终端窗口（通过 Terminal window id 追踪）
    private var openClawWindowId: Int? = nil
    private var activeGatewayRunId: String?
    private var activeGatewayTask: Task<Void, Never>?
    private var activeGatewayRequestId: UUID?

    private init() {
        Task { await refresh() }
        startPeriodicCheck()
    }

    /// 将 status 转换为后端 openclaw_status 字段的字符串值
    var statusString: String? {
        switch status {
        case .unknown:              return nil
        case .notInstalled:         return "not_installed"
        case .installedServiceDown: return "service_down"
        case .ready:                return "installed"
        }
    }

    var agentSessionActiveForRequest: Bool {
        agentSessionActive
    }

    func handleSessionTipCode(_ code: String) {
        switch code {
        case "OPENCLAW_SESSION_STARTED":
            if !agentSessionActive {
                resetAgentSessionKey()
            }
            agentSessionActive = true
        case "OPENCLAW_NEW_SESSION_STARTED":
            resetAgentSessionKey()
            agentSessionActive = true
        case "OPENCLAW_ALREADY_ACTIVE":
            agentSessionActive = true
        case "OPENCLAW_SESSION_ENDED", "OPENCLAW_NOT_INSTALLED", "OPENCLAW_SERVICE_DOWN":
            agentSessionActive = false
        default:
            break
        }
    }

    // MARK: - 状态检测

    func refresh() async {
        let installed = await isInstalled()
        if !installed {
            status = .notInstalled
            agentSessionActive = false
            return
        }
        let running = await isGatewayRunning()
        status = running ? .ready : .installedServiceDown
        if status != .ready {
            agentSessionActive = false
        }
    }

    /// 检测 openclaw 是否完整安装：binary 可访问 AND config 目录存在。
    /// 仅有 binary（npm 包残留但 config 已删）视为未安装，需重新安装或重新 onboard。
    private func isInstalled() async -> Bool {
        // 1. config 目录必须存在
        guard isConfigDirectoryPresent() else { return false }
        return await resolveBinaryPathSlow() != nil
    }

    /// 使用 OpenClaw 2026.5.27 的 Gateway RPC 深度状态命令探活。
    private func isGatewayRunning() async -> Bool {
        guard let binaryPath = await resolveBinaryPathSlow() else { return false }
        guard let status = await runOpenClawJSON(
            binaryPath: binaryPath,
            arguments: ["gateway", "status", "--json", "--require-rpc", "--deep"],
            timeout: 12
        ) else { return false }
        let rpc = status["rpc"] as? [String: Any]
        return rpc?["ok"] as? Bool == true
    }

    func diagnosticSnapshot() -> [String: String] {
        let credential = readGatewayCredential()
        let binaryPath = fastResolveBinaryPath() ?? ""
        return [
            "configExists": isConfigDirectoryPresent() ? "true" : "false",
            "binaryFound": binaryPath.isEmpty ? "false" : "true",
            "binaryPath": binaryPath.isEmpty ? "not_found" : binaryPath,
            "credentialMode": credential?.mode ?? "missing",
            "credentialExists": credential == nil ? "false" : "true",
            "gatewayURL": APIConfig.OpenClaw.gatewayBase,
            "status": statusString ?? "unknown",
            "agentSessionActive": agentSessionActiveForRequest ? "true" : "false",
            "agentSessionKey": agentSessionKey,
        ]
    }

    // MARK: - 定时检测（60s 间隔）

    /// 周期探活仅用于让首页状态灯与后端上报字段保持大致新鲜；
    /// 真正调用 OpenClaw 的路径（发送/中断）都会当场重新解析，不依赖这里的节拍。
    /// 曾为 15s：高频探活叠加主线程同步 spawn 在系统资源紧张时会放大为整机级卡死。
    private func startPeriodicCheck() {
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        timer.tolerance = 5
        checkTimer = timer
    }

    // MARK: - 一键安装

    /// 弹出系统终端执行官方一键安装脚本。
    /// 安装完成后 openclaw 通过 npm 全局注册，app 轮询最多 5 分钟自动更新状态。
    /// 检测到安装成功后，自动确保 gateway.mode 已配置（防止 onboarding 未完成导致无法启动）。
    func launchInstaller() {
        let script = "curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash"
        runInNewTerminalWindow(script)
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                let wasNotInstalled = status == .notInstalled
                await refresh()
                if wasNotInstalled && status != .notInstalled {
                    // 安装完成后，静默修复 gateway.mode 未配置的问题
                    ensureGatewayModeConfigured()
                    break
                }
            }
        }
    }

    /// 静默检查 openclaw.json 中 gateway.mode 是否已就绪，缺失时自动修复。
    private func ensureGatewayModeConfigured() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let gateway = json["gateway"] as? [String: Any] ?? [:]

        if gateway["mode"] == nil {
            runSilent(openClawShellCommand(arguments: ["config", "set", "gateway.mode", "local"]))
        }
    }

    /// 静默执行 shell 命令（login shell，确保 PATH 包含 nvm/npm）
    private func runSilent(_ command: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", command]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
    }

    // MARK: - 一键卸载

    /// 在新终端窗口执行完整卸载：先用官方命令清理配置，再 npm rm -g openclaw 移除 binary。
    /// 官方 uninstall --all 只清配置目录，不会自动移除 npm 全局包，需要手动补充。
    func launchUninstaller() {
        let cmd = "\(openClawShellCommand(arguments: ["gateway", "stop", "--json"])) || true; \(openClawShellCommand(arguments: ["uninstall", "--all", "--yes", "--non-interactive"])); npm rm -g openclaw 2>/dev/null || true; echo '--- OpenClaw 已完全卸载 ---'"
        runInNewTerminalWindow(cmd)
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refresh()
                if status == .notInstalled { break }
            }
        }
    }

    // MARK: - Gateway 启动 / 停止

    /// 在新终端窗口中启动 openclaw gateway，用户可见启动过程和日志。
    /// 启动策略：
    ///   0. 若 gateway 已运行（RPC 探活成功），直接刷新状态返回
    ///   1. 先尝试 `gateway start --json`
    ///   2. 不就绪时尝试 `gateway install --json`
    ///   3. 最终回退到 `gateway run --force`
    func startGateway() {
        guard !isStartingGateway else { return }
        isStartingGateway = true

        Task {
            // 步骤 0：若 gateway 已运行，无需重复启动
            if await isGatewayRunning() {
                await refresh()
                isStartingGateway = false
                return
            }

            ensureGatewayModeConfigured()

            runInNewTerminalWindow(openClawShellCommand(arguments: ["gateway", "start", "--json"]))

            // 第一阶段：等待最多 45 秒
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if await isGatewayRunning() {
                    await refresh()
                    isStartingGateway = false
                    return
                }
            }

            // 第二阶段：检查是否为 mode=unset 问题，自动修复后重试
            let hasModeProblem = gatewayLogContainsModeError()
            if hasModeProblem {
                ensureGatewayModeConfigured()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                runInNewTerminalWindow(openClawShellCommand(arguments: ["gateway", "start", "--json"]))
            } else {
                let install = openClawShellCommand(arguments: ["gateway", "install", "--json"])
                let run = openClawShellCommand(arguments: ["gateway", "run", "--force"])
                runInNewTerminalWindow("\(install) || \(run)")
            }

            // 再等 45 秒
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if await isGatewayRunning() { break }
            }
            await refresh()
            isStartingGateway = false
        }
    }

    /// 读取 gateway 错误日志，判断是否包含 mode=unset 错误。
    private func gatewayLogContainsModeError() -> Bool {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/logs/gateway.err.log")
        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else { return false }
        return content.contains("gateway.mode=local (current: unset)")
    }

    /// 停止 openclaw gateway 服务（在终端窗口执行，用户可见输出）。
    /// 使用 `stop` 仅停止进程，保留 launchd 服务注册，下次可直接 `start` 启动。
    /// 不使用 `uninstall`，避免清除注册信息导致下次被迫重新 `install`。
    func stopGateway() {
        agentSessionActive = false
        resetAgentSessionKey()
        runInNewTerminalWindow(openClawShellCommand(arguments: ["gateway", "stop", "--json"]))
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refresh()
        }
    }

    // MARK: - OpenClaw Gateway RPC 通信

    /// 向 openclaw 发送自然语言任务文本（TEXT 模式）。
    /// 走 Gateway RPC sessions.send，任务可通过 sessions.abort 中断。
    /// - Parameters:
    ///   - text: 用户语音指令（已经过后端识别）
    ///   - selectedText: 录音时鼠标选中的文本（可选）。有值时以结构化上下文块追加到消息前，
    ///     让 OpenClaw 自行决定是否将其作为操作对象，不强制绑定。
    ///   - onComplete: 完成后回调，用于更新历史记录为 OpenClaw 实际输出
    func sendToOpenClaw(
        _ text: String,
        selectedText: String? = nil,
        clipboardItems: [ClipboardContextItem]? = nil,
        onComplete: ((String) -> Void)? = nil
    ) {
        let message = buildOpenClawMessage(
            instruction: text,
            selectedText: selectedText,
            clipboardItems: clipboardItems
        )
        let attachments = buildOpenClawAttachments(from: clipboardItems)
        startGatewayTask(message: message, attachments: attachments, onComplete: onComplete)
    }

    /// 构建发送给 OpenClaw 的消息体。
    /// 有选中文本时，在指令前追加结构化上下文块，让 OpenClaw 自行决定是否使用：
    ///   [当前选中的文本]
    ///   ---
    ///   <选中内容>
    ///   ---
    ///   <用户指令>
    /// 无选中文本时直接发送指令，不引入任何额外噪声。
    private func buildOpenClawMessage(
        instruction: String,
        selectedText: String?,
        clipboardItems: [ClipboardContextItem]?
    ) -> String {
        var contextBlocks: [String] = []

        if let selected = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            contextBlocks.append("""
            [当前选中的文本]
            ---
            \(selected)
            ---
            """)
        }

        let clipboardTexts = (clipboardItems ?? [])
            .compactMap { item -> String? in
                guard item.kind == "text",
                      let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return text
            }
        if !clipboardTexts.isEmpty {
            contextBlocks.append("""
            [剪贴板文本]
            ---
            \(clipboardTexts.joined(separator: "\n\n---\n\n"))
            ---
            """)
        }

        let imageCount = (clipboardItems ?? []).filter { $0.kind == "image" && ($0.dataUrl?.isEmpty == false) }.count
        if imageCount > 0 {
            contextBlocks.append("[剪贴板图片]\n已随本次请求附加 \(imageCount) 张图片。")
        }

        guard !contextBlocks.isEmpty else {
            return instruction
        }

        return (contextBlocks + [instruction]).joined(separator: "\n\n")
    }

    private func buildOpenClawAttachments(from clipboardItems: [ClipboardContextItem]?) -> [[String: Any]] {
        (clipboardItems ?? []).enumerated().compactMap { index, item in
            guard item.kind == "image",
                  let dataUrl = item.dataUrl,
                  !dataUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return [
                "type": "image",
                "mimeType": item.mimeType ?? "image/png",
                "fileName": "clipboard-\(index + 1).\(item.mimeType == "image/jpeg" ? "jpg" : "png")",
                "content": dataUrl,
            ]
        }
    }

    /// 向 openclaw 发送精确命令（COMMAND 模式）。
    /// 路由策略：
    ///   - /stop 或 stop → Gateway RPC sessions.abort（中断当前会话活跃任务）
    ///   - 其他 slash 命令 → Gateway RPC sessions.send（发到 agent 会话）
    ///   - 交互式 CLI 命令（auth login、onboard 等）→ 新独立终端（需要用户交互）
    ///   - 普通 CLI 命令（status、logs 等）→ 复用 openclaw 专属终端窗口
    func sendCommandToOpenClaw(_ command: String, onComplete: ((String) -> Void)? = nil) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isAbortCommand(trimmed) {
            abortCurrentOpenClawTask(onComplete: onComplete, showFeedback: true)
        } else if trimmed.hasPrefix("/") {
            startGatewayTask(message: trimmed, onComplete: onComplete)
        } else if isInteractiveCommand(trimmed) {
            guard isSafeOpenClawTerminalCommand(trimmed) else {
                rejectUnsafeOpenClawCommand(trimmed, onComplete: onComplete)
                return
            }
            runInNewTerminalWindow(trimmed)
        } else {
            guard isSafeOpenClawTerminalCommand(trimmed) else {
                rejectUnsafeOpenClawCommand(trimmed, onComplete: onComplete)
                return
            }
            sendToOpenClawTerminal(trimmed)
        }
    }

    /// 校验一条「要原样送进 Terminal 执行」的命令是否为安全的 openclaw 调用。
    /// 命令文本来自后端 `result`（LLM 生成），若被提示注入或后端被仿冒，可能是任意 shell 命令。
    /// 此处把它从「任意 shell 命令」收敛为「仅 openclaw 子命令」：
    ///   1) 首个 token 必须是 openclaw 或指向 openclaw 二进制的路径；
    ///   2) 不含能改变 shell 语义的命令串联/管道/命令替换/重定向/换行等元字符。
    /// 注意：launchInstaller / startGateway 等 App 自身构造的可信命令直接走 runInNewTerminalWindow，
    /// 不经过本函数，故其中的 `||`、`PATH=...:$PATH` 不受影响。
    private func isSafeOpenClawTerminalCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let dangerousTokens = [";", "&", "|", "`", "$(", "${", ">", "<", "\n", "\r", "\\"]
        if dangerousTokens.contains(where: { trimmed.contains($0) }) {
            return false
        }

        guard let firstToken = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return false
        }
        let head = String(firstToken)
        return head == "openclaw" || head.hasSuffix("/openclaw")
    }

    private func rejectUnsafeOpenClawCommand(_ command: String, onComplete: ((String) -> Void)? = nil) {
        DebugTrace.log("OpenClaw: rejected unsafe terminal command (not a plain openclaw invocation)")
        let message = "出于安全考虑，已拒绝执行非 openclaw 命令。"
        OpenClawTaskOverlayWindowController.shared.showError(message)
        onComplete?(message)
    }

    // MARK: - Gateway 配置读取

    /// 读取本地 openclaw.json 中的 gateway 认证凭证。
    /// 支持两种模式（对应官方文档 gateway.auth.mode）：
    ///   - token（默认）：返回 gateway.auth.token
    ///   - password：返回 gateway.auth.password
    /// 认证与底层 AI provider（OpenAI/Claude/本地模型等）完全无关，
    /// token 是 openclaw onboarding 向导自动生成的本地访问凭证。
    func readGatewayCredential() -> (mode: String, value: String)? {
        let cfgPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
        guard let data = try? Data(contentsOf: cfgPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gw = json["gateway"] as? [String: Any],
              let auth = gw["auth"] as? [String: Any] else { return nil }

        let mode = auth["mode"] as? String ?? "token"
        if mode == "password", let pw = auth["password"] as? String, !pw.isEmpty {
            return ("password", pw)
        }
        if let token = auth["token"] as? String, !token.isEmpty {
            return ("token", token)
        }
        return nil
    }

    // MARK: - Gateway RPC

    private func startGatewayTask(
        message: String,
        attachments: [[String: Any]] = [],
        onComplete: ((String) -> Void)? = nil
    ) {
        activeGatewayTask?.cancel()
        activeGatewayRunId = nil

        let requestId = UUID()
        let sessionKey = agentSessionKey
        activeGatewayRequestId = requestId
        activeGatewayTask = Task { @MainActor [weak self] in
            await self?.sendViaGatewayRPC(
                message: message,
                attachments: attachments,
                sessionKey: sessionKey,
                requestId: requestId,
                onComplete: onComplete
            )
        }
    }

    private func sendViaGatewayRPC(
        message: String,
        attachments: [[String: Any]] = [],
        sessionKey: String,
        requestId: UUID,
        onComplete: ((String) -> Void)? = nil
    ) async {
        guard activeGatewayRequestId == requestId else { return }
        activeGatewayRunId = nil
        ResultOverlayWindowController.shared.hide()
        OpenClawTaskOverlayWindowController.shared.showConnecting()

        guard let binaryPath = await resolveBinaryPathSlow() else {
            clearGatewayTask(requestId: requestId)
            OpenClawTaskOverlayWindowController.shared.showError("未找到 OpenClaw 命令，请确认 OpenClaw 已正确安装。")
            return
        }

        do {
            try await OpenClawGatewayClient.shared.sendMessage(
                message: message,
                attachments: attachments,
                binaryPath: binaryPath,
                sessionKey: sessionKey
            ) { [weak self] event in
                Task { @MainActor in
                    guard self?.activeGatewayRequestId == requestId else { return }
                    switch event {
                    case .started(let runId, let messageSeq):
                        self?.activeGatewayRunId = runId
                        OpenClawTaskOverlayWindowController.shared.showRunning(
                            runId: runId,
                            messageSeq: messageSeq)
                    case .text(_, let accumulated):
                        OpenClawTaskOverlayWindowController.shared.updateTranscript(accumulated)
                    case .done(let full):
                        self?.clearGatewayTask(requestId: requestId)
                        OpenClawTaskOverlayWindowController.shared.finish(
                            full.isEmpty ? "（OpenClaw 未返回内容）" : full)
                        onComplete?(full)
                    case .error(let msg):
                        self?.clearGatewayTask(requestId: requestId)
                        OpenClawTaskOverlayWindowController.shared.showError(msg)
                    }
                }
            }
        } catch is CancellationError {
            clearGatewayTask(requestId: requestId)
        } catch {
            clearGatewayTask(requestId: requestId)
            OpenClawTaskOverlayWindowController.shared.showError(
                "Gateway RPC 请求失败：\(error.localizedDescription)\n请确认 gateway 已启动。")
        }
    }

    func abortCurrentOpenClawTask(showFeedback: Bool = true) {
        abortCurrentOpenClawTask(onComplete: nil, showFeedback: showFeedback)
    }

    private func abortCurrentOpenClawTask(
        onComplete: ((String) -> Void)? = nil,
        showFeedback: Bool = true
    ) {
        activeGatewayTask?.cancel()
        activeGatewayTask = nil
        activeGatewayRequestId = nil
        Task { @MainActor in
            await abortOpenClawTask(onComplete: onComplete, showFeedback: showFeedback)
        }
    }

    private func abortOpenClawTask(
        onComplete: ((String) -> Void)? = nil,
        showFeedback: Bool = true
    ) async {
        guard let binaryPath = await resolveBinaryPathSlow() else {
            let message = "❌ 未找到 OpenClaw 命令，请确认 OpenClaw 已正确安装。"
            if showFeedback {
                OpenClawTaskOverlayWindowController.shared.showError(message)
            }
            onComplete?(message)
            return
        }
        do {
            let message = try await OpenClawGatewayClient.shared.abortActiveSession(
                binaryPath: binaryPath,
                sessionKey: agentSessionKey,
                runId: activeGatewayRunId)
            activeGatewayRunId = nil
            if showFeedback {
                OpenClawTaskOverlayWindowController.shared.markAborted(message)
            }
            onComplete?(message)
        } catch {
            let message = "❌ OpenClaw 中断失败：\(error.localizedDescription)"
            if showFeedback {
                OpenClawTaskOverlayWindowController.shared.showError(message)
            }
            onComplete?(message)
        }
    }

    private func clearGatewayTask(requestId: UUID) {
        guard activeGatewayRequestId == requestId else { return }
        activeGatewayRunId = nil
        activeGatewayTask = nil
        activeGatewayRequestId = nil
    }

    private static func makeAgentSessionKey() -> String {
        "voiceinput:\(UUID().uuidString.lowercased())"
    }

    private func resetAgentSessionKey() {
        let oldKey = agentSessionKey
        agentSessionKey = Self.makeAgentSessionKey()
        activeGatewayRunId = nil
        cleanupSession(key: oldKey)
    }

    private func cleanupSession(key: String) {
        guard let binaryPath = fastResolveBinaryPath() else { return }
        Task {
            try? await OpenClawGatewayClient.shared.deleteSession(
                binaryPath: binaryPath,
                sessionKey: key
            )
        }
    }

    private func isAbortCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower == "stop" || lower == "/stop" || lower == "abort" || lower == "/abort" || lower == "cancel" || lower == "/cancel"
    }

    /// 判断命令是否需要用户交互（OAuth、引导配置、编辑器等）。
    /// 这类命令必须在独立终端窗口中运行，不能复用 agent 会话终端。
    /// 基于 OpenClaw 2026.5.27 CLI 确认的交互式命令列表。
    private func isInteractiveCommand(_ command: String) -> Bool {
        let interactivePatterns = [
            // 模型认证（OAuth / token 粘贴，需要用户交互）
            "models auth add",
            "models auth setup-token",
            "models auth paste-token",
            // 配置向导（交互式引导）
            "onboard",
            "configure",
            "setup",
            // 模型设置（需确认持久化写入）
            "models set ",
            "models set-image ",
            "models scan",
            // 配置写入（持久化，需用户确认）
            "config set ",
            "config unset ",
            // Channel 登录
            "channels login",
            "channels add",
        ]
        let lower = command.lowercased()
        return interactivePatterns.contains { lower.contains($0) }
    }

    // MARK: - 内部：终端操作

    /// 在 openclaw 专属终端窗口中执行命令。
    /// 复用已有窗口（若存活），否则新建窗口并记录 windowId。
    private func sendToOpenClawTerminal(_ command: String) {
        let escapedCmd = escapeForAppleScript(command)

        if let wid = openClawWindowId {
            let reuseScript = """
            tell application "Terminal"
                set winIds to id of every window
                if {\(wid)} is in winIds then
                    do script "\(escapedCmd)" in (first window whose id is \(wid))
                    activate
                    return "ok"
                end if
                return "missing"
            end tell
            """
            if let result = runAppleScriptReturning(reuseScript), result == "ok" {
                return
            }
            openClawWindowId = nil
        }

        let newWindowScript = """
        tell application "Terminal"
            activate
            do script "\(escapedCmd)"
            set newWin to front window
            return id of newWin as string
        end tell
        """
        if let idStr = runAppleScriptReturning(newWindowScript), let wid = Int(idStr) {
            openClawWindowId = wid
        }
    }

    private func runInNewTerminalWindow(_ command: String) {
        let escaped = escapeForAppleScript(command)
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        runAppleScript(appleScript)
    }

    // MARK: - 辅助

    /// 转义字符串用于 shell 命令中的双引号包裹
    private func escapeForShell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    /// 转义字符串用于 AppleScript do script 中的双引号包裹
    private func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            return error == nil
        }
        return false
    }

    /// 执行 AppleScript 并返回字符串结果（用于获取窗口 id 等）
    private func runAppleScriptReturning(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }

    private func isConfigDirectoryPresent() -> Bool {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw")
        return FileManager.default.fileExists(atPath: configDir.path)
    }

    /// 快速解析（零子进程）：缓存 → 常见安装路径扫描。
    /// 适用于同步调用点；未命中时由 resolveBinaryPathSlow 的 login shell 兜底并回填缓存。
    private func fastResolveBinaryPath() -> String? {
        let fileManager = FileManager.default
        if let cached = cachedBinaryPath, fileManager.isExecutableFile(atPath: cached) {
            return cached
        }
        cachedBinaryPath = nil
        for candidate in commonBinaryCandidates() where fileManager.isExecutableFile(atPath: candidate) {
            cachedBinaryPath = candidate
            return candidate
        }
        return nil
    }

    /// 完整解析：快速路径未命中时，后台 login shell 跑一次 `command -v` 兜底非常规安装位置。
    /// 子进程在全局执行器上运行并做并发合并，绝不阻塞主线程。
    private func resolveBinaryPathSlow() async -> String? {
        if let fast = fastResolveBinaryPath() {
            return fast
        }
        let task: Task<String?, Never>
        if let inflight = shellResolveTask {
            task = inflight
        } else {
            task = Task { @MainActor [weak self] in
                defer { self?.shellResolveTask = nil }
                guard let path = await Self.shellResolvedBinaryPath(),
                      FileManager.default.isExecutableFile(atPath: path) else { return nil }
                self?.cachedBinaryPath = path
                return path
            }
            shellResolveTask = task
        }
        return await task.value
    }

    private func commonBinaryCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
            home.appendingPathComponent(".local/bin/openclaw").path,
            home.appendingPathComponent(".volta/bin/openclaw").path,
            home.appendingPathComponent(".npm-global/bin/openclaw").path,
        ]

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: versions.map {
                $0.appendingPathComponent("bin/openclaw").path
            })
        }
        return candidates
    }

    /// login shell 解析 openclaw 路径（覆盖 nvm/自定义 PATH 等非常规安装）。
    /// login shell 启动要读取用户全部 shell 初始化脚本，单次可达秒级，
    /// 因此必须以 nonisolated 异步方式在全局执行器上运行，严禁主线程同步等待。
    private nonisolated static func shellResolvedBinaryPath(timeout: TimeInterval = 10) async -> String? {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-l", "-c", "command -v openclaw"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()

            let lock = NSLock()
            var didResume = false
            @Sendable func finish(_ value: String?) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }

            proc.terminationHandler = { process in
                let output = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                finish(process.terminationStatus == 0 && !trimmed.isEmpty ? trimmed : nil)
            }

            do {
                try proc.run()
            } catch {
                finish(nil)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning {
                    proc.terminate()
                    finish(nil)
                }
            }
        }
    }

    private func openClawShellCommand(arguments: [String]) -> String {
        guard let binaryPath = fastResolveBinaryPath() else {
            return "openclaw " + arguments.map(shellQuote).joined(separator: " ")
        }
        let binaryDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path
        return "PATH=\(shellQuote(binaryDir)):$PATH \(shellQuote(binaryPath)) " + arguments.map(shellQuote).joined(separator: " ")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runOpenClawJSON(
        binaryPath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            proc.arguments = arguments
            proc.environment = openClawProcessEnvironment(binaryPath: binaryPath)

            let stdout = Pipe()
            proc.standardOutput = stdout
            proc.standardError = Pipe()

            var didResume = false
            @Sendable func finish(_ value: [String: Any]?) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }

            proc.terminationHandler = { process in
                guard process.terminationStatus == 0 else {
                    finish(nil)
                    return
                }
                let output = String(
                    data: stdout.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    finish(nil)
                    return
                }
                finish(json)
            }

            do {
                try proc.run()
            } catch {
                finish(nil)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning {
                    proc.terminate()
                    finish(nil)
                }
            }
        }
    }

    private func openClawProcessEnvironment(binaryPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binaryDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let commonPaths = [binaryDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let merged = (commonPaths + existingPath.split(separator: ":").map(String.init))
            .filter { path in
                guard !path.isEmpty, !seen.contains(path) else { return false }
                seen.insert(path)
                return true
            }
            .joined(separator: ":")
        env["PATH"] = merged
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["TMPDIR"] = env["TMPDIR"] ?? NSTemporaryDirectory()
        env["USER"] = env["USER"] ?? NSUserName()
        env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
        return env
    }
}
