/// TipOverlayWindow.swift
/// 轻量 tip 提示浮窗 — 显示系统级操作反馈提示（如 OpenClaw 开启/关闭状态）
/// 特性：
///   - 位于屏幕底部居中，不抢焦点
///   - 4 秒后自动淡出消失
///   - 右上角 X 按钮支持手动关闭
///   - 支持鼠标交互（需响应 X 按钮点击，故不设置 ignoresMouseEvents）
import SwiftUI
import AppKit

final class TipOverlayWindowController: NSObject {
    static let shared = TipOverlayWindowController()
    private var panel: TipPanel?
    private var dismissTimer: Timer?
    private override init() { super.init() }

    func show(message: String) {
        DispatchQueue.main.async { [weak self] in
            self?._show(message: message)
        }
    }

    private func _show(message: String) {
        if panel == nil { createPanel() }
        updateContent(message: message)
        repositionToScreen()
        panel?.alphaValue = 1.0
        panel?.orderFrontRegardless()
        scheduleDismiss()
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel?.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }
    }

    private func updateContent(message: String) {
        guard let win = panel else { return }
        let hostingView = NSHostingView(rootView: TipOverlayView(
            message: message,
            onClose: { [weak self] in self?.hide() }
        ))
        let size = CGSize(width: 320, height: 56)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = hostingView
        win.setContentSize(size)
    }

    private func repositionToScreen() {
        guard let win = panel else { return }
        let ml = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(ml, $0.frame, false) } ?? NSScreen.main
        guard let s = screen else { return }
        let sz = win.frame.size
        win.setFrameOrigin(CGPoint(
            x: s.frame.minX + (s.frame.width - sz.width) / 2,
            y: s.frame.minY + 60
        ))
    }

    private func createPanel() {
        let size = CGSize(width: 320, height: 56)
        let hostingView = NSHostingView(rootView: TipOverlayView(message: "", onClose: {}))
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let win = TipPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.contentView = hostingView
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.level = .floating
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.isFloatingPanel = true
        win.becomesKeyOnlyIfNeeded = true
        self.panel = win
    }
}

private final class TipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

struct TipOverlayView: View {
    let message: String
    let onClose: () -> Void
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Cyber.accent)
                .frame(width: 15)
                .padding(.trailing, 10)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Cyber.textBright)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Cyber.textGhost)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.clear))
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 320, height: 56)
        .background(tipBackground)
        .overlay(tipBorder)
    }

    private var tipBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Cyber.panelBg)
    }

    private var tipBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(Cyber.borderDim, lineWidth: 1)
    }
}
