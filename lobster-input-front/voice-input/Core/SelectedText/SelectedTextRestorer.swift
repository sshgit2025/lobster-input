/// SelectedTextRestorer.swift
/// 通过 macOS Accessibility API 将文本选区恢复到之前保存的状态。
/// 在录音浮窗弹出导致选区丢失后，无感知地重建用户的文本选区。
import Foundation
import AppKit
import ApplicationServices
import os.log

private let selectionRestoreLog = Logger(subsystem: "ssh2026.voice-input", category: "SelectionRestore")

struct SelectedTextRestorer {

    /// 将焦点元素的选区恢复到快照中保存的范围
    /// 调用时机：浮窗显示后、切换为"识别中"时
    /// Cmd+C 方案的快照（element == nil 或 range.location == -1）无法恢复，直接跳过
    @discardableResult
    static func restore(_ snapshot: SelectionSnapshot) -> Bool {
        // Cmd+C 方案无 element，无法恢复选区
        guard let element = snapshot.element else {
            selectionRestoreLog.info("restore skipped: source=\(snapshot.source.rawValue, privacy: .public), no element")
            return false
        }
        // 占位 range（-1,-1）无法恢复
        guard snapshot.range.location >= 0 else {
            selectionRestoreLog.info("restore skipped: invalid range")
            return false
        }
        guard AXIsProcessTrusted() else {
            selectionRestoreLog.error("restore skipped: AX not trusted")
            return false
        }

        var range = snapshot.range
        guard let axValue = AXValueCreate(.cfRange, &range) else {
            selectionRestoreLog.error("restore skipped: AXValueCreate failed")
            return false
        }

        selectionRestoreLog.info("restore begin: source=\(snapshot.source.rawValue, privacy: .public), range={loc=\(range.location), len=\(range.length)}, textLen=\(snapshot.text.count)")
        DebugTrace.log("Selection restore begin: source=\(snapshot.source.rawValue), range={loc=\(range.location), len=\(range.length)}, textLen=\(snapshot.text.count)")

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axValue
        )
        selectionRestoreLog.info("restore result: \(self.describe(result), privacy: .public)")
        DebugTrace.log("Selection restore result: \(self.describe(result))")
        return result == .success
    }

    private static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(error.rawValue))"
        }
    }
}
