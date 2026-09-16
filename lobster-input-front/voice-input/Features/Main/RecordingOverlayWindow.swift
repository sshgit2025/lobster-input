/// RecordingOverlayWindow.swift
/// 录音/识别状态悬浮窗
import SwiftUI
import AppKit
import Combine
import os.log

private let overlayLog = Logger(subsystem: "ssh2026.voice-input", category: "RecordingOverlay")

/// 浮窗可见性的可观察状态。控制器 show/hide 时切换，视图据此启停 16Hz 动画定时器。
/// 解决 NSPanel.orderOut 不触发 SwiftUI onDisappear、导致隐藏后定时器仍在主线程空转的问题。
final class RecordingOverlayVisibility: ObservableObject {
    static let shared = RecordingOverlayVisibility()
    @Published var isVisible = false
    private init() {}
}

final class RecordingOverlayWindowController: NSObject {
    static let shared = RecordingOverlayWindowController()
    private var panel: FloatingPanel?
    private override init() { super.init() }

    func show() {
        if panel == nil { createPanel() }
        repositionToMouseScreen()
        overlayLog.info("show overlay: appActive=\(NSApp.isActive), panelExists=\(self.panel != nil)")
        DebugTrace.log("Overlay show: appActive=\(NSApp.isActive), panelExists=\(self.panel != nil)")
        RecordingOverlayVisibility.shared.isVisible = true
        panel?.orderFrontRegardless()
        overlayLog.info("overlay ordered front regardless")
        DebugTrace.log("Overlay ordered front regardless")
    }
    func hide() {
        overlayLog.info("hide overlay")
        DebugTrace.log("Overlay hide")
        panel?.orderOut(nil)
        RecordingOverlayVisibility.shared.isVisible = false
    }

    private func repositionToMouseScreen() {
        guard let win = panel else { return }
        let ml = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(ml, $0.frame, false) } ?? NSScreen.main
        guard let s = screen else { return }
        let sz = win.frame.size
        win.setFrameOrigin(CGPoint(x: s.frame.minX + (s.frame.width - sz.width) / 2, y: s.frame.minY + s.frame.height * 0.12))
    }

    private func createPanel() {
        let size = CGSize(width: CyberLayout.overlayW, height: CyberLayout.overlayH)
        let view = NSHostingView(rootView: RecordingOverlayView())
        view.frame = CGRect(origin: .zero, size: size)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        // 使用 NSPanel + nonactivating styleMask 保留当前输入焦点。
        // NSPanel 不参与正常焦点传递，不会抢走其他 App 的选中文本
        let win = FloatingPanel(
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
        // 关键：关闭所有会导致 App 激活的行为
        win.isFloatingPanel = true
        win.becomesKeyOnlyIfNeeded = true
        overlayLog.info("create overlay panel: level=\(win.level.rawValue), canBecomeKey=\(win.canBecomeKey), ignoresMouse=\(win.ignoresMouseEvents)")
        DebugTrace.log("Overlay create panel: level=\(win.level.rawValue), canBecomeKey=\(win.canBecomeKey), ignoresMouse=\(win.ignoresMouseEvents)")
        self.panel = win
    }
}

/// NSPanel 子类，通过非激活面板样式避免抢占输入焦点。
/// nonactivatingPanel styleMask 确保浮窗出现时完全不触发任何 App 激活流程
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct RecordingOverlayView: View {
    @ObservedObject private var recorder = AudioRecorder.shared
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var visibility = RecordingOverlayVisibility.shared
    @State private var waveformLevels: [Float] = Array(repeating: 0.08, count: 10)
    @State private var timer: Timer?
    @State private var dotPhase: Int = 0
    @State private var visualStartAt = Date()

    private var isProcessing: Bool { recorder.state == .processing }
    private var isStarting: Bool { recorder.state == .starting }
    private var isCountingDown: Bool { recorder.countdown != nil && !isProcessing }
    private var themeColor: Color {
        if isProcessing { return Cyber.warning }
        if isCountingDown { return Cyber.danger }
        return Cyber.accent
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                OverlayWaveBars(
                    levels: Array(waveformLevels.prefix(5)),
                    mirrored: false,
                    isProcessing: isProcessing,
                    phase: dotPhase,
                    phaseOffset: 0
                )
                .frame(width: 42, height: 16)
                .padding(.trailing, 8)

                centerStatus
                    .frame(maxWidth: .infinity)

                OverlayWaveBars(
                    levels: Array(waveformLevels.suffix(5)),
                    mirrored: false,
                    isProcessing: isProcessing,
                    phase: dotPhase,
                    phaseOffset: 5
                )
                .frame(width: 42, height: 16)
                .padding(.leading, 8)
            }
            .padding(.horizontal, 14)
            .frame(width: CyberLayout.overlayW, height: CyberLayout.overlayH)
            .background(overlayBg)
            .overlay(borderOverlay)
            .contentShape(Capsule())

            Button {
                NotificationCenter.default.post(name: isProcessing ? .overlayDismissedDuringProcessing : .overlayDismissedDuringRecording, object: nil)
            } label: {
                Color.clear
            }
            .buttonStyle(.plain)
        }
        .frame(width: CyberLayout.overlayW, height: CyberLayout.overlayH)
        .onAppear {
            visualStartAt = Date()
            if visibility.isVisible { startAnimationTimer() }
        }
        .onChange(of: visibility.isVisible) { _, isVisible in
            if isVisible {
                visualStartAt = Date()
                startAnimationTimer()
            } else {
                stopAnimationTimer()
            }
        }
        .onChange(of: recorder.state) { _, newState in
            if newState == .starting {
                visualStartAt = Date()
                waveformLevels = Array(repeating: 0.08, count: 10)
            }
        }
        .onDisappear { stopAnimationTimer() }
    }

    private var centerStatus: some View {
        VStack(spacing: 1) {
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .tint(Cyber.accent)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(themeColor)
                    .frame(width: 18, height: 14)
            }

            if !isProcessing {
                Text(statusText)
                    .font(.system(size: 9, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(isCountingDown ? Cyber.danger : Cyber.textDim)
                    .lineLimit(1)
                    .frame(maxWidth: 58)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 58)
        .animation(.easeInOut(duration: 0.2), value: isProcessing)
        .animation(.easeInOut(duration: 0.2), value: isCountingDown)
    }

    private var statusText: String {
        if let sec = recorder.countdown, !isProcessing { return "\(sec)s" }
        return elapsedText
    }

    private var elapsedText: String {
        let elapsedSeconds = recorder.state == .starting
            ? max(recorder.elapsedSeconds, Int(Date().timeIntervalSince(visualStartAt)))
            : recorder.elapsedSeconds
        return String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    private var overlayBg: some View {
        Capsule()
            .fill(Cyber.panelBg)
    }

    private var borderOverlay: some View {
        Capsule().stroke(Cyber.borderDim, lineWidth: 1)
    }

    private func startAnimationTimer() {
        stopAnimationTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            Task { @MainActor in
                if self.isProcessing {
                    self.dotPhase = (self.dotPhase + 1) % 10
                    return
                }
                let input = max(0, min(1, self.recorder.audioLevel))
                let idle = Float.random(in: 0.08...0.26)
                let reactive = input * Float.random(in: 0.75...1.2)
                self.waveformLevels.removeFirst()
                self.waveformLevels.append(max(0.05, min(1, max(idle, reactive))))
            }
        }
    }

    private func stopAnimationTimer() {
        timer?.invalidate()
        timer = nil
    }
}

private struct OverlayWaveBars: View {
    let levels: [Float]
    let mirrored: Bool
    let isProcessing: Bool
    let phase: Int
    let phaseOffset: Int

    var body: some View {
        ZStack(alignment: .center) {
            ForEach(Array(displayLevels.enumerated()), id: \.offset) { localIndex, level in
                let globalIndex = phaseOffset + localIndex
                let active = isProcessing && globalIndex == phase
                let near = isProcessing && globalIndex == (phase + 9) % 10
                RoundedRectangle(cornerRadius: isProcessing ? 3 : 1)
                    .fill(Cyber.accent)
                    .frame(
                        width: isProcessing ? (active ? 8 : 6) : 2,
                        height: isProcessing ? (active ? 8 : 6) : max(4, min(16, 4 + 16 * CGFloat(level)))
                    )
                    .opacity(isProcessing ? (active ? 1 : near ? 0.55 : 0.28) : 0.45 + min(0.5, Double(level) * 0.75))
                    .position(x: barX(localIndex, active: active), y: 8)
                    .animation(.easeOut(duration: 0.08), value: level)
                    .animation(.easeInOut(duration: 0.16), value: phase)
            }
        }
        .frame(width: 42, height: 16)
    }

    private var displayLevels: [Float] {
        mirrored ? Array(levels.reversed()) : levels
    }

    private func barX(_ localIndex: Int, active: Bool) -> CGFloat {
        let leftPositions: [CGFloat] = [4, 10, 16, 22, 28]
        let rightPositions: [CGFloat] = [10, 16, 22, 28, 34]
        let left = phaseOffset == 0 ? leftPositions[localIndex] : rightPositions[localIndex]
        let width: CGFloat = isProcessing ? (active ? 8 : 6) : 2
        return left + width / 2
    }
}
