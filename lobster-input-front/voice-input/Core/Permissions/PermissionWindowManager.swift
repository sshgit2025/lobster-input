/// PermissionWindowManager.swift
/// 权限设置窗口管理器（单例）。
/// 以独立 NSWindow 承载 PermissionGateView，关闭时自动刷新权限状态。
import AppKit
import SwiftUI

final class PermissionWindowManager {

    static let shared = PermissionWindowManager()
    private init() {}

    /// 稳定的窗口标识，独立于本地化标题，供主窗口识别逻辑排除本窗口。
    static let windowIdentifier = "permission-window"

    private var window: NSWindow?

    @MainActor
    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PermissionGateView(onDone: { [weak self] in
            self?.hide()
        })

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: CyberLayout.permW, height: CyberLayout.permH),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "权限设置"
        w.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        // 不设置 .floating level，避免抢占主窗口焦点
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    @MainActor
    func hide() {
        window?.close()
        window = nil
        PermissionManager.shared.refreshStatuses()
        // 把焦点还给真正的主窗口：必须是可见的、titled 的普通窗口（排除浮窗 NSPanel、
        // 状态栏窗口、以及反馈/权限等辅助窗口），否则可能误把已隐藏的浮窗调出。
        let mainWindow = NSApp.windows.first { window in
            guard !(window is NSPanel), window.isVisible, window.styleMask.contains(.titled) else { return false }
            let identifier = window.identifier?.rawValue
            return identifier != Self.windowIdentifier && identifier != FeedbackWindowController.windowIdentifier
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}
