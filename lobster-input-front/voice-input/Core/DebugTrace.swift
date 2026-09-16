import Foundation

enum DebugTrace {
    nonisolated private static let queue = DispatchQueue(label: "ssh2026.voice-input.debug-trace")
    nonisolated private static let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("voice_input_trace.log")
    /// 单文件大小上限（5MB）。超过即轮转，避免常驻进程长期运行下日志无界增长。
    nonisolated private static let maxFileSize: UInt64 = 5 * 1024 * 1024

    nonisolated static var path: String { fileURL.path }

    nonisolated static func clear() {
        queue.async {
            try? Data().write(to: fileURL, options: .atomic)
        }
    }

    nonisolated static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let thread = Thread.isMainThread ? "main" : "bg"
        let line = "\(timestamp) [\(thread)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        queue.async {
            rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        }
    }

    /// 文件超过上限时轮转：当前文件改名为 .1（覆盖旧的 .1），重新从空文件写入。
    /// 始终只保留「当前 + 上一份」两个文件，磁盘占用恒定有上限。
    nonisolated private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize else {
            return
        }
        let rotatedURL = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
    }
}
