/// FocusProbe.swift
/// 焦点输入框"一跳快探"：只查询焦点元素本身，不遍历 AX 树、不轮询。
/// 单次 AX IPC 超时 150ms，常规耗时 ~1ms（实测 Chrome/Electron/原生/访达）。
/// 三态结论：
///   editable     → 直接填充
///   notEditable  → 直接浮窗
///   undetermined → 由 TextFillEngine 盲填 + FillVerifier 通知确认兜底（Excel 单元格等）
import AppKit
import ApplicationServices
import Foundation
nonisolated enum FocusProbeVerdict: Sendable {
    case editable(String)
    case notEditable(String)
    case undetermined(String)

    var summary: String {
        switch self {
        case .editable(let r): return "editable(\(r))"
        case .notEditable(let r): return "notEditable(\(r))"
        case .undetermined(let r): return "undetermined(\(r))"
        }
    }
}
nonisolated enum FocusProbe {

    /// 文本输入类 role：AXValue 可写即判可编辑；不可写时降级为 undetermined（Excel 单元格等）
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXTextView", "AXTextEditor", "AXMultiLineTextField", "AXMultiLineTextArea"
    ]
    /// 明确非输入控件 role：AXValue 不可写时直接判不可编辑（实测覆盖 Cursor 文件树 AXGroup、
    /// 访达列表 AXList、各类按钮等）
    static let nonEditableRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton",
        "AXList", "AXTable", "AXOutline", "AXRow", "AXCell", "AXColumn",
        "AXImage", "AXStaticText", "AXLink", "AXMenu", "AXMenuItem", "AXMenuBar",
        "AXGroup", "AXScrollArea", "AXSplitter", "AXSplitGroup", "AXToolbar",
        "AXWindow", "AXSheet", "AXTabGroup", "AXSlider", "AXDisclosureTriangle"
    ]
    /// 录音开始时捕获目标 App PID：
    /// 优先 SystemWide 焦点元素所属进程（覆盖 Spotlight 等非前台浮层），失败回落前台 App。
    static func captureTargetPid() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, AXTimeouts.probeQuery)
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused {
            var pid: pid_t = 0
            if AXUIElementGetPid(focused as! AXUIElement, &pid) == .success, pid > 0 {
                return pid
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    /// 一跳快探。AX 错误（App 刚切换/树未就绪，实测仅出现在焦点切换瞬间）时隔 50ms 重试一次。
    /// 同步阻塞最多 ~0.35s，请在后台线程调用。
    static func probe(targetPid: pid_t?) -> FocusProbeVerdict {
        let pid = targetPid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid else { return .undetermined("no target pid") }
        let first = probeOnce(pid: pid)
        if case .undetermined(let reason) = first, reason.hasPrefix("ax error") {
            Thread.sleep(forTimeInterval: 0.05)
            return probeOnce(pid: pid)
        }
        return first
    }
    private static func probeOnce(pid: pid_t) -> FocusProbeVerdict {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, AXTimeouts.probeQuery)

        var focusedRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if err == .noValue {
            // noValue 不能当作"明确无焦点"：Chrome 等浏览器 AX 树未激活时，
            // 网页内已聚焦的输入框（如 Jira 搜索栏）同样返回 noValue。
            // 降级为 undetermined 走盲填确认：真无焦点 → 无通知 → 浮窗；
            // 树未激活但有输入框 → 粘贴生效收到通知 → 填充成功。
            return .undetermined("no focused element (noValue)")
        }
        guard err == .success, let focusedRef else {
            return .undetermined("ax error \(err.rawValue)")
        }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, AXTimeouts.probeQuery)
        let role = stringAttribute(kAXRoleAttribute, on: element) ?? ""
        if isValueSettable(element) {
            return .editable("role=\(role) value settable")
        }
        if editableRoles.contains(role) {
            // Excel 单元格等：文本 role 但 AXValue 不可写，键盘仍可输入 → 盲填确认兜底
            return .undetermined("text role=\(role) value not settable")
        }
        if nonEditableRoles.contains(role) {
            return .notEditable("non-editable role=\(role)")
        }
        return .undetermined("unknown role=\(role)")
    }
    // MARK: - AX 原语

    static func stringAttribute(_ name: String, on element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
    static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }
}
