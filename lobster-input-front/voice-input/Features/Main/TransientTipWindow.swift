import SwiftUI
import AppKit

enum TransientTipStyle {
    case success
    case warning
    case error

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return Cyber.success
        case .warning: return Cyber.warning
        case .error: return Cyber.danger
        }
    }
}

@MainActor
final class TransientTipWindowController: NSObject {
    static let shared = TransientTipWindowController()

    private var panel: TransientTipPanel?
    private var dismissTask: Task<Void, Never>?

    private override init() { super.init() }

    func show(message: String, style: TransientTipStyle = .success, duration: TimeInterval = 0.5) {
        dismissTask?.cancel()
        if panel == nil {
            createPanel()
        }
        updateContent(message: message, style: style)
        repositionToScreen()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.hide()
            }
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func createPanel() {
        let size = CGSize(width: 260, height: 44)
        let win = TransientTipPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.level = .floating
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.isFloatingPanel = true
        panel = win
    }

    private func updateContent(message: String, style: TransientTipStyle) {
        guard let win = panel else { return }
        let size = CGSize(width: 260, height: 44)
        let hostingView = NSHostingView(rootView: TransientTipView(message: message, style: style))
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = hostingView
        win.setContentSize(size)
    }

    private func repositionToScreen() {
        guard let win = panel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let size = win.frame.size
        win.setFrameOrigin(CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + 88
        ))
    }
}

private final class TransientTipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct TransientTipView: View {
    let message: String
    let style: TransientTipStyle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(style.color)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Cyber.textBright)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 260, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Cyber.panelBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Cyber.borderDim, lineWidth: 1)
        )
    }
}
