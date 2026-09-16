import Foundation

/// 实时识别"打字机"平滑层(Mac 悬浮窗预览用)。
///
/// 上游(火山 Seed-ASR)在实时输入下吐字是突发的:前沿大约每 ~390ms 跳 ~2 个字,并伴随
/// 偶发 ~1 秒停顿。直接整段替换显示就会"一顿一顿"。本组件把突发到达的 partial 目标文本,
/// 转换成稳定逐字揭示的连续流,改善"边说边出字"的流畅观感。
///
/// 安全原则(必须遵守,勿破坏业务):
///  - 只驱动"显示用"文本(悬浮窗 displayLiveText),绝不参与最终提交;最终权威文本仍由
///    workflow 读取完整的 `liveText` / 后端 final 决策,并经剪贴板粘贴提交。
///  - `setTarget` 每次都用"最新 target 的前缀"重绘,因此火山对已显示区域的"纠正 / 整句替换"
///    会在下一 tick(≤tickMs)立即反映;不会丢字、不会显示过期文本。
///  - `flush` 立即补齐到最新 target(停止 / 收尾时调用)。
///  - 揭示速率随积压自适应(积压越多揭示越快,数百毫秒内追平最新 partial)。
///  - revealed==0 时不渲染空串,避免空渲染带来的无意义刷新。
@MainActor
final class TypewriterReveal {
    private let render: (String) -> Void
    private var targetChars: [Character] = []
    private var revealed: Int = 0
    private var task: Task<Void, Never>?
    private var lastRevealAt: Double = 0

    init(render: @escaping (String) -> Void) {
        self.render = render
    }

    /// 设置最新目标文本(来自 partial / completed)。已显示区域内的纠正会立即生效。
    func setTarget(_ text: String) {
        targetChars = Array(text)
        if revealed > targetChars.count { revealed = targetChars.count }
        if revealed > 0 { render(currentPrefix()) }
        if revealed < targetChars.count { startLoop() }
    }

    /// 立即补齐到最新目标并停止动画(停止 / 收尾时调用)。
    func flush() {
        stopLoop()
        revealed = targetChars.count
        render(String(targetChars))
    }

    /// 清空状态并停止动画(会话结束 / 清理时调用,显示清理由调用方负责)。
    func reset() {
        stopLoop()
        targetChars = []
        revealed = 0
        lastRevealAt = 0
    }

    private func currentPrefix() -> String {
        if revealed <= 0 { return "" }
        if revealed >= targetChars.count { return String(targetChars) }
        return String(targetChars[0..<revealed])
    }

    private func startLoop() {
        if task != nil { return }
        lastRevealAt = nowMs()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.revealed >= self.targetChars.count { self.task = nil; return }
                try? await Task.sleep(nanoseconds: Self.tickNanos)
                if Task.isCancelled { return }
                self.step()
                if self.revealed >= self.targetChars.count { self.task = nil; return }
            }
        }
    }

    private func stopLoop() {
        task?.cancel()
        task = nil
    }

    private func step() {
        guard revealed < targetChars.count else { return }
        let now = nowMs()
        var changed = false
        while revealed < targetChars.count {
            let backlog = targetChars.count - revealed
            let interval: Double = backlog >= 8 ? 22 : (backlog >= 4 ? 55 : 120)
            if now - lastRevealAt < interval { break }
            revealed += 1
            lastRevealAt += interval
            changed = true
        }
        if changed { render(currentPrefix()) }
    }

    private func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
    }

    private static let tickNanos: UInt64 = 30 * 1_000_000
}
