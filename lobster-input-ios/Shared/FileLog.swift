import Foundation
import os

/// 落盘运行日志(主 App 与键盘扩展共用 App Group 容器 Logs/ 目录):
/// - 按天切割:lobster-yyyy-MM-dd.log,跨天自动滚动;
/// - 保留 14 天:创建新日文件时清理更早文件,避免撑爆磁盘;
/// - 覆盖安装(App Store/TestFlight 升级)不清空:App Group 容器只在卸载时删除;
/// - 串行队列写入不阻塞调用方;同时输出 os_log 便于 Console.app 实时查看。
enum FileLog {

    private static let retentionDays = 14
    private static let prefix = "lobster-"
    private static let suffix = ".log"

    private static let queue = DispatchQueue(label: "lobster.filelog", qos: .utility)
    private static let osLog = Logger(subsystem: "ssh2026.lobster-input-ios", category: "FileLog")

    private static var currentDay = ""
    private static var currentURL: URL?

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static var logDir: URL? = {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: APIConfig.appGroupID
        ) else { return nil }
        let dir = container.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func i(_ tag: String, _ msg: String) { write("I", tag, msg); osLog.info("\(tag, privacy: .public): \(msg, privacy: .public)") }
    static func w(_ tag: String, _ msg: String) { write("W", tag, msg); osLog.warning("\(tag, privacy: .public): \(msg, privacy: .public)") }
    static func e(_ tag: String, _ msg: String) { write("E", tag, msg); osLog.error("\(tag, privacy: .public): \(msg, privacy: .public)") }

    private static func write(_ level: String, _ tag: String, _ msg: String) {
        let now = Date()
        queue.async {
            guard let dir = logDir else { return }
            let day = dayFormatter.format(now)
            if day != currentDay || currentURL == nil {
                currentDay = day
                currentURL = dir.appendingPathComponent("\(prefix)\(day)\(suffix)")
                pruneOldLogs(in: dir)
            }
            guard let url = currentURL else { return }
            let line = "\(timeFormatter.format(now)) \(level)/\(tag): \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// 按文件名日期字典序保留最近 retentionDays 个日文件。
    private static func pruneOldLogs(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let logs = files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in logs.dropFirst(retentionDays) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}

private extension DateFormatter {
    func format(_ date: Date) -> String { string(from: date) }
}
