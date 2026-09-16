import AppKit
import Foundation
import os.log

private let crashLog = Logger(subsystem: "ssh2026.voice-input", category: "CrashReporter")

// MARK: - Models

struct CrashReport: Codable {
    let id: String
    let timestamp: String
    let appVersion: String
    let osVersion: String
    let signal: String
    let reason: String
    let callStack: [String]
    let systemReportPath: String?
    let diagnostics: [String: String]?
    var reported: Bool
}

struct CrashUploadResult {
    let attempted: Int
    let succeeded: Int
    let failed: Int
    let isAuthenticated: Bool
}

private struct PerformanceDiagnosticReport: Codable {
    let id: String
    let timestamp: String
    let appVersion: String
    let osVersion: String
    let kind: String
    let reason: String
    let diagnostics: [String: String]
}

private struct SystemCrashCandidate {
    let url: URL
    let creationDate: Date
    let identifier: String
    let signal: String
    let reason: String
    let timestamp: String
}

// MARK: - CrashReporter

final class CrashReporter {
    static let shared = CrashReporter()

    private let diagnosticsQueue = DispatchQueue(label: "ssh2026.voice-input.performance-diagnostics", qos: .utility)
    private var diagnosticsTimer: DispatchSourceTimer?
    private var menuTrackingDepth = 0
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var menuObservers: [NSObjectProtocol] = []
    private var lastMainQueueAckWall = Date()
    private var lastMainQueueAckUptime = ProcessInfo.processInfo.systemUptime
    private var suppressDiagnosticsUntilUptime: TimeInterval = 0
    private var lastDiagnosticWriteUptime: TimeInterval = 0
    private var applicationActiveSnapshot = false

    private let processedSystemReportsKey = "CrashReporter.processedSystemReports.v3"
    private let launchWallTimeKey = "CrashReporter.lastLaunchWallTime.v3"
    private let maxStoredCrashReports = 20
    private let maxStoredPerformanceReports = 20
    private let diagnosticProbeInterval: TimeInterval = 30
    private let diagnosticThreshold: TimeInterval = 60
    private let diagnosticMinimumWriteInterval: TimeInterval = 60 * 60

    private init() {}

    // MARK: - Paths

    static var reportsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ssh2026.voice-input/CrashReports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var performanceReportsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ssh2026.voice-input/PerformanceReports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var diagnosticReportsDirs: [URL] {
        [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]
    }

    // MARK: - Lifecycle

    func install() {
        installExceptionHandler()
        installSleepWakeObservers()
        installMenuTrackingObservers()
        recordApplicationState(active: NSApp.isActive)
        startPerformanceDiagnostics()
        crashLog.info("CrashReporter installed")
    }

    func processPendingCrashReports() {
        migrateLegacyHangReports()
        removeLegacySignalMarkers()
        importNewSystemCrashReports()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: launchWallTimeKey)
    }

    // MARK: - Reading

    func loadUnreported() -> [CrashReport] {
        loadAll().filter { !$0.reported }
    }

    func loadAll() -> [CrashReport] {
        let dir = Self.reportsDir
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> CrashReport? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CrashReport.self, from: data)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func markReported(id: String) {
        let url = Self.reportsDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              var report = try? JSONDecoder().decode(CrashReport.self, from: data)
        else { return }
        report.reported = true
        if let encoded = try? JSONEncoder().encode(report) {
            try? encoded.write(to: url, options: .atomic)
        }
    }

    func deleteReport(id: String) {
        let url = Self.reportsDir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Upload

    @MainActor
    @discardableResult
    func uploadUnreported() async -> CrashUploadResult {
        let unreported = loadUnreported()
        guard !unreported.isEmpty else {
            return CrashUploadResult(attempted: 0, succeeded: 0, failed: 0, isAuthenticated: true)
        }
        guard let token = AuthStore.shared.token else {
            return CrashUploadResult(
                attempted: unreported.count,
                succeeded: 0,
                failed: unreported.count,
                isAuthenticated: false
            )
        }

        var successCount = 0
        var failedCount = 0
        for report in unreported {
            let reportExcerpt = systemReportExcerpt(path: report.systemReportPath)
            let stackText = report.callStack.isEmpty
                ? "(see system report: \(report.systemReportPath ?? "not found"))"
                : report.callStack.prefix(40).joined(separator: "\n")

            let body: [String: Any] = [
                "app_version": report.appVersion,
                "os_version": report.osVersion,
                "entries": [[
                    "level": "fatal",
                    "tag": "Crash",
                    "message": "[\(report.signal)] \(report.reason)",
                    "extra": {
                        var extra: [String: Any] = [
                            "signal": report.signal,
                            "callStack": stackText,
                            "systemReport": report.systemReportPath ?? "",
                            "systemReportExcerpt": reportExcerpt,
                            "reportID": report.id,
                            "appVersion": report.appVersion,
                            "osVersion": report.osVersion,
                        ]
                        if let diagnostics = report.diagnostics {
                            extra["diagnostics"] = diagnostics
                        }
                        return extra
                    }(),
                    "timestamp": report.timestamp,
                ]]
            ]

            guard let url = URL(string: APIConfig.Logs.report),
                  let data = try? JSONSerialization.data(withJSONObject: body)
            else {
                failedCount += 1
                continue
            }

            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(APIConfig.appVariant, forHTTPHeaderField: "X-App-Variant")
            request.setValue("macos", forHTTPHeaderField: "X-Client-Platform")
            request.httpBody = data

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    deleteReport(id: report.id)
                    successCount += 1
                    crashLog.info("Crash report uploaded: \(report.id)")
                } else {
                    failedCount += 1
                }
            } catch {
                failedCount += 1
                crashLog.error("Upload failed for \(report.id): \(error.localizedDescription)")
            }
        }
        return CrashUploadResult(
            attempted: unreported.count,
            succeeded: successCount,
            failed: failedCount,
            isAuthenticated: true
        )
    }

    // MARK: - Storage

    func writeReport(_ report: CrashReport) {
        let url = Self.reportsDir.appendingPathComponent("\(report.id).json")
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: url, options: .atomic)
        }
        pruneReports(in: Self.reportsDir, limit: maxStoredCrashReports)
    }

    private func writePerformanceDiagnostic(_ report: PerformanceDiagnosticReport) {
        let url = Self.performanceReportsDir.appendingPathComponent("\(report.id).json")
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: url, options: .atomic)
        }
        pruneReports(in: Self.performanceReportsDir, limit: maxStoredPerformanceReports)
    }

    private func pruneReports(in dir: URL, limit: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let sorted = files
            .filter { $0.pathExtension == "json" }
            .sorted {
                let da = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da < db
            }
        if sorted.count > limit {
            sorted.prefix(sorted.count - limit).forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    // MARK: - System Crash Reports

    private func importNewSystemCrashReports() {
        let importedPaths = Set(loadAll().compactMap(\.systemReportPath))
        var processed = Set(UserDefaults.standard.stringArray(forKey: processedSystemReportsKey) ?? [])
        let candidates = findSystemCrashCandidates()
            .filter { !processed.contains($0.identifier) }
            .filter { !importedPaths.contains($0.url.path) }

        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            writeReport(CrashReport(
                id: UUID().uuidString,
                timestamp: candidate.timestamp,
                appVersion: appVersion(),
                osVersion: osVersion(),
                signal: candidate.signal,
                reason: candidate.reason,
                callStack: [],
                systemReportPath: candidate.url.path,
                diagnostics: [
                    "source": "macOS DiagnosticReports",
                    "systemReportFile": candidate.url.lastPathComponent,
                    "creationDate": isoString(candidate.creationDate),
                ],
                reported: false
            ))
            processed.insert(candidate.identifier)
            DebugTrace.log("CrashReporter imported system crash report: file=\(candidate.url.lastPathComponent), signal=\(candidate.signal)")
        }
        UserDefaults.standard.set(Array(processed.suffix(200)), forKey: processedSystemReportsKey)
    }

    private func findSystemCrashCandidates() -> [SystemCrashCandidate] {
        let defaults = UserDefaults.standard
        let now = Date()
        let previousLaunch = defaults.double(forKey: launchWallTimeKey)
        let cutoff = previousLaunch > 0
            ? Date(timeIntervalSince1970: previousLaunch).addingTimeInterval(-120)
            : now.addingTimeInterval(-24 * 60 * 60)

        return Self.diagnosticReportsDirs
            .flatMap { diagnosticReportFiles(in: $0) }
            .compactMap { url -> SystemCrashCandidate? in
                guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) else {
                    return nil
                }
                let creationDate = values.creationDate ?? values.contentModificationDate ?? .distantPast
                guard creationDate >= cutoff else { return nil }
                let identifier = "\(url.lastPathComponent)#\(Int(creationDate.timeIntervalSince1970))"
                let summary = summarizeSystemReport(url: url, fallbackDate: creationDate)
                return SystemCrashCandidate(
                    url: url,
                    creationDate: creationDate,
                    identifier: identifier,
                    signal: summary.signal,
                    reason: summary.reason,
                    timestamp: summary.timestamp
                )
            }
            .sorted { $0.creationDate < $1.creationDate }
    }

    private func diagnosticReportFiles(in dir: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return files.filter { isOwnSystemReport($0) }
    }

    private func isOwnSystemReport(_ url: URL) -> Bool {
        guard ["ips", "crash"].contains(url.pathExtension.lowercased()) else { return false }
        let name = url.lastPathComponent
        return name.hasPrefix("龙虾输入法-")
            || name.hasPrefix("voice-input-")
            || name.hasPrefix("ssh2026.voice-input-")
    }

    private func summarizeSystemReport(
        url: URL,
        fallbackDate: Date
    ) -> (signal: String, reason: String, timestamp: String) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: Data(data.prefix(256 * 1024)), encoding: .utf8)
        else {
            return ("SYSTEM_CRASH", "macOS crash report: \(url.lastPathComponent)", isoString(fallbackDate))
        }

        let signal = firstRegexCapture(in: text, pattern: #""signal"\s*:\s*"([^"]+)""#)
            ?? firstRegexCapture(in: text, pattern: #"Termination Signal:\s*([A-Z0-9_]+)"#)
            ?? firstRegexCapture(in: text, pattern: #"Exception Type:\s*([A-Z0-9_]+)"#)
            ?? "SYSTEM_CRASH"
        let exceptionType = firstRegexCapture(in: text, pattern: #""type"\s*:\s*"([^"]+)""#)
            ?? firstRegexCapture(in: text, pattern: #"Exception Type:\s*([^\n]+)"#)
        let terminationReason = firstRegexCapture(in: text, pattern: #""terminationReason"\s*:\s*"([^"]+)""#)
            ?? firstRegexCapture(in: text, pattern: #"Termination Reason:\s*([^\n]+)"#)
        let reportTimestamp = firstRegexCapture(in: text, pattern: #""timestamp"\s*:\s*"([^"]+)""#)
            ?? isoString(fallbackDate)

        let reasonParts = [exceptionType, terminationReason]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let reason = reasonParts.isEmpty
            ? "macOS crash report: \(url.lastPathComponent)"
            : reasonParts.joined(separator: " | ")
        return (signal, reason, reportTimestamp)
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    private func migrateLegacyHangReports() {
        let reports = loadAll().filter { $0.signal == "APP_HANG" }
        guard !reports.isEmpty else { return }
        for report in reports {
            deleteReport(id: report.id)
        }
        DebugTrace.log("CrashReporter removed legacy APP_HANG crash reports: count=\(reports.count)")
    }

    private func removeLegacySignalMarkers() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_input_crash_markers", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
        DebugTrace.log("CrashReporter removed legacy signal marker directory")
    }

    // MARK: - Low Frequency Performance Diagnostics

    private func startPerformanceDiagnostics() {
        guard diagnosticsTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: diagnosticsQueue)
        timer.schedule(deadline: .now() + diagnosticProbeInterval, repeating: diagnosticProbeInterval)
        timer.setEventHandler { [weak self] in
            self?.checkMainThreadResponsivenessForDiagnostics()
        }
        diagnosticsTimer = timer
        timer.resume()
    }

    private func installSleepWakeObservers() {
        guard sleepWakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepWakeObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.suppressPerformanceDiagnostics(reason: "willSleep", seconds: 180)
        })
        sleepWakeObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.suppressPerformanceDiagnostics(reason: "didWake", seconds: 60)
        })
    }

    private func installMenuTrackingObservers() {
        guard menuObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.setMenuTracking(active: true)
        })
        menuObservers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.setMenuTracking(active: false)
        })
        menuObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.recordApplicationState(active: true)
        })
        menuObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.recordApplicationState(active: false)
        })
    }

    private func setMenuTracking(active: Bool) {
        diagnosticsQueue.async { [weak self] in
            guard let self else { return }
            if active {
                self.menuTrackingDepth += 1
            } else {
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
            }
            self.resetPerformanceAck()
        }
    }

    private func recordApplicationState(active: Bool) {
        diagnosticsQueue.async { [weak self] in
            self?.applicationActiveSnapshot = active
        }
    }

    private func suppressPerformanceDiagnostics(reason: String, seconds: TimeInterval) {
        diagnosticsQueue.async { [weak self] in
            guard let self else { return }
            self.resetPerformanceAck()
            self.suppressDiagnosticsUntilUptime = ProcessInfo.processInfo.systemUptime + seconds
            DebugTrace.log("CrashReporter performance diagnostics suppressed: reason=\(reason), seconds=\(Int(seconds))")
        }
    }

    private func checkMainThreadResponsivenessForDiagnostics() {
        let probeWall = Date()
        let probeUptime = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            self?.diagnosticsQueue.async {
                self?.lastMainQueueAckWall = Date()
                self?.lastMainQueueAckUptime = ProcessInfo.processInfo.systemUptime
            }
        }

        guard probeUptime >= suppressDiagnosticsUntilUptime else { return }
        guard menuTrackingDepth == 0 else { return }

        let stalledFor = probeUptime - lastMainQueueAckUptime
        guard stalledFor >= diagnosticThreshold else { return }
        guard probeUptime - lastDiagnosticWriteUptime >= diagnosticMinimumWriteInterval else { return }
        lastDiagnosticWriteUptime = probeUptime

        let wallClockGap = probeWall.timeIntervalSince(lastMainQueueAckWall)
        let diagnostics = [
            "stalledForUptimeSeconds": String(format: "%.1f", stalledFor),
            "wallClockGapSeconds": String(format: "%.1f", wallClockGap),
            "lastMainQueueAckAt": isoString(lastMainQueueAckWall),
            "systemUptimeSeconds": String(format: "%.1f", probeUptime),
            "menuTrackingDepth": "\(menuTrackingDepth)",
            "applicationActive": "\(applicationActiveSnapshot)",
            "debugTracePath": DebugTrace.path,
        ]
        writePerformanceDiagnostic(PerformanceDiagnosticReport(
            id: UUID().uuidString,
            timestamp: isoString(probeWall),
            appVersion: appVersion(),
            osVersion: osVersion(),
            kind: "MAIN_THREAD_SLOW_RESPONSE",
            reason: "Main queue did not acknowledge within \(Int(diagnosticThreshold))s; recorded as performance diagnostic only.",
            diagnostics: diagnostics
        ))
        DebugTrace.log("CrashReporter wrote performance diagnostic: stalledFor=\(Int(stalledFor))s")
    }

    private func resetPerformanceAck() {
        lastMainQueueAckWall = Date()
        lastMainQueueAckUptime = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Helpers

    private func systemReportExcerpt(path: String?) -> String {
        guard let path,
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return "" }
        let maxLength = 64_000
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "\n...[truncated]"
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - NSException Handler

private func installExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let osVersion: String = {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }()
        let report = CrashReport(
            id: UUID().uuidString,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            appVersion: version,
            osVersion: osVersion,
            signal: "NSException",
            reason: "\(exception.name.rawValue): \(exception.reason ?? "no reason")",
            callStack: Array(exception.callStackSymbols.prefix(80)),
            systemReportPath: nil,
            diagnostics: ["source": "NSSetUncaughtExceptionHandler"],
            reported: false
        )
        CrashReporter.shared.writeReport(report)
    }
}
