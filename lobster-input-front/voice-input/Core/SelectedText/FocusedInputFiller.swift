/// FocusedInputFiller.swift
/// 识别结果自动填充工具。
/// 通过 CGEvent 向目标 App 发送 Cmd+V 按键事件，实现自动粘贴。
/// 录音开始时 captureTargetApp() 记录前台 App PID，识别完成后 paste(to:) 精准填充。
import AppKit
import Carbon

nonisolated struct FocusedInputFiller {

    /// 录音开始时调用，记录目标 App PID（SystemWide 焦点元素优先，覆盖 Spotlight 等浮层）
    static func captureTargetApp() -> pid_t? {
        let pid = FocusProbe.captureTargetPid()
        DebugTrace.log("FocusedInputFiller.captureTargetApp: pid=\(pid.map { "\($0)" } ?? "nil")")
        return pid
    }

    /// 向目标 App 发送 Cmd+V（剪贴板应已由调用方写入）
    static func paste(to targetPid: pid_t? = nil) {
        let pid = targetPid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier

        let src = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand

        if let pid {
            vDown?.postToPid(pid)
            vUp?.postToPid(pid)
        } else {
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
        }
    }
}
