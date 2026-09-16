/// TextFillEngine.swift
/// 识别结果"填充 / 浮窗"唯一决策与执行入口。设计核心是判定权反转：
///   1. 一跳快探（FocusProbe，常规 ~1ms，无树遍历、无轮询）
///   2. 明确可编辑   → Cmd+V（剪贴板请求级保存恢复；有选区时粘贴天然覆盖选区，
///      transcribe/rewrite/agent 的 paste 动作共用同一条写入路径）
///   3. 明确不可编辑 → 浮窗
///   4. 不确定       → 盲填 Cmd+V + FillVerifier 通知确认，超时恢复剪贴板走浮窗
/// 注意：禁止使用 AX kAXSelectedText 原位替换——Chromium/Electron 会返回 success
/// 但实际不写入，造成"既不替换也不浮窗"的静默失败。
/// 不变量：同一次识别结果至多写入一次；不抢宿主焦点；不永久覆盖用户剪贴板。
import AppKit
import Foundation
import os.log
private let textFillLog = Logger(subsystem: "ssh2026.voice-input", category: "TextFill")

/// 一次填充流程的最终业务结论：要么已写入目标，要么需要浮窗展示结果
enum TextFillResolution {
    case filled(String)
    case overlay(String)

    var isFilled: Bool {
        if case .filled = self { return true }
        return false
    }
    var summary: String {
        switch self {
        case .filled(let r): return "filled(\(r))"
        case .overlay(let r): return "overlay(\(r))"
        }
    }
}
@MainActor
final class TextFillEngine {
    static let shared = TextFillEngine()
    private init() {}

    /// 盲填确认等待上限。实测正向通知延迟 ~150ms，600ms 已含充分余量。
    private let blindFillConfirmTimeout: TimeInterval = 0.6
    /// 唯一入口：把识别结果写入目标输入框，或给出浮窗结论。
    func fill(text: String, targetPid: pid_t?) async -> TextFillResolution {
        let resolution = await performFill(text: text, targetPid: targetPid)
        FillVerifier.shared.detach()
        DebugTrace.log("TextFillEngine: \(resolution.summary)")
        textFillLog.info("resolution=\(resolution.summary, privacy: .public)")
        return resolution
    }
    private func performFill(text: String, targetPid: pid_t?) async -> TextFillResolution {
        guard !text.isEmpty else { return .overlay("empty text") }
        guard PermissionManager.shared.refreshAccessibilityStatus(reason: "text-fill") else {
            return .overlay("accessibility not granted")
        }
        // 自家 App（历史窗口重试等）：AX 查询自身不可靠，直接看 firstResponder
        if let targetPid, targetPid == ProcessInfo.processInfo.processIdentifier {
            return await fillSelfApp(text: text, pid: targetPid)
        }

        let verdict = await ContextCaptureWorker.run { FocusProbe.probe(targetPid: targetPid) }
        DebugTrace.log("TextFillEngine: probe verdict=\(verdict.summary)")
        switch verdict {
        case .editable(let reason):
            // 有选区时 Cmd+V 粘贴天然覆盖选区，rewrite 与 transcribe 行为一致
            await pasteViaCmdV(text: text, targetPid: targetPid)
            return .filled("Cmd+V; \(reason)")
        case .notEditable(let reason):
            return .overlay(reason)

        case .undetermined(let reason):
            return await blindFill(text: text, targetPid: targetPid, probeReason: reason)
        }
    }
    // MARK: - 填充手段

    /// Cmd+V 粘贴：请求级保存/恢复用户剪贴板
    private func pasteViaCmdV(text: String, targetPid: pid_t?) async {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            saved.restore(to: pasteboard)
            return
        }
        let expected = pasteboard.changeCount
        FocusedInputFiller.paste(to: targetPid)
        // 等目标 App 消费粘贴事件后再恢复剪贴板
        try? await Task.sleep(nanoseconds: 250_000_000)
        if !saved.restoreIfUnchanged(to: pasteboard, expectedChangeCount: expected, expectedString: text) {
            DebugTrace.log("TextFillEngine: skipped pasteboard restore because it changed")
        }
    }
    /// 快探不确定时（Excel 单元格 / 未知 role / AX 持续不可达）：
    /// 先粘贴，再通过 AX 通知确认是否真正写入；未确认则恢复剪贴板并走浮窗。
    private func blindFill(text: String, targetPid: pid_t?, probeReason: String) async -> TextFillResolution {
        guard let targetPid else {
            return .overlay("blind fill skipped, no target pid; \(probeReason)")
        }
        let verifier = FillVerifier.shared
        verifier.attach(pid: targetPid) // 录音开始时通常已挂载，这里幂等兜底
        guard verifier.isAttached else {
            return .overlay("blind fill unavailable, observer failed; \(probeReason)")
        }
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            saved.restore(to: pasteboard)
            return .overlay("pasteboard write failed; \(probeReason)")
        }
        let expected = pasteboard.changeCount
        verifier.arm()
        FocusedInputFiller.paste(to: targetPid)
        let confirmed = await verifier.waitForChange(timeoutSeconds: blindFillConfirmTimeout)

        if !saved.restoreIfUnchanged(to: pasteboard, expectedChangeCount: expected, expectedString: text) {
            DebugTrace.log("TextFillEngine: skipped pasteboard restore because it changed (blind fill)")
        }
        if confirmed {
            return .filled("blind Cmd+V confirmed; \(probeReason)")
        }
        // 超时无通知 ≠ 未写入：浏览器 AX 树未建好时没有节点能发通知（Jira 踩坑：
        // 粘贴实际生效却被误判失败，造成"既填充又浮窗"）。二次快探复查：
        // 此刻焦点元素可编辑 ⇒ 刚才的 Cmd+V 必然已写入该焦点元素 ⇒ 判已填充。
        let recheck = await ContextCaptureWorker.run { FocusProbe.probe(targetPid: targetPid) }
        if case .editable(let reason) = recheck {
            return .filled("blind Cmd+V; recheck editable(\(reason)); \(probeReason)")
        }
        return .overlay("blind Cmd+V not confirmed; recheck=\(recheck.summary); \(probeReason)")
    }
    /// 自家 App：直接看 keyWindow 的 firstResponder 是否文本输入控件
    private func fillSelfApp(text: String, pid: pid_t) async -> TextFillResolution {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return .overlay("self app has no key window")
        }
        let responder = window.firstResponder
        // NSTextView/NSText 必须看 isEditable：只读文本（教程只读示例、可选中 Text）
        // 背后的 responder 也可能是 NSTextView，按类型一刀切会误判成可编辑，
        // 造成 Cmd+V 静默无效且浮窗也不弹。聚焦的 NSTextField 其 firstResponder
        // 是窗口 field editor（isEditable 的 NSTextView），同样被 NSText 分支覆盖。
        let editable = (responder as? NSTextField)?.isEditable == true ||
            ((responder as? NSText)?.isEditable == true)
        guard editable else {
            let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
            return .overlay("self app firstResponder not editable (\(responderType))")
        }
        await pasteViaCmdV(text: text, targetPid: pid)
        return .filled("self app Cmd+V")
    }
}
