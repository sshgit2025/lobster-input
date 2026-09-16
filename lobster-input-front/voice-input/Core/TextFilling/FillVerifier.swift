/// FillVerifier.swift
/// 盲填结果确认器（判定权反转的核心）：
///   1. 录音开始时挂载 AXObserver 到目标 App —— 同时兼做 Chromium/Electron 的 AX 树预热，
///      取代旧 ManualAX 子树遍历 + 3 秒轮询（实测挂观察者即可让 Chromium 持续供给 AX 数据）。
///   2. 盲填 Cmd+V 后通过 AXValueChanged / AXSelectedTextChanged 通知被动确认文本是否真正写入，
///      实测（Chrome/Electron/原生）通知延迟 ~150ms；超时未收到即判定未写入。
import AppKit
import ApplicationServices
import Foundation
@MainActor
final class FillVerifier {
    static let shared = FillVerifier()
    private init() {}

    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var observedPid: pid_t = 0
    private var armedAt: Date?
    private var changedAt: Date?
    private static let notifications: [CFString] = [
        kAXValueChangedNotification as CFString,
        kAXSelectedTextChangedNotification as CFString
    ]

    var isAttached: Bool { observer != nil }
    /// 挂载观察者（幂等：同 pid 复用），并预热目标 App 的 AX 树：
    ///   - AXManualAccessibility：Electron 响应；Chrome/访达返回错误，忽略
    ///   - AXEnhancedUserInterface：Chrome 响应（VoiceOver 同款信号，返回错误码但实际生效）。
    ///     实测 Chrome 冷态下焦点查询永远 noValue 且不发任何通知（Jira 搜索栏踩坑），
    ///     设置该属性后约 2.3s 建好 AX 树，录音时长天然覆盖；detach 时设回 false 收窄副作用窗口
    func attach(pid: pid_t) {
        guard pid > 0 else { return }
        guard pid != observedPid || observer == nil else { return }
        detach()
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, AXTimeouts.probeQuery)
        _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let verifier = Unmanaged<FillVerifier>.fromOpaque(refcon).takeUnretainedValue()
            // 观察者源挂在主 RunLoop，回调必然在主线程执行
            MainActor.assumeIsolated {
                verifier.changedAt = Date()
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            DebugTrace.log("FillVerifier.attach: observer create failed pid=\(pid)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, appElement, name, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedElement = appElement
        observedPid = pid
        DebugTrace.log("FillVerifier.attach: pid=\(pid)")
    }
    /// 卸载观察者。录音取消或一次填充流程结束后调用，避免空闲期持续接收目标 App 通知。
    /// 同时关闭 AXEnhancedUserInterface，避免长开影响 Chrome 窗口拖拽等行为。
    func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        if let observedElement {
            _ = AXUIElementSetAttributeValue(observedElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        observer = nil
        observedElement = nil
        observedPid = 0
        armedAt = nil
        changedAt = nil
    }
    /// 盲填前调用：清零变化标记，之后只统计 arm 时间点以后的通知
    func arm() {
        armedAt = Date()
        changedAt = nil
    }
    /// 等待目标 App 发出内容变化通知；收到返回 true，超时返回 false。
    /// 30ms 轮询挂起（await 期间主 RunLoop 持续跑，能正常接收 AX 回调）。
    func waitForChange(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if confirmed { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return confirmed
    }

    private var confirmed: Bool {
        guard let armedAt, let changedAt else { return false }
        return changedAt >= armedAt
    }
}
