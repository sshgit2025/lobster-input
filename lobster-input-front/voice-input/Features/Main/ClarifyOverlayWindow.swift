/// ClarifyOverlayWindow.swift
/// 意图确认悬浮窗 — 当 rewrite 操作 LLM 无法理解指令时显示询问文案
/// 关键设计：窗口不抢焦点（canBecomeKey = false），不影响用户原输入框的选中状态
import SwiftUI
import AppKit

final class ClarifyOverlayWindowController: NSObject {
    static let shared = ClarifyOverlayWindowController()
    private let overlayWidth: CGFloat = 154
    private var panel: ClarifyPanel?
    private var dismissTimer: Timer?
    private override init() { super.init() }

    func show(question: String) {
        if panel == nil { createPanel() }
        updateContent(question: question)
        repositionToMouseScreen()
        panel?.orderFrontRegardless()
        scheduleDismiss()
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }
    }

    private func updateContent(question: String) {
        guard let win = panel else { return }
        let view = NSHostingView(rootView: ClarifyOverlayView(question: question))
        let size = contentSize(for: question)
        view.frame = CGRect(origin: .zero, size: size)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = view
        win.setContentSize(size)
    }

    private func contentSize(for question: String) -> CGSize {
        // 根据文案长度动态调整高度（约每40字符一行，最小高度90，最大140）
        let approxLines = max(1, Int(ceil(Double(question.count) / 28.0)))
        let h = min(140, max(90, 54 + approxLines * 22))
        return CGSize(width: overlayWidth, height: CGFloat(h))
    }

    private func repositionToMouseScreen() {
        guard let win = panel else { return }
        let ml = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(ml, $0.frame, false) } ?? NSScreen.main
        guard let s = screen else { return }
        let sz = win.frame.size
        // 显示在录音浮窗下方（offset -80），避免与录音浮窗重叠
        win.setFrameOrigin(CGPoint(
            x: s.frame.minX + (s.frame.width - sz.width) / 2,
            y: s.frame.minY + s.frame.height * 0.12 - sz.height - 12
        ))
    }

    private func createPanel() {
        let size = CGSize(width: overlayWidth, height: 100)
        let view = NSHostingView(rootView: ClarifyOverlayView(question: ""))
        view.frame = CGRect(origin: .zero, size: size)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        let win = ClarifyPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.contentView = view
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.level = .floating
        win.ignoresMouseEvents = true  // 完全穿透，不抢任何交互
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.isFloatingPanel = true
        win.becomesKeyOnlyIfNeeded = true
        self.panel = win
    }
}

/// 使用 NSPanel + nonactivatingPanel 展示浮层并保留输入焦点。
private final class ClarifyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

struct ClarifyOverlayView: View {
    let question: String
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 10) {
                clarifyIcon
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.overlayClarifyTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Cyber.warning)
                    Text(question.isEmpty ? L10n.overlayClarifyFallback : question)
                        .font(.system(size: 12))
                        .foregroundStyle(Cyber.textDim)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 154)
        .background(overlayBg)
        .overlay(borderOverlay)
    }

    private var clarifyIcon: some View {
        ZStack {
            Circle()
                .stroke(Cyber.warning, lineWidth: 1)
                .frame(width: 28, height: 28)
            Text("?")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Cyber.warning)
        }
        .frame(width: 28, height: 28)
    }

    private var overlayBg: some View {
        RoundedRectangle(cornerRadius: CyberLayout.corner)
            .fill(Cyber.panelBg)
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: CyberLayout.corner)
            .stroke(Cyber.warning.opacity(0.4), lineWidth: 1)
    }
}
