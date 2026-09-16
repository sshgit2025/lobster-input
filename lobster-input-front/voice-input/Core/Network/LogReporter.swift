/// LogReporter.swift
/// 客户端日志上报工具（单例）。
/// 将运行日志批量上报至后端，用于远程排查权限、OpenClaw、网络等问题。
/// 仅在用户已登录时上报，未登录时日志只写本地缓冲区，登录后一次性刷新。
/// HTTP 上报由 APIClient 统一处理，本文件不关心任何请求头细节。
import Foundation

@MainActor
final class LogReporter {

    static let shared = LogReporter()
    private init() {}

    // MARK: - 内部缓冲（最多保留 200 条，超出丢弃最旧的）

    private var buffer: [LogEntry] = []
    private let maxBuffer = 200

    // MARK: - 公开记录接口

    func log(level: String = "info", tag: String, message: String, extra: [String: String]? = nil) {
        let entry = LogEntry(
            level: level,
            tag: tag,
            message: message,
            extra: extra,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        buffer.append(entry)
        if buffer.count > maxBuffer {
            buffer.removeFirst(buffer.count - maxBuffer)
        }
    }

    func info(_ tag: String, _ msg: String, extra: [String: String]? = nil) {
        log(level: "info", tag: tag, message: msg, extra: extra)
    }
    func warn(_ tag: String, _ msg: String, extra: [String: String]? = nil) {
        log(level: "warn", tag: tag, message: msg, extra: extra)
    }
    func error(_ tag: String, _ msg: String, extra: [String: String]? = nil) {
        log(level: "error", tag: tag, message: msg, extra: extra)
    }

    // MARK: - 收集系统快照并上报

    /// 收集当前权限和 OpenClaw 状态快照，写入缓冲区，然后立即上报。
    func reportSnapshot(reason: String) async {
        collectSnapshot(reason: reason)
        await flush()
    }

    /// 只收集快照不上报（用于上报前追加更多上下文）
    func collectSnapshot(reason: String) {
        let pm = PermissionManager.shared
        let openClawDiagnostics = OpenClawManager.shared.diagnosticSnapshot()

        let micStatus = statusString(pm.microphoneStatus)
        let axStatus = statusString(pm.accessibilityStatus)
        let screenStatus = statusString(pm.screenCaptureStatus)

        let ocStatus = OpenClawManager.shared.status
        var extra: [String: String] = [
            "mic": micStatus,
            "accessibility": axStatus,
            "screenCapture": screenStatus,
            "hotkeyListening": HotKeyManager.shared.isListening ? "true" : "false",
            "openClaw": openClawStatusString(ocStatus),
            "appVersion": appVersion(),
            "osVersion": osVersion(),
        ]
        for (key, value) in openClawDiagnostics {
            extra["openClaw_\(key)"] = value
        }

        log(level: "info", tag: "Snapshot", message: "[\(reason)] 状态快照", extra: extra)
    }

    // MARK: - 上报（将缓冲区全部发送到后端）

    func flush() async {
        guard !buffer.isEmpty else { return }
        guard AuthStore.shared.token != nil else { return }

        let entries = buffer
        buffer.removeAll()

        do {
            try await APIClient.shared.uploadLogs(
                appVersion: appVersion(),
                osVersion: osVersion(),
                entries: entries
            )
        } catch {
            restore(entries)
        }
    }

    // MARK: - 工具

    private func statusString(_ s: PermissionStatus) -> String {
        switch s {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        }
    }

    private func openClawStatusString(_ s: OpenClawStatus) -> String {
        switch s {
        case .unknown: return "unknown"
        case .notInstalled: return "notInstalled"
        case .installedServiceDown: return "serviceDown"
        case .ready: return "ready"
        }
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private func restore(_ entries: [LogEntry]) {
        buffer = entries + buffer
        if buffer.count > maxBuffer {
            buffer.removeLast(buffer.count - maxBuffer)
        }
    }
}
