/// ResultOverlayWindow.swift
/// 结果展示悬浮窗 — 支持两种展示模式：
///   普通文本模式（rewrite 结果等）：按内容和屏幕可见区域动态计算初始宽高
///   Markdown 模式（show_markdown / 搜索结果）：NSTextView 渲染 Markdown，链接可点击打开浏览器
/// 关键设计：窗口可拖动、可缩放，缩放热区带光标反馈，内容溢出时由内容区滚动承接。
/// 默认 30 秒后自动消失，用户可点「常驻」按钮取消倒计时改为手动关闭。
import SwiftUI
import AppKit

@MainActor
final class ResultOverlayWindowController: NSObject {
    static let shared = ResultOverlayWindowController()
    private var panel: ResultPanel?
    private var hostingView: NSHostingView<ResultOverlayView>?
    private var dismissTimer: Timer?
    private var viewModel = ResultOverlayViewModel()
    private var activeMarkdownStreamID: UUID?
    private override init() { super.init() }

    /// 展示普通文本（rewrite、agent/paste 结果）
    func show(text: String) {
        _show(text: text, isMarkdown: false)
    }

    /// 展示 Markdown 内容（搜索结果）
    /// - Parameter pinned: 是否默认置为常驻（历史记录手动打开时传 true）
    func showMarkdown(text: String, pinned: Bool = false) {
        _show(text: text, isMarkdown: true, pinned: pinned)
    }

    func beginMarkdownStream(streamID: UUID) {
        activeMarkdownStreamID = streamID
    }

    func updateMarkdown(text: String) {
        ensurePanel()
        guard panel?.isVisible == true, viewModel.isMarkdown else {
            showMarkdown(text: text)
            return
        }
        viewModel.text = text
        viewModel.copied = false
        growMarkdownPanelIfNeeded(for: text)
    }

    func updateMarkdown(text: String, streamID: UUID) {
        ensurePanel()
        if let activeMarkdownStreamID, activeMarkdownStreamID != streamID {
            DebugTrace.log("ResultOverlay ignored stale markdown stream update: streamID=\(streamID)")
            return
        }
        if activeMarkdownStreamID == nil || panel?.isVisible != true || !viewModel.isMarkdown {
            activeMarkdownStreamID = streamID
            showMarkdown(text: text)
            return
        }
        viewModel.text = text
        viewModel.copied = false
        growMarkdownPanelIfNeeded(for: text)
    }

    func hide() {
        DebugTrace.log("ResultOverlay hide")
        dismissTimer?.invalidate()
        dismissTimer = nil
        activeMarkdownStreamID = nil
        panel?.orderOut(nil)
    }

    private func _show(text: String, isMarkdown: Bool, pinned: Bool = false) {
        ensurePanel()
        if !isMarkdown {
            activeMarkdownStreamID = nil
        }
        panel?.resetManualResizeTracking()

        viewModel.text = text
        viewModel.isMarkdown = isMarkdown
        viewModel.countdown = 30
        viewModel.pinned = pinned
        viewModel.copied = false

        updateHostingView(for: text, isMarkdown: isMarkdown)
        guard let panel else {
            DebugTrace.log("ResultOverlay _show skipped: panel unavailable after create")
            return
        }
        panel.orderFrontRegardless()
        DebugTrace.log("ResultOverlay _show: textLen=\(text.count), isMarkdown=\(isMarkdown), panelVisible=\(panel.isVisible), frame=\(panel.frame)")
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        viewModel.countdown = 30

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.viewModel.pinned else { return }
                self.viewModel.countdown -= 1
                if self.viewModel.countdown <= 0 { self.hide() }
            }
        }
    }

    private func currentScreen() -> NSScreen? {
        let ml = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(ml, $0.frame, false) } ?? NSScreen.main
    }

    private func placePanel(on screen: NSScreen, size: CGSize) {
        guard let win = panel else { return }
        let visible = screen.visibleFrame
        let sz = win.frame.size
        let x = visible.minX + (visible.width - sz.width) / 2
        let preferredY = visible.maxY - size.height - max(72, visible.height * 0.10)
        win.setFrameOrigin(CGPoint(
            x: min(max(x, visible.minX + 16), visible.maxX - sz.width - 16),
            y: min(max(preferredY, visible.minY + 16), visible.maxY - sz.height - 16)
        ))
    }

    private func updateHostingView(for text: String, isMarkdown: Bool) {
        ensurePanel()
        guard let hv = hostingView, let win = panel else {
            DebugTrace.log("ResultOverlay update skipped: missing hosting view or panel")
            return
        }
        guard let screen = currentScreen() else {
            DebugTrace.log("ResultOverlay update skipped: no screen")
            return
        }
        hv.rootView = ResultOverlayView(viewModel: viewModel, onDismiss: { [weak self] in
            Task { @MainActor in self?.hide() }
        })

        let size = preferredSize(for: text, isMarkdown: isMarkdown, on: screen)
        hv.sizingOptions = []
        // 先更新 hv.frame，再更新 window size，顺序不能颠倒
        hv.frame = CGRect(origin: .zero, size: size)
        win.setContentSize(size)
        win.minSize = CGSize(width: 360, height: 180)
        win.maxSize = maxPanelSize(isMarkdown: isMarkdown, on: screen)
        placePanel(on: screen, size: size)
    }

    private func growMarkdownPanelIfNeeded(for text: String) {
        guard viewModel.isMarkdown else { return }
        guard let win = panel, let hv = hostingView, win.isVisible else { return }
        guard !win.wasManuallyResized else { return }
        guard let screen = win.screen ?? currentScreen() else { return }

        win.maxSize = maxPanelSize(isMarkdown: true, on: screen)

        let currentFrame = win.frame
        let preferred = preferredSize(for: text, isMarkdown: true, on: screen)
        let targetHeight = min(win.maxSize.height, max(currentFrame.height, preferred.height))
        guard targetHeight > currentFrame.height + 1 else { return }

        let visible = screen.visibleFrame
        var nextFrame = currentFrame
        nextFrame.size.height = targetHeight
        nextFrame.origin.y = currentFrame.maxY - targetHeight
        nextFrame.origin.y = min(max(nextFrame.origin.y, visible.minY + 16), visible.maxY - targetHeight - 16)

        hv.frame = CGRect(origin: .zero, size: nextFrame.size)
        win.setFrame(nextFrame, display: true)
    }

    private func maxPanelSize(isMarkdown: Bool, on screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame
        let maxHeight = isMarkdown
            ? min(CyberLayout.searchOverlayMaxH, visible.height - 32)
            : visible.height - 32
        return CGSize(width: visible.width - 32, height: maxHeight)
    }

    private func ensurePanel() {
        guard let panel, let hostingView else {
            createPanel()
            return
        }
        guard NSApp.windows.contains(panel), panel.contentView === hostingView else {
            DebugTrace.log("ResultOverlay panel invalid, recreating")
            panel.orderOut(nil)
            self.panel = nil
            self.hostingView = nil
            createPanel()
            return
        }
    }

    private func preferredSize(for text: String, isMarkdown: Bool, on screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame
        let minW: CGFloat = isMarkdown ? 560 : 420
        let maxW = min(isMarkdown ? 860 : 760, visible.width * 0.86)
        let charsPerLine = max(34, min(96, text.split(separator: "\n").map(\.count).max() ?? text.count))
        let targetW = CGFloat(charsPerLine) * 7.2 + 96
        let width = min(max(minW, targetW), maxW)

        let wrappedLines = estimatedLineCount(text: text, width: width)
        let contentH = CGFloat(wrappedLines) * (isMarkdown ? 20 : 19)
        let minH = isMarkdown ? CyberLayout.searchOverlayMinH : CyberLayout.resultOverlayMinH
        let maxH = min(isMarkdown ? CyberLayout.searchOverlayMaxH : 520, visible.height * 0.72)
        let height = min(max(minH, contentH + ResultOverlayView.headerFooterH + 28), maxH)
        return CGSize(width: width, height: height)
    }

    private func estimatedLineCount(text: String, width: CGFloat) -> Int {
        let usableColumns = max(28, Int((width - 64) / 7.2))
        return max(1, text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(usableColumns))))
        })
    }

    private func createPanel() {
        let rootView = ResultOverlayView(viewModel: viewModel) { [weak self] in
            Task { @MainActor in self?.hide() }
        }
        let hv = NSHostingView(rootView: rootView)
        hv.sizingOptions = []
        hv.wantsLayer = true
        hv.layer?.backgroundColor = NSColor.clear.cgColor
        let initSize = CGSize(width: CyberLayout.resultOverlayW, height: CyberLayout.resultOverlayMinH)
        hv.frame = CGRect(origin: .zero, size: initSize)
        hv.autoresizingMask = [.width, .height]

        let win = ResultPanel(
            contentRect: CGRect(origin: .zero, size: initSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        win.contentView = hv
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.level = .floating
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces]
        win.isFloatingPanel = true
        win.becomesKeyOnlyIfNeeded = true
        win.isMovableByWindowBackground = true
        self.hostingView = hv
        self.panel = win
    }
}

private struct ResultOverlayResizeHandle: View {
    enum Kind {
        case right
        case bottom
        case bottomRight
    }

    let kind: Kind

    var body: some View {
        ZStack {
            ResultOverlayResizeHandleView(kind: kind)
            handleContent
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var handleContent: some View {
        if kind == .bottomRight {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    cornerGrip
                        .padding(8)
                }
            }
        } else {
            Color.clear
        }
    }

    private var cornerGrip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Cyber.accent.opacity(0.55))
            .rotationEffect(.degrees(-45))
    }

}

private struct ResultOverlayResizeHandleView: NSViewRepresentable {
    let kind: ResultOverlayResizeHandle.Kind

    func makeNSView(context: Context) -> ResizeHandleNSView {
        ResizeHandleNSView(kind: kind)
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.kind = kind
    }
}

private final class ResizeHandleNSView: NSView {
    var kind: ResultOverlayResizeHandle.Kind {
        didSet {
            resetCursorRects()
        }
    }

    private var startFrame: CGRect = .zero
    private var startMouseScreenPoint: CGPoint = .zero

    init(kind: ResultOverlayResizeHandle.Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.kind = .bottomRight
        super.init(coder: coder)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseEntered(with event: NSEvent) {
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? ResultPanel else { return }
        panel.markManuallyResized()
        startFrame = panel.frame
        startMouseScreenPoint = mouseScreenPoint(from: event)
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = window as? ResultPanel else { return }
        let currentPoint = mouseScreenPoint(from: event)
        let delta = CGSize(
            width: currentPoint.x - startMouseScreenPoint.x,
            height: startMouseScreenPoint.y - currentPoint.y
        )
        panel.setFrame(resizedFrame(for: panel, delta: delta), display: true)
        cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        cursor.set()
    }

    private var cursor: NSCursor {
        switch kind {
        case .right:
            return .resizeLeftRight
        case .bottom:
            return .resizeUpDown
        case .bottomRight:
            return .diagonalResize45
        }
    }

    private func mouseScreenPoint(from event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        let pointInWindow = event.locationInWindow
        return window.convertPoint(toScreen: pointInWindow)
    }

    private func resizedFrame(for panel: ResultPanel, delta: CGSize) -> CGRect {
        let minSize = panel.minSize
        let maxSize = panel.maxSize
        var next = startFrame

        if kind == .right || kind == .bottomRight {
            next.size.width = min(maxSize.width, max(minSize.width, startFrame.width + delta.width))
        }
        if kind == .bottom || kind == .bottomRight {
            let targetHeight = min(maxSize.height, max(minSize.height, startFrame.height + delta.height))
            let heightDelta = targetHeight - startFrame.height
            next.origin.y = startFrame.origin.y - heightDelta
            next.size.height = targetHeight
        }

        return next
    }
}

private extension NSCursor {
    static let diagonalResize45: NSCursor = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.set()
        if let symbol = NSImage(systemSymbolName: "arrow.up.left.and.down.right", accessibilityDescription: nil) {
            symbol.draw(in: NSRect(x: 1, y: 1, width: 16, height: 16))
        } else {
            NSBezierPath.strokeLine(from: NSPoint(x: 3, y: 15), to: NSPoint(x: 15, y: 3))
        }
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }()
}

private final class ResultPanel: NSPanel {
    private(set) var wasManuallyResized = false

    override var canBecomeKey: Bool { true }   // Markdown 模式需要接收键盘事件（滚动）
    override var canBecomeMain: Bool { false }

    func markManuallyResized() {
        wasManuallyResized = true
    }

    func resetManualResizeTracking() {
        wasManuallyResized = false
    }
}

// MARK: - OpenClaw Task Overlay

@MainActor
final class OpenClawTaskOverlayWindowController: NSObject {
    static let shared = OpenClawTaskOverlayWindowController()

    private var panel: OpenClawTaskPanel?
    private var hostingView: NSHostingView<OpenClawTaskOverlayView>?
    private var viewModel = OpenClawTaskOverlayViewModel()
    private var timer: Timer?

    private override init() { super.init() }

    func closeFromUser() {
        if viewModel.phase == .running {
            OpenClawManager.shared.abortCurrentOpenClawTask(showFeedback: false)
        }
        hide()
    }

    func showConnecting() {
        ensurePanel()
        viewModel.title = "OpenClaw"
        viewModel.status = "连接中"
        viewModel.phase = .running
        viewModel.runId = nil
        viewModel.messageSeq = nil
        viewModel.transcript = "OpenClaw 已启动，正在连接任务..."
        viewModel.startedAt = Date()
        viewModel.elapsed = 0
        viewModel.copied = false
        updatePanel()
        startElapsedTimer()
    }

    func showRunning(runId: String?, messageSeq: Int?) {
        ensurePanel()
        viewModel.status = "运行中"
        viewModel.phase = .running
        viewModel.runId = runId
        viewModel.messageSeq = messageSeq
        if viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            viewModel.transcript == "OpenClaw 已启动，正在连接任务..." {
            viewModel.transcript = "任务已开始，正在等待 OpenClaw 返回执行过程..."
        }
        updatePanel()
    }

    func updateTranscript(_ text: String) {
        ensurePanel()
        viewModel.status = "运行中"
        viewModel.phase = .running
        viewModel.transcript = text
        updatePanel(allowResize: false)
    }

    func finish(_ text: String) {
        ensurePanel()
        viewModel.status = "已完成"
        viewModel.phase = .finished
        viewModel.transcript = text
        updatePanel(allowResize: false)
        stopElapsedTimer()
    }

    func markAborted(_ text: String) {
        ensurePanel()
        viewModel.status = "已中断"
        viewModel.phase = .aborted
        viewModel.transcript = text
        updatePanel(allowResize: false)
        stopElapsedTimer()
    }

    func showError(_ text: String) {
        ensurePanel()
        viewModel.status = "失败"
        viewModel.phase = .failed
        viewModel.transcript = text
        updatePanel(allowResize: false)
        stopElapsedTimer()
    }

    func hide() {
        stopElapsedTimer()
        panel?.orderOut(nil)
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.viewModel.elapsed = Int(Date().timeIntervalSince(self.viewModel.startedAt))
            }
        }
    }

    private func stopElapsedTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func ensurePanel() {
        guard let panel, let hostingView else {
            createPanel()
            return
        }
        guard NSApp.windows.contains(panel), panel.contentView === hostingView else {
            panel.orderOut(nil)
            self.panel = nil
            self.hostingView = nil
            createPanel()
            return
        }
    }

    private func createPanel() {
        let root = OpenClawTaskOverlayView(
            viewModel: viewModel,
            onStop: { OpenClawManager.shared.abortCurrentOpenClawTask() },
            onClose: { [weak self] in Task { @MainActor in self?.closeFromUser() } }
        )
        let size = CGSize(width: 680, height: 520)
        let hv = NSHostingView(rootView: root)
        hv.sizingOptions = []
        hv.wantsLayer = true
        hv.layer?.backgroundColor = NSColor.clear.cgColor
        hv.frame = CGRect(origin: .zero, size: size)
        hv.autoresizingMask = [.width, .height]

        let win = OpenClawTaskPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        win.contentView = hv
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.level = .floating
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces]
        win.isFloatingPanel = true
        win.becomesKeyOnlyIfNeeded = true
        win.isMovableByWindowBackground = true
        win.minSize = CGSize(width: 520, height: 360)
        if let screen = currentScreen() {
            let visible = screen.visibleFrame
            win.maxSize = CGSize(width: visible.width - 32, height: visible.height - 32)
            let x = visible.minX + (visible.width - size.width) / 2
            let y = visible.maxY - size.height - max(64, visible.height * 0.08)
            win.setFrameOrigin(CGPoint(
                x: min(max(x, visible.minX + 16), visible.maxX - size.width - 16),
                y: min(max(y, visible.minY + 16), visible.maxY - size.height - 16)
            ))
        }
        self.hostingView = hv
        self.panel = win
    }

    private func updatePanel(allowResize: Bool = true) {
        ensurePanel()
        hostingView?.rootView = OpenClawTaskOverlayView(
            viewModel: viewModel,
            onStop: { OpenClawManager.shared.abortCurrentOpenClawTask() },
            onClose: { [weak self] in Task { @MainActor in self?.closeFromUser() } }
        )
        if allowResize, let panel, !panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel?.orderFrontRegardless()
        }
    }

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

private final class OpenClawTaskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum OpenClawTaskPhase {
    case running
    case finished
    case aborted
    case failed
}

@MainActor
@Observable
private final class OpenClawTaskOverlayViewModel {
    var title = "OpenClaw"
    var status = "连接中"
    var phase: OpenClawTaskPhase = .running
    var runId: String?
    var messageSeq: Int?
    var transcript = ""
    var startedAt = Date()
    var elapsed = 0
    var copied = false
}

private struct OpenClawTaskOverlayView: View {
    @Bindable var viewModel: OpenClawTaskOverlayViewModel
    let onStop: () -> Void
    let onClose: () -> Void
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.08)
            content
        }
        .frame(minWidth: 520, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: CyberLayout.corner)
                .fill(Cyber.panelBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CyberLayout.corner)
                .stroke(Cyber.borderDim, lineWidth: 1)
        )
        .overlay(resizeGrip, alignment: .bottomTrailing)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(statusColor.opacity(0.9), lineWidth: 1)
                    .frame(width: 26, height: 26)
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            Text(viewModel.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Cyber.textBright)
            Text(viewModel.status)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
            Text("\(viewModel.elapsed)s")
                .font(.system(size: 11))
                .foregroundStyle(Cyber.textGhost)
            Spacer(minLength: 8)
            stopButton
            copyButton
            closeButton
        }
        .frame(height: 48)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .contentShape(Rectangle())
    }

    private var content: some View {
        GeometryReader { proxy in
            MarkdownScrollView(
                text: viewModel.transcript,
                maxHeight: max(160, proxy.size.height)
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(14)
    }

    private var stopButton: some View {
        Button { onStop() } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("停止")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(viewModel.phase == .running ? Cyber.danger : Cyber.textGhost)
            .frame(height: 28)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(viewModel.phase == .running ? Cyber.danger.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.phase != .running)
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(viewModel.transcript, forType: .string)
            viewModel.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in viewModel.copied = false }
            }
        } label: {
            Image(systemName: viewModel.copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(viewModel.copied ? Cyber.success : Cyber.textDim)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button { onClose() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Cyber.textDim)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
    }

    private var resizeGrip: some View {
        ResultOverlayResizeHandle(kind: .bottomRight)
            .frame(width: 40, height: 40)
    }

    private var statusColor: Color {
        switch viewModel.phase {
        case .running: return Cyber.accent
        case .finished: return Cyber.success
        case .aborted: return Cyber.warning
        case .failed: return Cyber.danger
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class ResultOverlayViewModel {
    var text: String = ""
    var isMarkdown: Bool = false
    var countdown: Int = 30
    var pinned: Bool = false
    var copied: Bool = false
}

// MARK: - Root View

struct ResultOverlayView: View {
    @Bindable var viewModel: ResultOverlayViewModel
    let onDismiss: () -> Void
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            contentArea
                .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 360, minHeight: 180)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(overlayBg)
        .overlay(borderOverlay)
        .overlay(resizeHandles)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            resultIcon
                .padding(.trailing, 8)
            Text(viewModel.isMarkdown ? L10n.overlaySearchTitle : L10n.overlayResultTitle)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Cyber.accent)
            Text(viewModel.pinned ? L10n.overlayResultPinned : "\(viewModel.countdown)s")
                .font(.system(size: 11))
                .foregroundStyle(Cyber.textGhost)
                .padding(.leading, 10)
            Spacer(minLength: 4)
            pinButton
            copyButton
            closeButton
        }
        .frame(height: 46)
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
    }

    // MARK: Content

    // header + footer 固定占用高度约 90pt
    static let headerFooterH: CGFloat = 90

    @ViewBuilder
    private var contentArea: some View {
        if viewModel.isMarkdown {
            GeometryReader { proxy in
                MarkdownScrollView(
                    text: viewModel.text,
                    maxHeight: max(80, proxy.size.height)
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            ScrollView(.vertical) {
                Text(viewModel.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Cyber.textBright)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: Icon / Buttons

    private var resultIcon: some View {
        ZStack {
            Circle()
                .stroke(Cyber.accentRing, lineWidth: 1)
                .frame(width: 24, height: 24)
            Image(systemName: viewModel.isMarkdown ? "magnifyingglass" : "text.alignleft")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Cyber.accent)
        }
        .frame(width: 24, height: 24)
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(viewModel.text, forType: .string)
            viewModel.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in viewModel.copied = false }
            }
        } label: {
            Image(systemName: viewModel.copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(viewModel.copied ? Cyber.success : Cyber.textDim)
                .frame(width: 30, height: 28)
                .background(buttonHoverBackground)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: viewModel.copied)
    }

    private var closeButton: some View {
        Button { onDismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Cyber.textDim)
                .frame(width: 30, height: 28)
                .background(buttonHoverBackground)
        }
        .buttonStyle(.plain)
    }

    private var pinButton: some View {
        Button { viewModel.pinned.toggle() } label: {
            Image(systemName: viewModel.pinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(viewModel.pinned ? Cyber.accent : Cyber.textDim)
                .frame(width: 30, height: 28)
                .background(buttonHoverBackground)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: viewModel.pinned)
    }

    private var buttonHoverBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.clear)
    }

    private var resizeHandles: some View {
        ZStack(alignment: .bottomTrailing) {
            ResultOverlayResizeHandle(kind: .right)
                .frame(width: 16)
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ResultOverlayResizeHandle(kind: .bottom)
                .frame(height: 16)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .bottom)
            ResultOverlayResizeHandle(kind: .bottomRight)
                .frame(width: 40, height: 40)
        }
    }

    // MARK: Backgrounds

    private var overlayBg: some View {
        RoundedRectangle(cornerRadius: CyberLayout.corner)
            .fill(Cyber.panelBg)
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: CyberLayout.corner)
            .stroke(Cyber.borderDim, lineWidth: 1)
    }
}
