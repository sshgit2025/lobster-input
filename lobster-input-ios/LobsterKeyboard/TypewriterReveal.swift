import Foundation

/// 实时识别"打字机"平滑层(键盘扩展内)。
///
/// 上游(火山 Seed-ASR)在实时输入下吐字是突发的:前沿大约每 ~390ms 跳 ~2 个字,并伴随
/// 偶发 ~1 秒停顿。直接整段替换显示就会"一顿一顿"。本组件把突发到达的 partial 目标文本,
/// 转换成稳定逐字揭示的连续流,改善"边说边出字"的流畅观感。
///
/// 安全原则(必须遵守,勿破坏业务):
///  - 只影响"预览显示",绝不参与最终提交;最终权威文本仍由调用方在 finished 后整段提交。
///  - `setTarget` 每次都用"最新 target 的前缀"重绘,因此火山对已显示区域的"纠正 / 整句替换"
///    会在下一 tick(≤tickMs)立即反映到屏幕,不会丢字、不会显示过期文本。
///  - `flush` 立即把显示补齐到最新 target(停止 / 收尾时调用),保证被提交的是完整文本。
///  - 揭示速率随积压自适应:积压越多揭示越快(数百毫秒内追平最新 partial),不给"边说边识别"添加可感知延迟。
///
/// 线程约束:所有方法必须在主线程调用(渲染回调会编辑 textDocumentProxy)。
final class TypewriterReveal {
    private let render: (String) -> Void
    private var targetChars: [Character] = []
    private var revealed: Int = 0
    private var timer: DispatchSourceTimer?
    private var lastRevealAt: Double = 0

    init(render: @escaping (String) -> Void) {
        self.render = render
    }

    /// 设置最新目标文本(来自 partial / completed)。已显示区域内的纠正会立即生效。
    func setTarget(_ text: String) {
        targetChars = Array(text)
        if revealed > targetChars.count { revealed = targetChars.count }
        // 仅在已揭示>0 时重绘(反映纠正 / 整句替换);revealed==0 时不渲染空串。
        if revealed > 0 { render(currentPrefix()) }
        if revealed < targetChars.count { startTimer() }
    }

    /// 立即补齐到最新目标并停止动画(停止 / 收尾时调用)。
    func flush() {
        stopTimer()
        revealed = targetChars.count
        render(String(targetChars))
    }

    /// 清空状态并停止动画(会话结束 / 清理时调用,显示清理由调用方负责)。
    func reset() {
        stopTimer()
        targetChars = []
        revealed = 0
        lastRevealAt = 0
    }

    private func currentPrefix() -> String {
        if revealed <= 0 { return "" }
        if revealed >= targetChars.count { return String(targetChars) }
        return String(targetChars[0..<revealed])
    }

    private func startTimer() {
        if timer != nil { return }
        lastRevealAt = nowMs()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(Self.tickMs), repeating: .milliseconds(Self.tickMs))
        t.setEventHandler { [weak self] in self?.step() }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func step() {
        guard revealed < targetChars.count else { stopTimer(); return }
        let now = nowMs()
        var changed = false
        while revealed < targetChars.count {
            let backlog = targetChars.count - revealed
            let interval: Double = backlog >= Self.fastBacklog ? Self.fastMs
                : (backlog >= Self.midBacklog ? Self.midMs : Self.slowMs)
            if now - lastRevealAt < interval { break }
            revealed += 1
            lastRevealAt += interval
            changed = true
        }
        if changed { render(currentPrefix()) }
        if revealed >= targetChars.count { stopTimer() }
    }

    private func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
    }

    // 积压字数阈值与对应逐字间隔(毫秒):积压越大越快,平滑吸收上游停顿。
    private static let tickMs = 30
    private static let fastBacklog = 8
    private static let midBacklog = 4
    private static let fastMs: Double = 22
    private static let midMs: Double = 55
    private static let slowMs: Double = 120
}
