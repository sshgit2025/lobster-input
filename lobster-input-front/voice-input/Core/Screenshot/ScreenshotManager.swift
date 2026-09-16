import Foundation
import AppKit

enum ScreenshotConfirmationStore {
    private static let key = "screenshot_confirmation_enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 无需二次确认模式下是否启用「滚动截长图」。默认关闭：关闭时无需确认模式保持系统
/// screencapture 行为完全不变（零风险回退）；开启后无需确认模式改走自定义滚动覆盖层。
enum ScreenshotScrollingStore {
    private static let key = "screenshot_scrolling_enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@MainActor
final class ScreenshotManager {
    static let shared = ScreenshotManager()

    private var isCapturing = false

    private init() {}

    func captureToClipboard() {
        guard !isCapturing else { return }
        DebugTrace.log("Screenshot: capture requested")
        PermissionManager.shared.refreshStatuses()
        guard PermissionManager.shared.requestScreenCaptureIfNeeded() else {
            DebugTrace.log("Screenshot: screen capture permission not granted; opening settings")
            TransientTipWindowController.shared.show(message: L10n.screenshotPermissionRequired, style: .warning)
            PermissionManager.shared.openScreenCaptureSettings()
            return
        }
        isCapturing = true

        if ScreenshotConfirmationStore.isEnabled {
            launchConfirmedCapture()
            return
        }

        if ScreenshotScrollingStore.isEnabled {
            launchScrollingCapture()
            return
        }

        launchSystemCapture()
    }

    private func launchScrollingCapture() {
        DebugTrace.log("Screenshot: launching scrolling capture overlay")
        ScrollingScreenshotController.shared.present { [weak self] result in
            guard let self else { return }
            self.isCapturing = false
            self.showScrollingTip(result)
        }
    }

    private func showScrollingTip(_ result: ScrollingScreenshotResult) {
        switch result {
        case .copied:
            DebugTrace.log("Screenshot: scrolling capture copied to clipboard")
            TransientTipWindowController.shared.show(message: L10n.screenshotCopied, style: .success)
        case .cancelled:
            DebugTrace.log("Screenshot: scrolling capture cancelled")
            TransientTipWindowController.shared.show(message: L10n.screenshotCancelled, style: .warning)
        case .noImage:
            DebugTrace.log("Screenshot: scrolling capture produced no image")
            TransientTipWindowController.shared.show(message: L10n.screenshotNoImage, style: .warning)
        case .failed:
            DebugTrace.log("Screenshot: scrolling capture failed")
            TransientTipWindowController.shared.show(message: L10n.screenshotFailed, style: .error)
        }
    }

    private func launchSystemCapture() {
        DebugTrace.log("Screenshot: launching screencapture -i -c")
        let pasteboardChangeCount = NSPasteboard.general.changeCount

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-c"]
        process.terminationHandler = { [weak self] _ in
            let terminationStatus = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.isCapturing = false
                await self?.showCompletionTip(for: terminationStatus, initialPasteboardChangeCount: pasteboardChangeCount)
            }
        }

        do {
            try process.run()
        } catch {
            isCapturing = false
            DebugTrace.log("Screenshot: failed to launch screencapture: \(error.localizedDescription)")
            TransientTipWindowController.shared.show(message: L10n.screenshotFailed, style: .error)
        }
    }

    private func showCompletionTip(for terminationStatus: Int32, initialPasteboardChangeCount: Int) async {
        let pasteboardResult = await waitForScreenshotPasteboardUpdate(since: initialPasteboardChangeCount)
        if pasteboardResult.hasNewImage {
            DebugTrace.log(
                "Screenshot: completed and copied to clipboard status=\(terminationStatus) " +
                "changeCount=\(pasteboardResult.changeCount) attempts=\(pasteboardResult.attempts)"
            )
            TransientTipWindowController.shared.show(message: L10n.screenshotCopied, style: .success)
        } else if terminationStatus == 0 {
            DebugTrace.log(
                "Screenshot: completed without pasteboard image " +
                "changeCount=\(pasteboardResult.changeCount) attempts=\(pasteboardResult.attempts)"
            )
            TransientTipWindowController.shared.show(message: L10n.screenshotNoImage, style: .warning)
        } else {
            DebugTrace.log(
                "Screenshot: cancelled or failed status=\(terminationStatus) " +
                "changeCount=\(pasteboardResult.changeCount) attempts=\(pasteboardResult.attempts)"
            )
            TransientTipWindowController.shared.show(message: L10n.screenshotCancelled, style: .warning)
        }
    }

    private func waitForScreenshotPasteboardUpdate(since initialChangeCount: Int) async -> PasteboardScreenshotResult {
        let maxAttempts = 8
        let retryDelay: UInt64 = 80_000_000

        for attempt in 1...maxAttempts {
            let pasteboard = NSPasteboard.general
            let changeCount = pasteboard.changeCount
            if changeCount != initialChangeCount, pasteboardContainsImage(pasteboard) {
                return PasteboardScreenshotResult(hasNewImage: true, changeCount: changeCount, attempts: attempt)
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: retryDelay)
            }
        }

        return PasteboardScreenshotResult(
            hasNewImage: false,
            changeCount: NSPasteboard.general.changeCount,
            attempts: maxAttempts
        )
    }

    private func pasteboardContainsImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.tiff"),
            NSPasteboard.PasteboardType("public.png")
        ]
        return pasteboard.pasteboardItems?.contains { item in
            imageTypes.contains { item.availableType(from: [$0]) != nil }
        } ?? false
    }

    private func launchConfirmedCapture() {
        DebugTrace.log("Screenshot: launching confirmation overlay")
        ScreenshotConfirmationController.shared.present { [weak self] result in
            guard let self else { return }
            self.isCapturing = false
            self.showConfirmationTip(result)
        }
    }

    private func showConfirmationTip(_ result: ScreenshotConfirmationResult) {
        switch result {
        case .copied:
            DebugTrace.log("Screenshot: confirmed and copied to clipboard")
            TransientTipWindowController.shared.show(message: L10n.screenshotCopied, style: .success)
        case .cancelled:
            DebugTrace.log("Screenshot: confirmation cancelled")
            TransientTipWindowController.shared.show(message: L10n.screenshotCancelled, style: .warning)
        case .failed:
            DebugTrace.log("Screenshot: confirmation capture failed")
            TransientTipWindowController.shared.show(message: L10n.screenshotFailed, style: .error)
        }
    }
}

// MARK: - Result

private struct PasteboardScreenshotResult {
    let hasNewImage: Bool
    let changeCount: Int
    let attempts: Int
}

private enum ScreenshotConfirmationResult {
    case copied
    case cancelled
    case failed
}

// MARK: - Snapshot

private struct ScreenshotScreenSnapshot {
    let screen: NSScreen
    let frame: NSRect       // NSScreen.frame，AppKit 坐标系
    let scale: CGFloat
    let displayID: CGDirectDisplayID
    let image: CGImage
}

// MARK: - Controller
// 每个屏幕独立一个 Panel。
// 交互逻辑：
//   - 未点击前：全局 mouseMoved monitor 跟踪鼠标，鼠标所在屏高亮（活跃），其余屏深色暗化
//   - 用户 mouseDown 后：锁定到该屏，关闭其余屏 Panel，只在锁定屏截图

@MainActor
private final class ScreenshotConfirmationController {
    static let shared = ScreenshotConfirmationController()

    private var panels: [(panel: ScreenshotSelectionPanel, view: ScreenshotSelectionView)] = []
    private var completion: ((ScreenshotConfirmationResult) -> Void)?
    private var escapeMonitors: [Any] = []
    private var mouseMoveMonitor: Any?
    private var snapshots: [ScreenshotScreenSnapshot] = []
    /// 当前高亮的屏幕（鼠标所在屏）
    private var activeScreen: NSScreen?
    /// 用户已 mouseDown，进入锁定屏截图阶段
    private var isLocked = false

    private init() {}

    func present(completion: @escaping (ScreenshotConfirmationResult) -> Void) {
        dismiss(result: .cancelled, notify: false)
        self.completion = completion
        isLocked = false

        let screens = NSScreen.screens
        guard !screens.isEmpty else { completion(.failed); return }

        for screen in screens {
            let view = ScreenshotSelectionView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                screen: screen
            )
            view.onCancel = { [weak self] in self?.dismiss(result: .cancelled) }
            view.onConfirm = { [weak self] rect, anns in self?.confirm(rect, annotations: anns, in: screen.frame) }
            view.onFirstMouseDown = { [weak self] in self?.lockToScreen(screen) }
            view.onMouseEntered = { [weak self] in self?.mouseEnteredScreen(screen) }

            let panel = ScreenshotSelectionPanel(
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
            panel.orderFrontRegardless()
            panels.append((panel, view))
        }

        // 初始高亮鼠标当前所在屏
        let mouseLoc = NSEvent.mouseLocation
        activeScreen = NSScreen.screens.first { NSMouseInRect(mouseLoc, $0.frame, false) }
        updateHighlight()

        // 主屏 panel 获取 key 焦点接收键盘事件
        if let mainPanel = panels.first(where: { $0.panel.screen == NSScreen.main })?.panel
            ?? panels.first?.panel {
            mainPanel.makeKey()
        }

        installEscapeMonitor()
        installMouseMoveMonitor()

        // 后台并发抓取各屏截图
        Task {
            let captured = await captureScreenSnapshotsAsync()
            guard !self.panels.isEmpty else { return }
            guard !captured.isEmpty else { self.dismiss(result: .failed); return }
            self.snapshots = captured
            for snap in captured {
                if let entry = self.panels.first(where: { $0.panel.screen == snap.screen }) {
                    entry.view.applySnapshot(snap)
                }
            }
            // 截图到位后刷新一次高亮状态，确保遮罩深浅正确
            self.updateHighlight()
        }
    }

    /// 用户在某屏 mouseDown，锁定到该屏，关闭其余屏
    private func lockToScreen(_ screen: NSScreen) {
        guard !isLocked else { return }
        isLocked = true
        removeMouseMoveMonitor()
        // 关闭非锁定屏的 panel，保留锁定屏
        let toClose = panels.filter { $0.panel.screen != screen }
        for entry in toClose { entry.panel.orderOut(nil) }
        panels.removeAll { $0.panel.screen != screen }
        // 锁定屏恢复正常高亮状态并获取焦点
        if let entry = panels.first {
            entry.view.setActive(true)
            entry.panel.makeKey()
        }
    }

    /// 更新所有屏幕的高亮状态（鼠标所在屏高亮，其余暗化）
    private func updateHighlight() {
        for entry in panels {
            let isActive = entry.panel.screen == activeScreen
            entry.view.setActive(isActive)
        }
    }

    /// 某屏的 view 报告鼠标进入（由 NSTrackingArea mouseEntered 触发，实时无延迟）
    func mouseEnteredScreen(_ screen: NSScreen) {
        guard !isLocked else { return }
        guard screen != activeScreen else { return }
        activeScreen = screen
        updateHighlight()
    }

    private func installMouseMoveMonitor() {
        // 不再依赖 globalMonitor mouseMoved（在自身 Panel 上不触发）
        // 改用各 Panel 的 NSTrackingArea mouseEntered 驱动切换（见 ScreenshotSelectionView.mouseEntered）
        // 保留 globalMonitor 作为兜底（鼠标在非 Panel 区域时）
        removeMouseMoveMonitor()
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self, !self.isLocked else { return }
            Task { @MainActor in
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

    private func confirm(_ rect: NSRect, annotations: [Annotation], in screenFrame: NSRect) {
        let globalRect = rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        // 标注坐标是 View 局部坐标，需平移到全局坐标
        let globalAnnotations = annotations.map { $0.translated(dx: screenFrame.minX, dy: screenFrame.minY) }
        removeEscapeMonitor()
        removeMouseMoveMonitor()
        closePanels()
        let result: ScreenshotConfirmationResult = copySelectionToClipboard(globalRect, annotations: globalAnnotations) ? .copied : .failed
        dismiss(result: result)
    }

    private func dismiss(result: ScreenshotConfirmationResult, notify: Bool = true) {
        removeEscapeMonitor()
        removeMouseMoveMonitor()
        closePanels()
        snapshots.removeAll()
        isLocked = false
        if notify {
            let callback = completion
            completion = nil
            callback?(result)
        } else {
            completion = nil
        }
    }

    private func closePanels() {
        for entry in panels { entry.panel.orderOut(nil) }
        panels.removeAll()
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.dismiss(result: .cancelled) }
            return nil
        }
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.dismiss(result: .cancelled) }
        }
        escapeMonitors = [localMonitor, globalMonitor].compactMap { $0 }
    }

    private func removeEscapeMonitor() {
        for monitor in escapeMonitors { NSEvent.removeMonitor(monitor) }
        escapeMonitors.removeAll()
    }

    // MARK: 截图抓取 — 并发，每屏独立

    private func captureScreenSnapshotsAsync() async -> [ScreenshotScreenSnapshot] {
        let screens = NSScreen.screens
        // 并发抓取所有屏幕
        return await withTaskGroup(of: ScreenshotScreenSnapshot?.self) { group in
            for screen in screens {
                group.addTask {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                    let displayID = CGDirectDisplayID(number.uint32Value)
                    guard let image = CGDisplayCreateImage(displayID) else { return nil }
                    return ScreenshotScreenSnapshot(
                        screen: screen,
                        frame: screen.frame,
                        scale: screen.backingScaleFactor,
                        displayID: displayID,
                        image: image
                    )
                }
            }
            var results: [ScreenshotScreenSnapshot] = []
            for await snap in group {
                if let s = snap { results.append(s) }
            }
            return results
        }
    }

    // MARK: 截图裁剪复制

    private func copySelectionToClipboard(_ rect: NSRect, annotations: [Annotation] = []) -> Bool {
        guard let image = imageForSelection(rect, annotations: annotations) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
    }

    private func imageForSelection(_ rect: NSRect, annotations: [Annotation] = []) -> NSImage? {
        let parts = snapshots.compactMap { snapshot -> (drawRect: NSRect, image: CGImage, scale: CGFloat)? in
            guard snapshot.frame.intersects(rect) else { return nil }
            let partRect = snapshot.frame.intersection(rect)

            let imgW = CGFloat(snapshot.image.width)
            let imgH = CGFloat(snapshot.image.height)
            let ptW  = snapshot.frame.width
            let ptH  = snapshot.frame.height

            let relX = (partRect.minX - snapshot.frame.minX) / ptW * imgW
            let relY = (snapshot.frame.maxY - partRect.maxY) / ptH * imgH
            let relW = partRect.width  / ptW * imgW
            let relH = partRect.height / ptH * imgH

            let cropRect = CGRect(x: relX, y: relY, width: relW, height: relH).integral
            let imageBounds = CGRect(x: 0, y: 0, width: imgW, height: imgH)
            let bounded = cropRect.intersection(imageBounds)
            guard bounded.width > 0, bounded.height > 0,
                  let cropped = snapshot.image.cropping(to: bounded) else { return nil }
            return (partRect, cropped, snapshot.scale)
        }

        guard !parts.isEmpty else { return nil }

        // 拼合截图底图
        let baseImage: NSImage
        if parts.count == 1, let part = parts.first, part.drawRect.equalTo(rect) {
            baseImage = NSImage(cgImage: part.image, size: rect.size)
        } else {
            baseImage = NSImage(size: rect.size)
            baseImage.lockFocus()
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: rect.size).fill()
            for part in parts {
                let drawRect = NSRect(
                    x: part.drawRect.minX - rect.minX,
                    y: part.drawRect.minY - rect.minY,
                    width: part.drawRect.width,
                    height: part.drawRect.height
                )
                NSImage(cgImage: part.image, size: part.drawRect.size).draw(in: drawRect)
            }
            baseImage.unlockFocus()
        }

        guard !annotations.isEmpty else { return baseImage }

        // 将标注合成到底图上（对齐 Windows 端的 ComposeAnnotations 逻辑）
        return composeAnnotations(onto: baseImage, rect: rect, annotations: annotations)
    }

    /// 将标注重绘到截图上，坐标从全局 pt 坐标映射到图像局部 pt 坐标
    private func composeAnnotations(onto baseImage: NSImage, rect: NSRect, annotations: [Annotation]) -> NSImage {
        let size = baseImage.size
        let result = NSImage(size: size)
        result.lockFocus()

        // 绘制底图
        baseImage.draw(in: NSRect(origin: .zero, size: size))

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            result.unlockFocus()
            return baseImage
        }

        // 裁剪区域：防止标注溢出图像边界
        ctx.clip(to: CGRect(origin: .zero, size: size))

        for ann in annotations {
            // 全局坐标 → 图像局部坐标（左下为原点，与 NSView 一致）
            let offsetX = -rect.minX
            let offsetY = -rect.minY

            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(ann.lineWidth)
            ctx.setStrokeColor(ann.color.cgColor)
            ctx.setFillColor(ann.color.withAlphaComponent(0.25).cgColor)

            switch ann.kind {
            case .path(let bezier):
                // 平移路径到局部坐标
                var transform = CGAffineTransform(translationX: offsetX, y: offsetY)
                if let shifted = bezier.cgPath.copy(using: &transform) {
                    ctx.addPath(shifted)
                    ctx.strokePath()
                }
            case .rect(let r):
                let localR = r.offsetBy(dx: offsetX, dy: offsetY)
                ctx.addRect(localR)
                ctx.drawPath(using: .fillStroke)
            case .ellipse(let r):
                let localR = r.offsetBy(dx: offsetX, dy: offsetY)
                ctx.addEllipse(in: localR)
                ctx.drawPath(using: .fillStroke)
            }
            ctx.restoreGState()
        }

        result.unlockFocus()
        return result
    }
}

// MARK: - Panel

private final class ScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 标注工具

private enum AnnotationTool: Int {
    case none = 0
    case pen
    case rect
    case ellipse
}

private struct Annotation {
    enum Kind {
        case path(NSBezierPath)
        case rect(NSRect)
        case ellipse(NSRect)
    }
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat

    /// 返回标注的包围矩形（用于命中检测）
    var bounds: NSRect {
        switch kind {
        case .path(let p): return p.bounds
        case .rect(let r): return r
        case .ellipse(let r): return r
        }
    }

    /// 将标注平移（用于 View 局部坐标 → 全局坐标转换）
    func translated(dx: CGFloat, dy: CGFloat) -> Annotation {
        switch kind {
        case .path(let p):
            let t = NSAffineTransform()
            t.translateX(by: dx, yBy: dy)
            return Annotation(kind: .path(t.transform(p)), color: color, lineWidth: lineWidth)
        case .rect(let r):
            return Annotation(kind: .rect(r.offsetBy(dx: dx, dy: dy)), color: color, lineWidth: lineWidth)
        case .ellipse(let r):
            return Annotation(kind: .ellipse(r.offsetBy(dx: dx, dy: dy)), color: color, lineWidth: lineWidth)
        }
    }

    /// 命中检测
    func hitTest(_ point: NSPoint, tolerance: CGFloat = 8) -> Bool {
        switch kind {
        case .path(let p):
            let expanded = NSBezierPath()
            expanded.append(p)
            expanded.lineWidth = lineWidth + tolerance * 2
            return expanded.contains(point)
        case .rect(let r):
            // 点击边框区域
            let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(point) && !inner.contains(point)
        case .ellipse(let r):
            let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            let pathOuter = NSBezierPath(ovalIn: outer)
            let pathInner = NSBezierPath(ovalIn: inner)
            return pathOuter.contains(point) && !pathInner.contains(point)
        }
    }
}

// MARK: - Selection View
// 架构重点：
// - snapshotLayer (CALayer)  显示截图背景
// - maskLayer    (CALayer)   遮罩，用 addSublayer 叠加
// - annotationLayers         每条标注一个 CAShapeLayer，增量添加，无需重绘历史
// - overlayView (NSView)     轻量子视图，只绘制选区边框+手柄，不绘制截图和标注

private final class ScreenshotSelectionView: NSView {
    var onConfirm: ((NSRect, [Annotation]) -> Void)?
    var onCancel: (() -> Void)?
    /// 用户在本屏发起第一次 mouseDown 时回调（通知 Controller 锁定到本屏）
    var onFirstMouseDown: (() -> Void)?
    /// 鼠标进入本屏 Panel 时回调（用于实时多屏高亮切换）
    var onMouseEntered: (() -> Void)?

    private var hasStartedSelection = false

    private enum DragMode {
        case none, new, move, topLeft, topRight, bottomLeft, bottomRight
    }

    private var selection = NSRect.zero
    private var dragMode = DragMode.none
    private var anchor = NSPoint.zero
    private var dragStartSelection = NSRect.zero
    private let minSize: CGFloat = 18
    private let targetScreen: NSScreen

    // 标注状态
    private var currentTool: AnnotationTool = .none
    private var annotations: [Annotation] = []          // 所有已完成标注数据
    private var annotationLayers: [CAShapeLayer] = []   // 对应的 CAShapeLayer（索引一一对应）
    private var currentAnnLayer: CAShapeLayer?           // 正在绘制的 layer
    private var penPath: NSBezierPath?
    private var shapeStart: NSPoint = .zero
    private var selectedColor: NSColor = .systemRed
    private let penLineWidth: CGFloat = 3.0

    // 选中/编辑状态
    private var selectedAnnotationIndex: Int? = nil     // 当前选中的标注索引
    private var selectDragStart: NSPoint = .zero
    private var selectDragStartAnnotation: Annotation? = nil
    private var selectHandleIndex: Int? = nil           // 拖动的调整手柄索引（0-7 对应 8 个方向）
    private var selectionHighlightLayer: CALayer?        // 选中高亮容器（外框 + 手柄），整体移除避免残影

    // Layers
    private let snapshotLayer = CALayer()
    private let maskLayer = CALayer()       // 半透明遮罩
    private let highlightCutLayer = CALayer() // 选区高亮镂空（用独立 layer 实现）
    private let annotationContainer = CALayer()

    // 鼠标跟踪
    private var trackingArea: NSTrackingArea?

    // 按钮
    private lazy var confirmButton = makeActionButton(symbol: "checkmark", color: .systemGreen)
    private lazy var cancelButton  = makeActionButton(symbol: "xmark",     color: .systemRed)
    private lazy var toolbarView: NSView = makeToolbar()

    init(frame frameRect: NSRect, screen: NSScreen) {
        self.targetScreen = screen
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayers()
        addSubview(confirmButton)
        addSubview(cancelButton)
        addSubview(toolbarView)
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        updateButtonFrames()
        toolbarView.isHidden = true
        confirmButton.isHidden = true
        cancelButton.isHidden = true
        installTrackingArea()
    }

    required init?(coder: NSCoder) { nil }

    private func setupLayers() {
        guard let root = layer else { return }
        // 透明底，截图贴入前不显示纯黑
        root.backgroundColor = NSColor.clear.cgColor

        snapshotLayer.frame = bounds
        snapshotLayer.contentsGravity = .resize
        snapshotLayer.contentsScale = targetScreen.backingScaleFactor
        root.addSublayer(snapshotLayer)

        // 半透明黑色遮罩（截图贴入后才显示，alpha 0.35 确保截图背景清晰可见）
        maskLayer.frame = bounds
        maskLayer.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        maskLayer.isHidden = true   // 截图到位前保持隐藏，避免纯黑遮住屏幕
        root.addSublayer(maskLayer)

        // 标注 container（在遮罩上方）
        annotationContainer.frame = bounds
        root.addSublayer(annotationContainer)
    }

    /// 截图抓取完成后异步贴入，仅更新 snapshotLayer.contents，无需全量重绘
    func applySnapshot(_ snapshot: ScreenshotScreenSnapshot) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotLayer.contents = snapshot.image
        // 截图到位后显示遮罩（保持当前活跃状态的 alpha，由 Controller 通过 setActive 控制）
        if !maskLayer.isHidden { /* 已显示，不重置 */ } else {
            maskLayer.isHidden = false
        }
        CATransaction.commit()
    }

    // MARK: Tracking Area

    private func installTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    /// 鼠标进入本 Panel 区域时立即触发，通知 Controller 切换高亮（零延迟）
    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    /// 允许非激活状态下的第一次点击直接触发 mouseDown，无需额外的激活点击。
    /// 企业微信 JTCaptureView 同样实现此方法并返回 true，是解决切屏首次点击
    /// 被系统消耗为"窗口激活"而非传递给 mouseDown 的关键。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func mouseMoved(with event: NSEvent) {
        if !isValidSelection {
            updateMaskForNoSelection()
        } else {
            // 有选区时智能更新光标
            let point = event.locationInWindow
            NSCursor.current.set()
            cursorForPoint(point).set()
        }
    }

    /// 光标智能切换：综合标注手柄/标注体/工具状态/选区边框（对齐 Windows 端）
    private func cursorForPoint(_ point: NSPoint) -> NSCursor {
        // 已选中标注：优先检测手柄
        if let idx = selectedAnnotationIndex {
            let hi = hitTestAnnotationHandle(point, annotationIndex: idx)
            if hi >= 0 { return cursorForAnnotationHandle(hi) }
        }
        // 命中标注体：移动光标
        if hitTestAnnotations(point) != nil { return .openHand }
        // 有绘制工具
        if currentTool != .none { return .crosshair }
        // 选区拖拽模式
        let m = mode(at: point)
        switch m {
        case .move:        return .openHand
        case .topLeft, .bottomRight: return .resizeLeftRight
        case .topRight, .bottomLeft: return .resizeLeftRight
        default: break
        }
        return .arrow
    }

    private func cursorForAnnotationHandle(_ idx: Int) -> NSCursor {
        switch idx {
        case 0, 7: return .resizeLeftRight   // TL, BR
        case 2, 5: return .resizeLeftRight   // TR, BL
        case 1, 6: return .resizeUpDown      // TC, BC
        case 3, 4: return .resizeLeftRight   // ML, MR
        default:   return .openHand
        }
    }

    // MARK: 活跃状态控制（由 Controller 调用）

    /// active=true：鼠标在本屏，高亮显示（浅遮罩）
    /// active=false：鼠标在其他屏，暗化显示（深遮罩）
    func setActive(_ active: Bool) {
        guard maskLayer.isHidden == false || !active else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 截图未到时不操作 maskLayer（仍然隐藏）
        if snapshotLayer.contents != nil {
            maskLayer.isHidden = false
            maskLayer.backgroundColor = active
                ? NSColor.black.withAlphaComponent(0.35).cgColor   // 活跃屏：浅遮罩
                : NSColor.black.withAlphaComponent(0.65).cgColor   // 非活跃屏：深遮罩
        }
        CATransaction.commit()
    }

    // MARK: Layer-based mask 更新（不触发 draw()）

    private func updateMaskForNoSelection() {
        // 无选区：维持当前活跃状态的遮罩，不强制重置
    }

    private func updateMaskForSelection() {
        // 有选区：使用 CAShapeLayer 镂空选区
        guard let root = layer else { return }

        // 移除旧的选区遮罩 shape layer
        root.sublayers?.filter { $0.name == "selectionMask" }.forEach { $0.removeFromSuperlayer() }

        let maskShape = CAShapeLayer()
        maskShape.name = "selectionMask"
        maskShape.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(selection)
        maskShape.path = path
        maskShape.fillRule = .evenOdd
        maskShape.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        // 插入到 snapshotLayer 上方、annotationContainer 下方
        if let idx = root.sublayers?.firstIndex(of: annotationContainer) {
            root.insertSublayer(maskShape, at: UInt32(idx))
        } else {
            root.addSublayer(maskShape)
        }

        // 隐藏纯色遮罩，改用 shape 遮罩
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.isHidden = true
        CATransaction.commit()
    }

    // MARK: Draw — 只负责选区边框和手柄，不绘制截图和标注

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard isValidSelection else { return }
        // 选区青色边框
        NSColor.systemCyan.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 2
        border.stroke()
        // 四角手柄
        drawHandles()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        if !toolbarView.isHidden && toolbarView.frame.contains(point) {
            super.mouseDown(with: event)
            return
        }
        if !confirmButton.isHidden && confirmButton.frame.contains(point) {
            super.mouseDown(with: event)
            return
        }
        if !cancelButton.isHidden && cancelButton.frame.contains(point) {
            super.mouseDown(with: event)
            return
        }
        // 首次点击：通知 Controller 锁定到本屏
        if !hasStartedSelection {
            hasStartedSelection = true
            onFirstMouseDown?()
        }

        // 标注命中检测优先：点击已有标注自动退出绘制模式并选中对象（Windows 端业界方案）
        if isValidSelection {
            // 已有选中标注时先检测调整手柄
            if let idx = selectedAnnotationIndex {
                let handleIdx = hitTestAnnotationHandle(point, annotationIndex: idx)
                if handleIdx >= 0 {
                    exitAnnotationTool()
                    selectHandleIndex = handleIdx
                    selectDragStart = point
                    selectDragStartAnnotation = annotations[idx]
                    return
                }
            }
            // 检测是否点中任意标注体
            if let hitIdx = hitTestAnnotations(point) {
                exitAnnotationTool()
                selectAnnotation(at: hitIdx)
                selectDragStart = point
                selectDragStartAnnotation = annotations[hitIdx]
                selectHandleIndex = nil
                return
            }
            // 点击选区内空白处：无工具时清除选中但不做其他操作
            if currentTool == .none {
                deselectAnnotation()
            }
        }

        // 绘制工具：在选区内开始绘制
        if currentTool != .none && isValidSelection && selection.contains(point) {
            startAnnotation(at: point)
            return
        }

        // 选区调整：有选区且无绘制工具时，点击选区内部空白不触发新选区
        let selMode = mode(at: point)
        if isValidSelection && currentTool == .none && selMode == .none && selection.contains(point) {
            return
        }

        anchor = point
        dragStartSelection = selection
        dragMode = selMode
        if dragMode == .none {
            dragMode = .new
            selection = NSRect(origin: point, size: .zero)
            layer?.sublayers?.filter { $0.name == "selectionMask" }.forEach { $0.removeFromSuperlayer() }
            if snapshotLayer.contents != nil { maskLayer.isHidden = false }
        }
        updateButtonFrames()
        updateToolbarFrame()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        // 标注拖拽（移动或调整手柄）：由 selectDragStartAnnotation 标记驱动
        if let idx = selectedAnnotationIndex, selectDragStartAnnotation != nil {
            if let handleIdx = selectHandleIndex {
                resizeAnnotation(at: idx, handleIndex: handleIdx, to: point)
            } else {
                moveAnnotation(at: idx, to: point)
            }
            return
        }
        if currentTool != .none && currentAnnLayer != nil {
            updateAnnotation(at: point)
            return
        }
        updateSelection(with: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = event.locationInWindow
        // 标注拖拽结束
        if selectDragStartAnnotation != nil {
            selectDragStartAnnotation = nil
            selectHandleIndex = nil
            return
        }
        if currentTool != .none && currentAnnLayer != nil {
            finishAnnotation(at: point)
            return
        }
        updateSelection(with: point)
        dragMode = .none
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                                    // Esc：分级处理
            if selectedAnnotationIndex != nil || currentTool != .none {
                deselectAnnotation()
                exitAnnotationTool()
            } else {
                onCancel?()
            }
        case 51, 117:                               // Delete / Forward Delete
            if let idx = selectedAnnotationIndex {
                deleteAnnotation(at: idx)
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Annotation — CAShapeLayer 增量渲染

    private func startAnnotation(at point: NSPoint) {
        deselectAnnotation()
        shapeStart = point
        let shapeLayer = CAShapeLayer()
        shapeLayer.strokeColor = selectedColor.cgColor
        shapeLayer.fillColor = selectedColor.withAlphaComponent(0.25).cgColor
        shapeLayer.lineWidth = currentTool == .pen ? penLineWidth : 2.0
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round

        switch currentTool {
        case .pen:
            let path = NSBezierPath()
            path.move(to: point)
            penPath = path
            shapeLayer.path = path.cgPath
        case .rect:
            shapeLayer.path = CGPath(rect: CGRect(origin: point, size: .zero), transform: nil)
        case .ellipse:
            shapeLayer.path = CGPath(ellipseIn: CGRect(origin: point, size: .zero), transform: nil)
        default: break
        }
        annotationContainer.addSublayer(shapeLayer)
        currentAnnLayer = shapeLayer
    }

    private func updateAnnotation(at point: NSPoint) {
        guard let annLayer = currentAnnLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch currentTool {
        case .pen:
            if let path = penPath {
                path.line(to: point)
                annLayer.path = path.cgPath
            }
        case .rect:
            annLayer.path = CGPath(rect: normalizedRect(from: shapeStart, to: point), transform: nil)
        case .ellipse:
            annLayer.path = CGPath(ellipseIn: normalizedRect(from: shapeStart, to: point), transform: nil)
        default: break
        }
        CATransaction.commit()
    }

    private func finishAnnotation(at point: NSPoint) {
        updateAnnotation(at: point)
        guard let annLayer = currentAnnLayer else { return }
        // 同步记录 Annotation 数据（用于命中检测和编辑）
        let ann: Annotation
        switch currentTool {
        case .pen:
            let path = penPath ?? NSBezierPath()
            ann = Annotation(kind: .path(path), color: selectedColor, lineWidth: penLineWidth)
        case .rect:
            let r = normalizedRect(from: shapeStart, to: point)
            ann = Annotation(kind: .rect(r), color: selectedColor, lineWidth: 2)
        case .ellipse:
            let r = normalizedRect(from: shapeStart, to: point)
            ann = Annotation(kind: .ellipse(r), color: selectedColor, lineWidth: 2)
        default:
            currentAnnLayer = nil; penPath = nil; return
        }
        annotations.append(ann)
        annotationLayers.append(annLayer)
        currentAnnLayer = nil
        penPath = nil
    }

    // MARK: Select 模式 — 命中检测 / 选中 / 移动 / 调整 / 删除

    private func hitTestAnnotations(_ point: NSPoint) -> Int? {
        // 从最后（最上层）往前找
        for i in stride(from: annotations.count - 1, through: 0, by: -1) {
            if annotations[i].hitTest(point) { return i }
        }
        return nil
    }

    /// 选中时调整手柄：仅 rect/ellipse 有 8 个方向手柄，pen 无手柄
    private func hitTestAnnotationHandle(_ point: NSPoint, annotationIndex idx: Int) -> Int {
        let ann = annotations[idx]
        switch ann.kind {
        case .rect(let r), .ellipse(let r):
            let handles = annotationHandlePoints(for: r)
            for (i, hp) in handles.enumerated() {
                if NSRect(x: hp.x - 6, y: hp.y - 6, width: 12, height: 12).contains(point) { return i }
            }
        default: break
        }
        return -1
    }

    /// 8 个调整手柄点：TL, TC, TR, ML, MR, BL, BC, BR
    private func annotationHandlePoints(for r: NSRect) -> [NSPoint] {
        [
            NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
            NSPoint(x: r.minX, y: r.midY),                                  NSPoint(x: r.maxX, y: r.midY),
            NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY)
        ]
    }

    private func selectAnnotation(at idx: Int) {
        selectedAnnotationIndex = idx
        updateSelectionHighlight()
    }

    private func deselectAnnotation() {
        selectedAnnotationIndex = nil
        selectionHighlightLayer?.removeFromSuperlayer()
        selectionHighlightLayer = nil
        needsDisplay = true
    }

    private func updateSelectionHighlight() {
        // 一次性移除旧的容器（外框 + 所有手柄）
        selectionHighlightLayer?.removeFromSuperlayer()
        selectionHighlightLayer = nil
        guard let idx = selectedAnnotationIndex, idx < annotations.count else { return }
        let ann = annotations[idx]

        // 用一个容器 layer 统一持有外框和所有手柄，确保整体一起移除，不留残影
        let container = CALayer()
        container.name = "selectionHighlightContainer"

        let hl = CAShapeLayer()
        hl.strokeColor = NSColor.white.cgColor
        hl.fillColor = NSColor.clear.cgColor
        hl.lineWidth = 1
        hl.lineDashPattern = [4, 3]
        let hlBounds = ann.bounds.insetBy(dx: -4, dy: -4)
        hl.path = CGPath(rect: hlBounds, transform: nil)
        container.addSublayer(hl)

        // 绘制 8 个手柄（仅 rect/ellipse）
        switch ann.kind {
        case .rect(let r), .ellipse(let r):
            for hp in annotationHandlePoints(for: r) {
                let hLayer = CAShapeLayer()
                hLayer.path = CGPath(rect: CGRect(x: hp.x - 4, y: hp.y - 4, width: 8, height: 8), transform: nil)
                hLayer.fillColor = NSColor.white.cgColor
                hLayer.strokeColor = NSColor.systemCyan.cgColor
                hLayer.lineWidth = 1
                container.addSublayer(hLayer)
            }
        default: break
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        annotationContainer.addSublayer(container)
        CATransaction.commit()

        selectionHighlightLayer = container
        needsDisplay = true
    }

    private func moveAnnotation(at idx: Int, to point: NSPoint) {
        guard let startAnn = selectDragStartAnnotation else { return }
        let dx = point.x - selectDragStart.x
        let dy = point.y - selectDragStart.y
        let movedAnn: Annotation
        switch startAnn.kind {
        case .path(let p):
            let moved = NSAffineTransform()
            moved.translateX(by: dx, yBy: dy)
            let newPath = moved.transform(p)
            movedAnn = Annotation(kind: .path(newPath), color: startAnn.color, lineWidth: startAnn.lineWidth)
        case .rect(let r):
            movedAnn = Annotation(kind: .rect(r.offsetBy(dx: dx, dy: dy)), color: startAnn.color, lineWidth: startAnn.lineWidth)
        case .ellipse(let r):
            movedAnn = Annotation(kind: .ellipse(r.offsetBy(dx: dx, dy: dy)), color: startAnn.color, lineWidth: startAnn.lineWidth)
        }
        annotations[idx] = movedAnn
        applyAnnotationToLayer(movedAnn, layer: annotationLayers[idx])
        updateSelectionHighlight()
    }

    private func resizeAnnotation(at idx: Int, handleIndex: Int, to point: NSPoint) {
        guard var ann = selectDragStartAnnotation else { return }
        switch ann.kind {
        case .rect(let r), .ellipse(let r):
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            switch handleIndex {
            case 0: minX = point.x; maxY = point.y   // TL
            case 1: maxY = point.y                    // TC
            case 2: maxX = point.x; maxY = point.y   // TR
            case 3: minX = point.x                    // ML
            case 4: maxX = point.x                    // MR
            case 5: minX = point.x; minY = point.y   // BL
            case 6: minY = point.y                    // BC
            case 7: maxX = point.x; minY = point.y   // BR
            default: break
            }
            let newR = NSRect(x: min(minX, maxX), y: min(minY, maxY),
                              width: abs(maxX - minX), height: abs(maxY - minY))
            switch ann.kind {
            case .rect:    ann = Annotation(kind: .rect(newR), color: ann.color, lineWidth: ann.lineWidth)
            case .ellipse: ann = Annotation(kind: .ellipse(newR), color: ann.color, lineWidth: ann.lineWidth)
            default: break
            }
        default: break
        }
        annotations[idx] = ann
        applyAnnotationToLayer(ann, layer: annotationLayers[idx])
        updateSelectionHighlight()
    }

    private func deleteAnnotation(at idx: Int) {
        annotationLayers[idx].removeFromSuperlayer()
        annotations.remove(at: idx)
        annotationLayers.remove(at: idx)
        deselectAnnotation()
    }

    /// 将 Annotation 数据同步回 CAShapeLayer
    private func applyAnnotationToLayer(_ ann: Annotation, layer: CAShapeLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.strokeColor = ann.color.cgColor
        layer.fillColor = ann.color.withAlphaComponent(0.25).cgColor
        switch ann.kind {
        case .path(let p):
            layer.path = p.cgPath
        case .rect(let r):
            layer.path = CGPath(rect: r, transform: nil)
        case .ellipse(let r):
            layer.path = CGPath(ellipseIn: r, transform: nil)
        }
        CATransaction.commit()
    }

    // MARK: Selection

    private var isValidSelection: Bool { selection.width >= minSize && selection.height >= minSize }

    @objc private func confirmTapped() {
        guard isValidSelection else { return }
        onConfirm?(selection, annotations)
    }

    @objc private func cancelTapped() { onCancel?() }

    private func updateSelection(with point: NSPoint) {
        switch dragMode {
        case .new:   selection = normalizedRect(from: anchor, to: point)
        case .move:  selection = clamped(dragStartSelection.offsetBy(dx: point.x - anchor.x, dy: point.y - anchor.y))
        case .topLeft, .topRight, .bottomLeft, .bottomRight: selection = resizedSelection(to: point)
        case .none:  break
        }
        updateButtonFrames()
        updateToolbarFrame()
        if isValidSelection {
            updateMaskForSelection()
        }
        needsDisplay = true
    }

    private func resizedSelection(to point: NSPoint) -> NSRect {
        var rect = dragStartSelection
        switch dragMode {
        case .topLeft:
            rect.origin.x = point.x; rect.size.width = dragStartSelection.maxX - point.x
            rect.size.height = point.y - dragStartSelection.minY
        case .topRight:
            rect.size.width = point.x - dragStartSelection.minX
            rect.size.height = point.y - dragStartSelection.minY
        case .bottomLeft:
            rect.origin.x = point.x; rect.origin.y = point.y
            rect.size.width = dragStartSelection.maxX - point.x
            rect.size.height = dragStartSelection.maxY - point.y
        case .bottomRight:
            rect.origin.y = point.y
            rect.size.width = point.x - dragStartSelection.minX
            rect.size.height = dragStartSelection.maxY - point.y
        default: break
        }
        return clamped(normalized(rect))
    }

    private func mode(at point: NSPoint) -> DragMode {
        guard isValidSelection else { return .none }
        if handleRect(.topLeft).contains(point)     { return .topLeft }
        if handleRect(.topRight).contains(point)    { return .topRight }
        if handleRect(.bottomLeft).contains(point)  { return .bottomLeft }
        if handleRect(.bottomRight).contains(point) { return .bottomRight }
        // 边框移动带（7px）：仅在选区边框附近才触发移动，内部留给绘制/标注操作
        if isSelectionMoveBand(point)               { return .move }
        return .none
    }

    /// 选区边框 7px 范围内判定为移动区（业界成熟方案：边框带移动，内部不影响绘制）
    private func isSelectionMoveBand(_ point: NSPoint) -> Bool {
        let band: CGFloat = 7
        let outer = selection.insetBy(dx: -band, dy: -band)
        let inner = NSRect(
            x: selection.minX + band, y: selection.minY + band,
            width: max(0, selection.width - band * 2),
            height: max(0, selection.height - band * 2))
        return outer.contains(point) && !inner.contains(point)
    }

    private func normalizedRect(from a: NSPoint, to b: NSPoint) -> NSRect {
        normalized(NSRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
    }

    private func normalized(_ rect: NSRect) -> NSRect {
        NSRect(x: min(rect.minX, rect.maxX), y: min(rect.minY, rect.maxY),
               width: abs(rect.width), height: abs(rect.height))
    }

    private func clamped(_ rect: NSRect) -> NSRect {
        var r = rect
        r.size.width  = min(max(r.width,  1), bounds.width)
        r.size.height = min(max(r.height, 1), bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    // MARK: Layout

    private func updateButtonFrames() {
        let visible = isValidSelection
        confirmButton.isHidden = !visible
        cancelButton.isHidden  = !visible
        guard visible else { return }
        let size = NSSize(width: 30, height: 30)
        let y = selection.minY >= 42 ? selection.minY - 38 : selection.maxY + 8
        cancelButton.frame  = NSRect(x: selection.maxX - 68, y: y, width: size.width, height: size.height)
        confirmButton.frame = NSRect(x: selection.maxX - 32, y: y, width: size.width, height: size.height)
    }

    private func updateToolbarFrame() {
        guard isValidSelection else { toolbarView.isHidden = true; return }
        toolbarView.isHidden = false
        let tw = toolbarView.frame.width
        let th = toolbarView.frame.height
        let tx = max(bounds.minX + 4, min(selection.minX, bounds.maxX - tw - 4))
        let buttonY = selection.minY >= 42 ? selection.minY - 38 : selection.maxY + 8
        let ty: CGFloat
        if buttonY - th - 6 >= bounds.minY + 4 {
            ty = buttonY - th - 6
        } else {
            ty = buttonY + 38
        }
        toolbarView.frame = NSRect(x: tx, y: ty, width: tw, height: th)
    }

    // MARK: Draw Helpers

    private func drawHandles() {
        NSColor.systemCyan.setFill()
        [DragMode.topLeft, .topRight, .bottomLeft, .bottomRight].forEach {
            NSBezierPath(roundedRect: handleRect($0), xRadius: 3, yRadius: 3).fill()
        }
    }

    private func handleRect(_ mode: DragMode) -> NSRect {
        let size: CGFloat = 10
        let point: NSPoint
        switch mode {
        case .topLeft:    point = NSPoint(x: selection.minX, y: selection.maxY)
        case .topRight:   point = NSPoint(x: selection.maxX, y: selection.maxY)
        case .bottomLeft: point = NSPoint(x: selection.minX, y: selection.minY)
        default:          point = NSPoint(x: selection.maxX, y: selection.minY)
        }
        return NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    // MARK: Toolbar

    private func makeToolbar() -> NSView {
        let toolDefs: [(symbol: String, tool: AnnotationTool)] = [
            ("pencil", .pen), ("rectangle", .rect), ("circle", .ellipse)
        ]
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemCyan, .white]
        let toolCount  = toolDefs.count
        let colorCount = colors.count
        let totalWidth: CGFloat = 8 + CGFloat(toolCount) * 34 + 9 + CGFloat(colorCount) * 22 + 9 + 30 + 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: 36))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        container.layer?.cornerRadius = 8

        var x: CGFloat = 8

        for (symbol, tool) in toolDefs {
            let btn = makeToolButton(symbol: symbol)
            btn.tag = tool.rawValue
            btn.target = self
            btn.action = #selector(toolTapped(_:))
            btn.frame = NSRect(x: x, y: 3, width: 30, height: 30)
            container.addSubview(btn)
            x += 34
        }

        addSeparator(to: container, x: &x)

        for color in colors {
            let btn = makeColorButton(color: color)
            btn.target = self
            btn.action = #selector(colorTapped(_:))
            btn.frame = NSRect(x: x, y: 9, width: 18, height: 18)
            if color.isApproximatelyEqual(to: selectedColor) {
                btn.layer?.borderWidth = 2
            }
            container.addSubview(btn)
            x += 22
        }

        addSeparator(to: container, x: &x)

        let undoBtn = makeToolButton(symbol: "arrow.uturn.backward")
        undoBtn.target = self
        undoBtn.action = #selector(undoTapped)
        undoBtn.frame = NSRect(x: x, y: 3, width: 30, height: 30)
        container.addSubview(undoBtn)

        return container
    }

    private func addSeparator(to view: NSView, x: inout CGFloat) {
        let sep = NSView(frame: NSRect(x: x, y: 6, width: 1, height: 24))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        view.addSubview(sep)
        x += 9
    }

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = AnnotationTool(rawValue: sender.tag) ?? .none
        // 再次点击同一工具取消激活（反选）
        currentTool = (currentTool == tool) ? .none : tool
        deselectAnnotation()
        refreshToolbarHighlight()
    }

    private func exitAnnotationTool() {
        guard currentTool != .none else { return }
        currentTool = .none
        refreshToolbarHighlight()
    }

    @objc private func colorTapped(_ sender: NSButton) {
        guard let cgColor = sender.layer?.backgroundColor,
              let color = NSColor(cgColor: cgColor) else { return }
        selectedColor = color
        refreshColorHighlight()
    }

    @objc private func undoTapped() {
        // 若有选中，先删除选中的；否则删除最后一条
        if let idx = selectedAnnotationIndex {
            deleteAnnotation(at: idx)
        } else if !annotationLayers.isEmpty {
            let last = annotationLayers.removeLast()
            last.removeFromSuperlayer()
            if !annotations.isEmpty { annotations.removeLast() }
        }
    }

    private func refreshToolbarHighlight() {
        for sub in toolbarView.subviews {
            guard let btn = sub as? NSButton, btn.tag > 0 else { continue }
            let tool = AnnotationTool(rawValue: btn.tag) ?? .none
            btn.layer?.backgroundColor = (tool == currentTool)
                ? NSColor.systemCyan.withAlphaComponent(0.55).cgColor
                : NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    private func refreshColorHighlight() {
        for sub in toolbarView.subviews {
            guard let btn = sub as? NSButton, btn.tag == 0,
                  btn.frame.width == 18 else { continue }
            guard let cgColor = btn.layer?.backgroundColor,
                  let btnColor = NSColor(cgColor: cgColor) else { continue }
            btn.layer?.borderWidth = btnColor.isApproximatelyEqual(to: selectedColor) ? 2 : 0
        }
    }

    private func makeToolButton(symbol: String) -> NSButton {
        let btn = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
            target: nil, action: nil)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.contentTintColor = .white
        btn.layer?.cornerRadius = 6
        btn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        return btn
    }

    private func makeColorButton(color: NSColor) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.title = ""
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = color.cgColor
        btn.layer?.cornerRadius = 9
        btn.layer?.borderColor = NSColor.white.cgColor
        btn.layer?.borderWidth = 0
        btn.tag = 0
        return btn
    }

    private func makeActionButton(symbol: String, color: NSColor) -> NSButton {
        let btn = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
            target: nil, action: nil)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.contentTintColor = .white
        btn.layer?.cornerRadius = 15
        btn.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor
        return btn
    }
}

// MARK: - NSBezierPath → CGPath

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo:  path.move(to: points[0])
            case .lineTo:  path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

// MARK: - NSColor 近似相等

private extension NSColor {
    func isApproximatelyEqual(to other: NSColor) -> Bool {
        guard let c1 = usingColorSpace(.sRGB),
              let c2 = other.usingColorSpace(.sRGB) else { return false }
        return abs(c1.redComponent   - c2.redComponent)   < 0.05 &&
               abs(c1.greenComponent - c2.greenComponent) < 0.05 &&
               abs(c1.blueComponent  - c2.blueComponent)  < 0.05
    }
}
