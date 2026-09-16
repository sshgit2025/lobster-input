/// SelectedTextReader.swift
/// 通过 macOS Accessibility API 读取当前焦点应用中被选中的文本及选区范围。
/// 需要辅助功能权限（AXIsProcessTrusted），用于 rewrite 等需要上下文的操作。
///
/// 实现策略（Chain of Responsibility）：
///   1. AX 直读法（SystemWide）：最快，支持原生 AppKit/UIKit 应用
///   2. Cmd+C 模拟复制法：兜底方案，支持 Electron/Chrome/Firefox 等 AX 不完整的应用
///      - 保存当前剪贴板 → 模拟 Cmd+C → 读取新剪贴板 → 还原旧剪贴板
///      - 依赖辅助功能授权以稳定触发快捷键链路
import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import os.log

nonisolated private func selectedTextLogger() -> Logger {
    Logger(subsystem: "ssh2026.voice-input", category: "Selection")
}

/// 选区快照 — 保存恢复选区所需的全部信息
struct SelectionSnapshot: @unchecked Sendable {
    /// 选中的文本内容
    let text: String
    /// 选区在文档中的字符范围（CFRange）；Cmd+C 方案下为 (-1,-1) 占位
    let range: CFRange
    /// 持有焦点的 UI 元素引用（用于写回选区）；Cmd+C 方案下为 nil
    let element: AXUIElement?
    /// 选区来源，用于日志诊断
    let source: Source

    enum Source: String {
        case axSystemWide = "AX-SystemWide"
        case axApplication = "AX-Application"
        case cmdCopy      = "CmdC-Fallback"
    }
}

struct SelectedTextReader {

    /// 读取当前焦点元素中被选中的文本（仅文本，兼容旧接口）
    nonisolated static func read() -> String? {
        snapshot()?.text
    }

    /// 读取完整选区快照（文本 + 范围 + 元素引用）
    /// 优先使用 AX SystemWide，失败则降级到 Cmd+C 模拟复制
    /// 注意：此方法为同步阻塞，Cmd+C 方案最多阻塞约 2s，请勿在主线程直接调用。
    nonisolated static func snapshot() -> SelectionSnapshot? {
        let totalStart = Date()
        func ms(_ from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }

        // ── 方案 1：AX SystemWide（最快，支持原生 App）──────────────────
        let sw = Date()
        if AXIsProcessTrusted(), let snap = axSystemWideSnapshot() {
            DebugTrace.log("snapshot[timing]: SystemWide hit in \(ms(sw))ms, total=\(ms(totalStart))ms")
            return snap
        }
        DebugTrace.log("snapshot[timing]: SystemWide miss in \(ms(sw))ms")

        // ── 方案 2：AX Application（兼容部分 App，AXIsProcessTrusted 可能 false 时跳过）──
        let appStart = Date()
        if AXIsProcessTrusted(), let snap = axApplicationSnapshot() {
            DebugTrace.log("snapshot[timing]: Application hit in \(ms(appStart))ms, total=\(ms(totalStart))ms")
            return snap
        }
        DebugTrace.log("snapshot[timing]: Application miss in \(ms(appStart))ms")

        // ── 方案 3：Cmd+C 模拟复制（兜底，支持 Electron/Chrome/Firefox）──
        let cmdStart = Date()
        let result = cmdCopySnapshot()
        DebugTrace.log("snapshot[timing]: cmdCopy done in \(ms(cmdStart))ms, total=\(ms(totalStart))ms, hasResult=\(result != nil)")
        return result
    }

    /// 读取完整选区快照的异步版本。
    /// 将同步阻塞（Cmd+C 方案最长等待 2s）移到后台线程，不阻塞 MainActor。
    /// 调用方可直接 await，结果通过 continuation 回传 MainActor。
    nonisolated static func snapshotAsync() async -> SelectionSnapshot? {
        await ContextCaptureWorker.run {
            snapshot()
        }
    }

    // MARK: - 方案 1：AX SystemWide

    /// 使用 AXUIElementCreateSystemWide() 获取系统焦点元素，再读取选中文本
    /// 这是跨应用读取选中文本的标准做法，比 AXUIElementCreateApplication 更通用
    nonisolated private static func axSystemWideSnapshot() -> SelectionSnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, AXTimeouts.elementQuery)

        var focusedRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard err == .success, let focusedRef else {
            selectedTextLogger().debug("axSystemWide: focusedElement failed, err=\(err.rawValue)")
            DebugTrace.log("AX-SystemWide: focusedElement failed err=\(err.rawValue)")
            return nil
        }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, AXTimeouts.elementQuery)

        return buildSnapshot(from: element, source: .axSystemWide)
    }

    // MARK: - 方案 2：AX Application（备用）

    /// 通过前台 App PID 创建 Application 元素，再获取焦点子元素
    nonisolated private static func axApplicationSnapshot() -> SelectionSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, AXTimeouts.elementQuery)

        var focusedRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard err == .success, let focusedRef else {
            selectedTextLogger().debug("axApplication: focusedElement failed, app=\(app.localizedName ?? "nil"), err=\(err.rawValue)")
            DebugTrace.log("AX-Application: focusedElement failed app=\(app.localizedName ?? "nil") err=\(err.rawValue)")
            return nil
        }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, AXTimeouts.elementQuery)

        return buildSnapshot(from: element, source: .axApplication)
    }

    // MARK: - 方案 3：Cmd+C 模拟复制

    /// 模拟 Cmd+C，从剪贴板读取选中文本，完成后还原原剪贴板内容
    /// 适用于 Electron/Chrome/Firefox 等 AX 树不完整的应用
    nonisolated private static func cmdCopySnapshot() -> SelectionSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = app.localizedName ?? "nil"

        // 保存当前剪贴板内容（changeCount 用于检测是否真的发生了复制）
        let pasteboard = NSPasteboard.general
        let beforeCount = pasteboard.changeCount
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        // 发送 Cmd+C 到目标 App
        DebugTrace.log("cmdCopy[timing]: posting Cmd+C (will wait up to 2000ms for clipboard change)")
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(8), keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(8), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.postToPid(app.processIdentifier)
        keyUp?.postToPid(app.processIdentifier)

        // 等待剪贴板更新（最多 2000ms，自适应轮询：前 300ms 每 20ms 一次，之后每 50ms 一次）
        // 根据 Apple 文档，pbcopy/pbpaste 本身可能耗时 0.8-1.7s；大文本需要更多时间。
        var text: String?
        let copyStartTime = Date()
        let maxWaitInterval: TimeInterval = 2.0
        let deadline = copyStartTime.addingTimeInterval(maxWaitInterval)
        while Date() < deadline {
            let elapsed = Date().timeIntervalSince(copyStartTime)
            // 前 300ms 快速轮询（20ms），之后放慢（50ms）避免 CPU 空转
            let pollInterval: TimeInterval = elapsed < 0.3 ? 0.02 : 0.05
            Thread.sleep(forTimeInterval: pollInterval)
            if pasteboard.changeCount != beforeCount {
                text = pasteboard.string(forType: .string)
                let elapsedMs = Int(Date().timeIntervalSince(copyStartTime) * 1000)
                selectedTextLogger().info("cmdCopy: clipboard updated after \(elapsedMs)ms")
                DebugTrace.log("CmdC-Fallback: clipboard updated after \(elapsedMs)ms")
                break
            }
        }
        if text == nil {
            let elapsedMs = Int(Date().timeIntervalSince(copyStartTime) * 1000)
            selectedTextLogger().debug("cmdCopy: no clipboard change detected after \(elapsedMs)ms")
            DebugTrace.log("CmdC-Fallback: no clipboard change after \(elapsedMs)ms (timeout)")
        }

        // 还原剪贴板。若用户在 Cmd+C 探测窗口内主动改动剪贴板，则保留用户新内容。
        if pasteboard.changeCount != beforeCount {
            let copiedChangeCount = pasteboard.changeCount
            let restored = snapshot.restoreIfUnchanged(
                to: pasteboard,
                expectedChangeCount: copiedChangeCount,
                expectedString: text
            )
            if !restored {
                DebugTrace.log("CmdC-Fallback: skipped restore because pasteboard changed")
            }
        }

        guard let selectedText = text, !selectedText.isEmpty else {
            selectedTextLogger().debug("cmdCopy: no text captured from \(appName)")
            DebugTrace.log("CmdC-Fallback: no text captured from \(appName)")
            return nil
        }

        selectedTextLogger().info("cmdCopy snapshot: app=\(appName, privacy: .public), textLen=\(selectedText.count)")
        DebugTrace.log("CmdC-Fallback snapshot: app=\(appName), textLen=\(selectedText.count)")

        // Cmd+C 方案无法获取精确 range 和 element，用占位值
        return SelectionSnapshot(
            text: selectedText,
            range: CFRange(location: -1, length: -1),
            element: nil,
            source: .cmdCopy
        )
    }

    // MARK: - 公共构建逻辑

    nonisolated private static func buildSnapshot(from element: AXUIElement, source: SelectionSnapshot.Source) -> SelectionSnapshot? {
        // 读取选中文本
        var textRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &textRef
        ) == .success,
              let text = textRef as? String,
              !text.isEmpty else { return nil }

        // 读取选区范围
        var rangeRef: AnyObject?
        var range = CFRange(location: 0, length: text.count)
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeVal = rangeRef {
            AXValueGetValue(rangeVal as! AXValue, .cfRange, &range)
        }

        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        selectedTextLogger().info("snapshot[\(source.rawValue, privacy: .public)]: app=\(appName, privacy: .public), textLen=\(text.count)")
        DebugTrace.log("snapshot[\(source.rawValue)]: app=\(appName), textLen=\(text.count)")

        return SelectionSnapshot(text: text, range: range, element: element, source: source)
    }

    // MARK: - 诊断

    nonisolated static func diagnosticSummary(label: String) -> String {
        let axTrusted = AXIsProcessTrusted()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "[SelectionDiag] \(label): AXTrusted=\(axTrusted), no frontmost app"
        }

        // 尝试 SystemWide 焦点
        let systemWide = AXUIElementCreateSystemWide()
        var swFocusedRef: AnyObject?
        let swErr = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &swFocusedRef)

        // 尝试 Application 焦点
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var appFocusedRef: AnyObject?
        let appErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appFocusedRef)

        var details = "[SelectionDiag] \(label): AXTrusted=\(axTrusted), app=\(app.localizedName ?? "nil")(pid=\(app.processIdentifier))"
        details += ", SW-focusErr=\(swErr.rawValue), App-focusErr=\(appErr.rawValue)"

        if let ref = swFocusedRef ?? appFocusedRef {
            let el = ref as! AXUIElement
            let role = stringAttribute(kAXRoleAttribute, on: el) ?? "nil"
            let selectedText = stringAttribute(kAXSelectedTextAttribute, on: el) ?? ""
            let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute, on: el)
            details += ", role=\(role), textLen=\(selectedText.count), range=\(selectedRange ?? "nil")"
        }

        return details
    }

    nonisolated private static func stringAttribute(_ name: String, on element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private static func rangeAttribute(_ name: String, on element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return "{loc=\(range.location), len=\(range.length)}"
    }
}
