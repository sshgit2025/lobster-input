import UIKit

/// 音波波形动画(录音态)。竖条高度由实时音量驱动并逐帧插值,叠加正弦相位使动画自然不僵硬。
final class WaveformView: UIView {

    private let barCount = 9
    private var current = [CGFloat](repeating: 0, count: 9)
    private var level: CGFloat = 0
    private var warning = false
    private var tick: CGFloat = 0
    private var link: CADisplayLink?

    func setLevel(_ l: CGFloat) { level = max(0, min(1, l)) }
    func setWarning(_ w: Bool) { warning = w }

    func start() {
        if link != nil { return }
        let l = CADisplayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate(); link = nil
        level = 0
        for i in current.indices { current[i] = 0 }
        setNeedsDisplay()
    }

    @objc private func step() {
        tick += 0.32
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width, h = bounds.height
        if w <= 0 || h <= 0 { return }
        let barW: CGFloat = 2.6, gap: CGFloat = 3.2
        let totalW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * gap
        var x = (w - totalW) / 2
        let midY = h / 2
        let maxBar = h * 0.78
        let color = warning ? LobsterWaterPalette.danger : LobsterWaterPalette.accent
        ctx.setFillColor(color.cgColor)

        for i in 0..<barCount {
            let phase = tick + CGFloat(i) * 0.7
            let shape = 0.45 + 0.55 * ((sin(phase) + 1) / 2)
            let edge = 1 - abs(CGFloat(i) - CGFloat(barCount - 1) / 2) / CGFloat(barCount) * 0.5
            let target = min(3 + level * maxBar * shape * edge, maxBar)
            current[i] += (target - current[i]) * 0.28
            let bh = max(current[i], 3)
            let r = CGRect(x: x, y: midY - bh / 2, width: barW, height: bh)
            ctx.addPath(UIBezierPath(roundedRect: r, cornerRadius: barW / 2).cgPath)
            ctx.fillPath()
            x += barW + gap
        }
    }
}
