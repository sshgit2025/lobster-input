import AppKit
import CoreGraphics
import QuartzCore

enum ScrollingScreenshotResult {
    case copied
    case cancelled
    case failed
    case noImage
}

/// 无需二次确认模式下的「长图模式」自定义覆盖层控制器。
///
/// 与二次确认模式（ScreenshotConfirmationController）完全独立，互不影响。
/// 多屏架构对齐二次确认模式：每个屏幕一个独立 Panel（macOS「显示器各自独立 Spaces」
/// 下单个窗口无法跨屏，必须每屏一个），跟踪鼠标所在屏并高亮（active），用户在某屏
/// mouseDown 即锁定到该屏 —— 保证「发起截图的屏幕 = 鼠标所在屏」。长图本就是同屏行为，
/// 故锁定到单屏后进行框选与滚动拼接。
///
/// 交互（Xnip 式）：
///   1. 每屏覆盖层，鼠标所在屏高亮；在该屏框选区域，mouseDown 锁定该屏。
///   2. 松开后进入滚动捕获：覆盖层把选区做成透明洞 + 鼠标穿透，底层内容正常滚动。
///   3. 滚动「过程中」密集采帧（任意速度都有重叠），ScreenshotStitcher 实时拼接 + 预览。
///   4. 回车 / 点「完成」→ 长图落剪贴板；Esc / 点「取消」→ 丢弃。未滚动=单帧，天然无缝。
@MainActor
final class ScrollingScreenshotController {
    static let shared = ScrollingScreenshotController()
    private init() {}

    private enum Phase { case idle, selecting, scrolling, finishing }

    private var phase: Phase = .idle
    private var completion: ((ScrollingScreenshotResult) -> Void)?

    // 选区覆盖层（每屏一个）。显式保存对应 screen 实例，按 displayID 比较，避免 NSScreen 身份不一致。
    private var panels: [(panel: ScrollOverlayPanel, view: ScrollOverlayView, screen: NSScreen)] = []
    private var activeScreen: NSScreen?     // 鼠标所在屏（高亮）
    private var isLocked = false            // 已 mouseDown，锁定到某屏
    // 锁定后保留的那一屏 Panel / View（滚动阶段使用）
    private var lockedPanel: ScrollOverlayPanel?
    private var lockedView: ScrollOverlayView?

    // 滚动阶段控制面板
    private var controlPanel: ScrollControlPanel?

    // 监听
    private var keyMonitors: [Any] = []
    private var scrollMonitors: [Any] = []
    private var mouseMoveMonitor: Any?

    // 滚动捕获状态
    private var captureScreen: NSScreen?
    private var captureRectGlobal: NSRect = .zero
    private let stitcher = ScreenshotStitcher()
    // 串行队列承载全部 stitcher 访问（add / makeImage / reset），避免与采帧竞态。
    private let captureQueue = DispatchQueue(label: "voiceinput.scroll.capture", qos: .userInitiated)
    private var captureInFlight = false   // 同一时刻仅一帧在飞，完成后若仍有滚动再补采（合并）
    private var scrollDirty = false        // 自上次采帧后又发生了滚动
    private var hintAccum: Double = 0      // 自上次采帧以来累计的滚轮量（点），作为拼接引擎的先验
    private var trailingWorkItem: DispatchWorkItem?  // 滚停后补采一帧定格
    private var lastPreviewAt: CFTimeInterval = 0    // 预览生成节流（避免每帧拷贝增长缓冲）
    private var lastCaptureStartAt: CFTimeInterval = 0           // 采集限频起点
    private let minCaptureInterval: CFTimeInterval = 0.04        // 采集最小间隔（≈25/s 上限，CPU 封顶）

    // MARK: - 入口

    func present(completion: @escaping (ScrollingScreenshotResult) -> Void) {
        dismiss(result: .cancelled, notify: false)
        self.completion = completion
        isLocked = false

        let screens = NSScreen.screens
        guard !screens.isEmpty else { completion(.failed); return }

        for screen in screens {
            let view = ScrollOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenFrameOrigin = screen.frame.origin
            view.onFirstMouseDown = { [weak self] in self?.lockToScreen(screen) }
            view.onMouseEntered = { [weak self] in self?.mouseEntered(screen) }
            view.onSelectedLocal = { [weak self] localRect in self?.handleSelected(localRect, on: screen) }
            view.onCancel = { [weak self] in self?.dismiss(result: .cancelled) }

            let panel = ScrollOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.level = .screenSaver
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panels.append((panel, view, screen))
        }

        phase = .selecting

        // 初始高亮鼠标当前所在屏
        let mouseLoc = NSEvent.mouseLocation
        activeScreen = NSScreen.screens.first { NSMouseInRect(mouseLoc, $0.frame, false) } ?? NSScreen.main
        updateHighlight()

        // 主屏（或第一块）Panel 取 key 接收键盘
        if let keyPanel = panels.first(where: { screensEqual($0.screen, NSScreen.main) })?.panel ?? panels.first?.panel {
            keyPanel.makeKey()
        }

        installEscMonitorForSelecting()
        installMouseMoveMonitor()
    }

    // MARK: - 多屏高亮 / 锁定（对齐二次确认模式）

    private func mouseEntered(_ screen: NSScreen) {
        guard !isLocked, phase == .selecting, !screensEqual(screen, activeScreen) else { return }
        activeScreen = screen
        updateHighlight()
    }

    private func updateHighlight() {
        for entry in panels {
            entry.view.setActive(screensEqual(entry.screen, activeScreen))
        }
    }

    /// 用户在某屏 mouseDown → 锁定该屏，关闭其余屏 Panel，保证发起屏 = 鼠标屏
    private func lockToScreen(_ screen: NSScreen) {
        guard !isLocked, phase == .selecting else { return }
        isLocked = true
        removeMouseMoveMonitor()
        // 关闭非锁定屏，仅保留锁定屏
        for entry in panels where !screensEqual(entry.screen, screen) { entry.panel.orderOut(nil) }
        if let entry = panels.first(where: { screensEqual($0.screen, screen) }) {
            entry.view.setActive(true)
            entry.panel.makeKey()
            lockedPanel = entry.panel
            lockedView = entry.view
        }
        panels.removeAll { !screensEqual($0.screen, screen) }
    }

    /// 按 NSScreenNumber(displayID) 比较屏幕，避免依赖 NSScreen 实例身份
    private func screensEqual(_ a: NSScreen?, _ b: NSScreen?) -> Bool {
        guard let a, let b else { return false }
        return displayID(for: a) == displayID(for: b)
    }

    private func installMouseMoveMonitor() {
        removeMouseMoveMonitor()
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isLocked, self.phase == .selecting else { return }
                let loc = NSEvent.mouseLocation
                let newActive = NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
                guard newActive != self.activeScreen else { return }
                self.activeScreen = newActive
                self.updateHighlight()
            }
        }
    }

    private func removeMouseMoveMonitor() {
        if let m = mouseMoveMonitor { NSEvent.removeMonitor(m) }
        mouseMoveMonitor = nil
    }

    // MARK: - 选区完成 → 进入滚动捕获

    private func handleSelected(_ localRect: NSRect, on screen: NSScreen) {
        guard phase == .selecting else { return }
        let global = NSRect(
            x: localRect.minX + screen.frame.minX,
            y: localRect.minY + screen.frame.minY,
            width: localRect.width,
            height: localRect.height
        )
        captureScreen = screen
        captureRectGlobal = global.intersection(screen.frame)
        enterScrolling()
    }

    private func enterScrolling() {
        guard let screen = captureScreen, let view = lockedView, let panel = lockedPanel else {
            dismiss(result: .failed); return
        }
        phase = .scrolling
        hintAccum = 0
        let stitcher = self.stitcher
        captureQueue.async { stitcher.reset() }

        // 选区在锁定屏的本地坐标（用于透明洞）
        let localRect = NSRect(
            x: captureRectGlobal.minX - screen.frame.minX,
            y: captureRectGlobal.minY - screen.frame.minY,
            width: captureRectGlobal.width,
            height: captureRectGlobal.height
        )
        view.lockAsHole(localRect)
        panel.ignoresMouseEvents = true

        DebugTrace.log("Scroll capture begin: region=\(Int(captureRectGlobal.width))x\(Int(captureRectGlobal.height)) scale=\(screen.backingScaleFactor)")
        showControlPanel(on: screen)
        installScrollMonitors()
        installKeyMonitorsForScrolling()

        // 等屏幕合成更新到「洞」状态后抓取基底帧
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.scheduleCapture()
        }
    }

    // MARK: - 滚动密集采帧

    /// 滚轮事件驱动：滚动「过程中」就密集采帧（而非等滚停再采），
    /// 保证连续帧之间始终有重叠，任意速度都能拼接。单飞 + 合并，采得越快越能容忍快滚。
    /// 同时累积滚轮事件量（含惯性阶段）作为拼接引擎的位置先验 ——
    /// 纯色/渐变等无纹理区域全靠它外推（内容级验证表明这是纯色区的生命线）。
    private func onScrollTick(deltaY: Double = 0) {
        guard phase == .scrolling else { return }
        hintAccum += deltaY
        scrollDirty = true
        scheduleCapture()
        // 同时安排一次"滚停补采"，抓取滚动停下后的最终定格帧
        trailingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scheduleCapture() }
        trailingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 若当前无在飞采帧则立即在后台串行队列采一帧并拼接；完成后若期间又滚动了则继续补采。
    /// 采用「单飞 + 最小间隔下限」双重限频，把采集频率（≈处理频率）钉在 CPU 可控范围。
    private func scheduleCapture() {
        guard phase == .scrolling, !captureInFlight,
              let screen = captureScreen, let displayID = displayID(for: screen) else { return }
        let now = CACurrentMediaTime()
        // CPU 封顶：两次采集起始至少间隔 minCaptureInterval（约 25 次/秒上限），
        // 太近则留待下一个滚动事件/滚停补采触发，避免高频采集+配准把 CPU 拖爆。
        if now - lastCaptureStartAt < minCaptureInterval {
            scrollDirty = true
            return
        }
        lastCaptureStartAt = now
        captureInFlight = true
        scrollDirty = false
        let hint = hintAccum          // 快照并清零本帧的滚轮量（主线程独占访问）
        hintAccum = 0
        let rectGlobal = captureRectGlobal
        let frame = screen.frame
        let stitcher = self.stitcher
        // 预览节流：增长缓冲拷贝有成本，约每 200ms 生成一次；超长图直接跳过预览图，只更新高度提示
        let wantPreview = now - lastPreviewAt > 0.2
        if wantPreview { lastPreviewAt = now }
        captureQueue.async { [weak self] in
            var result: ScreenshotStitcher.AddResult = .invalid
            var preview: CGImage?
            var height = 0
            if let full = CGDisplayCreateImage(displayID) {
                let cropPx = Self.pixelCropRect(rectGlobal, in: frame, image: full)
                if cropPx.width >= 1, cropPx.height >= 1, let cropped = full.cropping(to: cropPx) {
                    result = stitcher.add(cropped, hintUnits: hint)
                    height = stitcher.pixelHeight
                    let isGrowth: Bool = { if case .first = result { return true }; if case .appended = result { return true }; return false }()
                    // 后台直接抽样生成小缩略图，主线程只贴小图，不做大图缩放 → 不卡顿。
                    if isGrowth, wantPreview || stitcher.frameCount == 1 {
                        preview = stitcher.makeThumbnail(maxW: 220, maxH: 800)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.captureInFlight = false
                self.handleCaptureResult(result, preview: preview, height: height)
                if self.scrollDirty { self.scheduleCapture() }
            }
        }
    }

    private func handleCaptureResult(_ result: ScreenshotStitcher.AddResult, preview: CGImage?, height: Int) {
        guard phase == .scrolling else { return }
        switch result {
        case .first, .appended:
            if let preview { controlPanel?.updatePreview(preview, height: height) }
            // 附带已捕获高度，超长图跳过预览图时也能直观看到仍在增长
            controlPanel?.setHint(L10n.screenshotScrollHint + "  ·  \(height)px")
        case .noMatch:
            controlPanel?.setHint(L10n.screenshotScrollTooFast)
        case .full:
            controlPanel?.setHint(L10n.screenshotScrollLimit)
        case .duplicate, .invalid:
            break
        }
    }

    // MARK: - 完成 / 取消

    private func finish() {
        guard phase == .scrolling else { return }
        phase = .finishing
        trailingWorkItem?.cancel()
        removeScrollMonitors()
        removeKeyMonitors()

        // 在串行队列上生成最终图，确保排在所有在飞采帧之后，避免与 add 竞态
        let stitcher = self.stitcher
        captureQueue.async { [weak self] in
            DebugTrace.log("Scroll capture finish: height=\(stitcher.pixelHeight) appendedFrames=\(stitcher.frameCount)")
            let cg = stitcher.makeImage()
            DispatchQueue.main.async {
                guard let self else { return }
                guard let cg else { self.dismiss(result: .noImage); return }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                NSPasteboard.general.clearContents()
                let ok = NSPasteboard.general.writeObjects([image])
                self.dismiss(result: ok ? .copied : .failed)
            }
        }
    }

    // MARK: - 控制面板

    private func showControlPanel(on screen: NSScreen) {
        let panel = ScrollControlPanel.make()
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.dismiss(result: .cancelled) }
        panel.setHint(L10n.screenshotScrollHint)

        let size = panel.frame.size
        let sel = captureRectGlobal
        var x = sel.midX - size.width / 2
        var y = sel.minY - 12 - size.height          // 选区下方
        if y < screen.frame.minY + 8 {
            y = sel.maxY + 12                          // 放不下则放上方
        }
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        y = min(max(y, screen.frame.minY + 8), screen.frame.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        panel.makeKey()
        controlPanel = panel
    }

    // MARK: - 监听

    private func installEscMonitorForSelecting() {
        removeKeyMonitors()
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            Task { @MainActor in self?.dismiss(result: .cancelled) }
            return nil
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.dismiss(result: .cancelled) }
        }
        keyMonitors = [local, global].compactMap { $0 }
    }

    private func installKeyMonitorsForScrolling() {
        removeKeyMonitors()
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53:                       // Esc → 取消
                Task { @MainActor in self?.dismiss(result: .cancelled) }
                return nil
            case 36, 76:                   // Return / 小键盘 Enter → 完成
                Task { @MainActor in self?.finish() }
                return nil
            default:
                return event
            }
        }
        let globalEsc = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.dismiss(result: .cancelled) }
        }
        keyMonitors = [local, globalEsc].compactMap { $0 }
    }

    private func removeKeyMonitors() {
        for m in keyMonitors { NSEvent.removeMonitor(m) }
        keyMonitors.removeAll()
    }

    private func installScrollMonitors() {
        removeScrollMonitors()
        let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let dy = event.scrollingDeltaY
            Task { @MainActor in self?.onScrollTick(deltaY: dy) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let dy = event.scrollingDeltaY
            Task { @MainActor in self?.onScrollTick(deltaY: dy) }
            return event
        }
        scrollMonitors = [global, local].compactMap { $0 }
    }

    private func removeScrollMonitors() {
        for m in scrollMonitors { NSEvent.removeMonitor(m) }
        scrollMonitors.removeAll()
    }

    // MARK: - 收尾

    private func dismiss(result: ScrollingScreenshotResult, notify: Bool = true) {
        trailingWorkItem?.cancel()
        trailingWorkItem = nil
        removeKeyMonitors()
        removeScrollMonitors()
        removeMouseMoveMonitor()
        controlPanel?.orderOut(nil)
        controlPanel = nil
        for entry in panels { entry.panel.orderOut(nil) }
        panels.removeAll()
        lockedPanel?.orderOut(nil)
        lockedPanel = nil
        lockedView = nil
        // reset 也排到串行队列，确保排在任何在飞采帧之后，避免竞态
        let stitcher = self.stitcher
        captureQueue.async { stitcher.reset() }
        captureScreen = nil
        captureInFlight = false
        scrollDirty = false
        hintAccum = 0
        isLocked = false
        activeScreen = nil
        phase = .idle
        if notify {
            let cb = completion
            completion = nil
            cb?(result)
        } else {
            completion = nil
        }
    }

    // MARK: - 坐标 / 屏幕工具

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// 全局点矩形 → CGImage 像素矩形（与 ScreenshotManager.imageForSelection 同款 Retina 映射）。
    private static func pixelCropRect(_ rect: NSRect, in frame: NSRect, image: CGImage) -> CGRect {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let relX = (rect.minX - frame.minX) / frame.width * imgW
        let relY = (frame.maxY - rect.maxY) / frame.height * imgH
        let relW = rect.width / frame.width * imgW
        let relH = rect.height / frame.height * imgH
        // 内缩 edge 像素：杜绝选区青色边框/羽边被截进每帧，避免接缝处出现青色横线
        let scale = imgW / max(1, frame.width)
        let edge = max(2.0, scale.rounded())
        let cropRect = CGRect(x: relX, y: relY, width: relW, height: relH).integral.insetBy(dx: edge, dy: edge)
        let bounds = CGRect(x: 0, y: 0, width: imgW, height: imgH)
        return cropRect.intersection(bounds)
    }
}

// MARK: - Overlay Panel

private final class ScrollOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay View（每屏一个：选区 + 透明洞 + 活跃高亮，CALayer 遮罩避免全量重绘）

private final class ScrollOverlayView: NSView {
    var onSelectedLocal: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    var onFirstMouseDown: (() -> Void)?
    var onMouseEntered: (() -> Void)?
    /// 本屏 frame 原点（用于本地坐标 → 全局坐标）
    var screenFrameOrigin: NSPoint = .zero

    private var selection = NSRect.zero
    private var anchor = NSPoint.zero
    private var dragging = false
    private var locked = false
    private let minSize: CGFloat = 12

    private let dimLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let sizeLabel = CATextLayer()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor.clear.cgColor

        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        maskLayer.fillRule = .evenOdd
        maskLayer.fillColor = NSColor.black.cgColor
        dimLayer.mask = maskLayer
        root.addSublayer(dimLayer)

        borderLayer.frame = bounds
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.systemCyan.cgColor
        borderLayer.lineWidth = 2
        borderLayer.isHidden = true
        root.addSublayer(borderLayer)

        sizeLabel.fontSize = 12
        sizeLabel.foregroundColor = NSColor.white.cgColor
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        sizeLabel.alignmentMode = .center
        sizeLabel.cornerRadius = 3
        sizeLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        sizeLabel.isHidden = true
        root.addSublayer(sizeLabel)

        applyMask(hole: nil)
        installTrackingArea()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 活跃高亮（鼠标所在屏浅遮罩，其余深遮罩）

    func setActive(_ active: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.backgroundColor = active
            ? NSColor.black.withAlphaComponent(0.30).cgColor
            : NSColor.black.withAlphaComponent(0.55).cgColor
        CATransaction.commit()
    }

    /// 进入滚动阶段：锁定选区为透明洞 + 边框，不再响应鼠标。
    func lockAsHole(_ rect: NSRect) {
        locked = true
        selection = rect
        applyMask(hole: rect)
        updateBorder(rect)
        sizeLabel.isHidden = true
    }

    // MARK: Tracking Area

    private func installTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard !locked else { return }
        onFirstMouseDown?()   // 通知 Controller 锁定到本屏
        anchor = convert(event.locationInWindow, from: nil)
        selection = NSRect(origin: anchor, size: .zero)
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !locked, dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = normalizedRect(anchor, p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyMask(hole: selection)
        updateBorder(selection)
        updateSizeLabel(selection)
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        guard !locked, dragging else { return }
        dragging = false
        if selection.width >= minSize, selection.height >= minSize {
            onSelectedLocal?(selection)
        } else {
            onCancel?()
        }
    }

    // MARK: 绘制辅助

    private func normalizedRect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return r.intersection(bounds)
    }

    private func applyMask(hole: NSRect?) {
        maskLayer.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole, hole.width > 0, hole.height > 0 {
            path.addRect(hole)
        }
        maskLayer.path = path
    }

    private func updateBorder(_ rect: NSRect) {
        borderLayer.isHidden = false
        let path = CGMutablePath()
        // 边框画在选区外 3px（配合截取区内缩），确保青色边框绝不进入捕获，消除接缝青线
        path.addRect(rect.insetBy(dx: -3, dy: -3))
        borderLayer.path = path
    }

    private func updateSizeLabel(_ rect: NSRect) {
        sizeLabel.isHidden = false
        sizeLabel.string = "\(Int(rect.width)) × \(Int(rect.height))"
        let w: CGFloat = 96, h: CGFloat = 18
        var y = rect.maxY + 4
        if y + h > bounds.maxY { y = rect.maxY - h - 4 }
        sizeLabel.frame = NSRect(x: rect.minX, y: y, width: w, height: h)
    }
}

// MARK: - Control Panel（滚动阶段：预览 + 完成/取消）

private final class ScrollControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let previewView = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "")

    static func make() -> ScrollControlPanel {
        let w: CGFloat = 200, h: CGFloat = 220
        let panel = ScrollControlPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.buildContent(width: w, height: h)
        return panel
    }

    private func buildContent(width w: CGFloat, height h: CGFloat) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        container.layer?.cornerRadius = 10

        hintLabel.frame = NSRect(x: 10, y: h - 30, width: w - 20, height: 22)
        hintLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(hintLabel)

        previewView.frame = NSRect(x: 10, y: 46, width: w - 20, height: h - 84)
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.imageAlignment = .alignTop
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
        previewView.layer?.cornerRadius = 4
        container.addSubview(previewView)

        let cancel = NSButton(title: L10n.screenshotScrollCancel, target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: 10, y: 10, width: (w - 30) / 2, height: 28)
        container.addSubview(cancel)

        let finish = NSButton(title: L10n.screenshotScrollDone, target: self, action: #selector(finishTapped))
        finish.frame = NSRect(x: w / 2 + 5, y: 10, width: (w - 30) / 2, height: 28)
        finish.keyEquivalent = "\r"
        container.addSubview(finish)

        contentView = container
    }

    func setHint(_ text: String) { hintLabel.stringValue = text }

    func updatePreview(_ image: CGImage?, height: Int) {
        guard let image else { return }
        previewView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
}
