import SwiftUI
import AppKit
import Combine

/// 实时录音浮窗可见性的可观察状态，控制器 show/hide 时切换，视图据此启停 16Hz 动画定时器，
/// 避免 NSPanel.orderOut 不触发 onDisappear 导致隐藏后定时器仍持续空转。
final class RealtimeRecordingOverlayVisibility: ObservableObject {
    static let shared = RealtimeRecordingOverlayVisibility()
    @Published var isVisible = false
    private init() {}
}

final class RealtimeRecordingOverlayWindowController: NSObject {
    static let shared = RealtimeRecordingOverlayWindowController()
    private var panel: RealtimeFloatingPanel?
    private override init() { super.init() }

    func show() {
        if panel == nil { createPanel() }
        repositionToMouseScreen()
        RealtimeRecordingOverlayVisibility.shared.isVisible = true
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        RealtimeRecordingOverlayVisibility.shared.isVisible = false
    }

    private func repositionToMouseScreen() {
        guard let win = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let size = win.frame.size
        win.setFrameOrigin(CGPoint(
            x: screen.frame.minX + (screen.frame.width - size.width) / 2,
            y: screen.frame.minY + screen.frame.height * 0.12
        ))
    }

    private func createPanel() {
        let size = CGSize(width: 420, height: 112)
        let view = NSHostingView(rootView: RealtimeRecordingOverlayView())
        view.frame = CGRect(origin: .zero, size: size)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        let win = RealtimeFloatingPanel(
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
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.isFloatingPanel = true
        win.becomesKeyOnlyIfNeeded = true
        panel = win
    }
}

private final class RealtimeFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct RealtimeRecordingOverlayView: View {
    @ObservedObject private var streamer = RealtimeAudioStreamer.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var visibility = RealtimeRecordingOverlayVisibility.shared
    @State private var waveformLevels: [Float] = Array(repeating: 0.08, count: 10)
    @State private var timer: Timer?

    private var displayText: String {
        // 显示打字机平滑后的文本;业务仍读取完整的 streamer.liveText,互不影响。
        streamer.displayLiveText.isEmpty ? L10n.overlayRealtimeListening : streamer.displayLiveText
    }

    private var bubbleWidth: CGFloat {
        let count = max(5, min(22, displayText.count))
        return min(308, max(118, 56 + CGFloat(count) * 11))
    }

    var body: some View {
        VStack(spacing: 7) {
            if streamer.state != .processing {
                realtimeBubble
                    .frame(width: bubbleWidth, height: 46)
                    .animation(.spring(response: 0.22, dampingFraction: 0.88), value: bubbleWidth)
            }
            recorderCapsule
        }
        .frame(width: 420, height: 112)
        .onAppear { if visibility.isVisible { startTimer() } }
        .onChange(of: visibility.isVisible) { _, isVisible in
            if isVisible { startTimer() } else { stopTimer() }
        }
        .onDisappear { stopTimer() }
    }

    private var realtimeBubble: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(Cyber.accentSoft)
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(streamer.state == .processing ? Cyber.warning : Cyber.accent)
                        .frame(width: 7, height: 7)
                }

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            Text(displayText)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Cyber.textBright)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .id("text-end")
                        }
                        .padding(.trailing, 1)
                        .frame(minWidth: max(0, bubbleWidth - 67), alignment: .leading)
                    }
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.07),
                                .init(color: .black, location: 0.92),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                    .onChange(of: displayText) { _, _ in
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo("text-end", anchor: .trailing)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(width: bubbleWidth, height: 38)
            .background(bubbleBackground)
            .overlay(bubbleBorder)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            RealtimeBubbleTail()
                .fill(Cyber.panelBg.opacity(0.96))
                .frame(width: 14, height: 8)
                .overlay(
                    RealtimeBubbleTail()
                        .stroke(Cyber.lineStrong.opacity(0.65), lineWidth: 0.8)
                )
                .offset(y: -1)
        }
        .shadow(color: Color.black.opacity(themeStore.mode == .sandDark ? 0.36 : 0.13), radius: 12, x: 0, y: 8)
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Cyber.panelBg.opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Cyber.accentSoft.opacity(themeStore.mode == .sandDark ? 0.55 : 0.75))
                    .blendMode(.plusLighter)
            )
    }

    private var bubbleBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Cyber.lineStrong.opacity(0.75), lineWidth: 0.8)
    }

    private var recorderCapsule: some View {
        HStack(spacing: 0) {
            RealtimeWaveBars(levels: Array(waveformLevels.prefix(5)))
                .frame(width: 42, height: 16)
                .padding(.trailing, 8)

            VStack(spacing: 1) {
                if streamer.state == .processing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Cyber.accent)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(streamer.countdown == nil ? Cyber.accent : Cyber.danger)
                        .frame(width: 18, height: 14)
                }
                if streamer.state != .processing {
                    Text(statusText)
                        .font(.system(size: 9, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundStyle(streamer.countdown == nil ? Cyber.textDim : Cyber.danger)
                        .lineLimit(1)
                        .frame(width: 58)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: 58)

            RealtimeWaveBars(levels: Array(waveformLevels.suffix(5)))
                .frame(width: 42, height: 16)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 14)
        .frame(width: CyberLayout.overlayW, height: CyberLayout.overlayH)
        .background(Capsule().fill(Cyber.panelBg))
        .overlay(Capsule().stroke(Cyber.borderDim, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture {
            NotificationCenter.default.post(
                name: streamer.state == .processing ? .overlayDismissedDuringProcessing : .realtimeOverlayDismissedDuringStreaming,
                object: nil
            )
        }
    }

    private var statusText: String {
        if let sec = streamer.countdown { return "\(sec)s" }
        return String(format: "%02d:%02d", streamer.elapsedSeconds / 60, streamer.elapsedSeconds % 60)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            Task { @MainActor in
                let input = max(0, min(1, streamer.audioLevel))
                let idle = Float.random(in: 0.08...0.24)
                let reactive = input * Float.random(in: 0.75...1.2)
                waveformLevels.removeFirst()
                waveformLevels.append(max(0.05, min(1, max(idle, reactive))))
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

private struct RealtimeBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct RealtimeWaveBars: View {
    let levels: [Float]

    var body: some View {
        ZStack(alignment: .center) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Cyber.accent)
                    .frame(width: 2, height: max(4, min(16, 4 + 16 * CGFloat(level))))
                    .opacity(0.45 + min(0.5, Double(level) * 0.75))
                    .position(x: [6, 13, 20, 27, 34][index], y: 8)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}
