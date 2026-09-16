import UIKit

// MARK: - 水蓝涟漪录音钮（仅 UI / 动画，录音业务在外部）

/// 默认态与录音态共用同一扩散算法；录音时仅略增发射频率，音量不驱动波峰/振幅（避免挤在中心颤抖）。
final class KeyboardRecordOrbView: UIControl {

    private enum Mode { case idle, recording, processing }

    private struct Ripple {
        var radius: CGFloat
        var phase1: CGFloat
        var phase2: CGFloat
        var amplitude: CGFloat
        var life: CGFloat
        var speed: CGFloat
        var waves1: Int
        var waves2: Int
    }

    private enum Water {
        static let bgTop = LobsterWaterPalette.orbTop
        static let bgBottom = LobsterWaterPalette.orbBottom
        static let rim = LobsterWaterPalette.accent.withAlphaComponent(0.55)
        static let rippleDeep = LobsterWaterPalette.accentDeep
        static let rippleMid = LobsterWaterPalette.accentBright
        static let rippleLight = LobsterWaterPalette.accentSoft
        static let mic = LobsterWaterPalette.accentDeep
        static let micHighlight = LobsterWaterPalette.panelTop
        static let maxWobblePx: CGFloat = 2.0
        static let flowPhaseStep: CGFloat = 0.022
        static let ripplePhaseStep: CGFloat = 0.018
        static let refOrbRadius: CGFloat = 29
        static let expand: CGFloat = 0.28
        static let idleVisualEnergy: CGFloat = 0.16
        static let maxRipples = 3
        static let lifeDecayPerFrame: CGFloat = 0.007
    }

    private var displayLink: CADisplayLink?
    private var ripples: [Ripple] = []
    private var mode: Mode = .idle
    private var energy: CGFloat = 0
    private var smoothedEnergy: CGFloat = 0
    private var flowPhase: CGFloat = 0
    private var processingPhase = 0
    private var lastSpawnTime: CFTimeInterval = 0
    private var lastProcessingTick: CFTimeInterval = 0
    private var orbRadius: CGFloat = Water.refOrbRadius

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        layer.shadowColor = LobsterWaterPalette.accent.withAlphaComponent(0.35).cgColor
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowRadius = 8
        layer.shadowOpacity = 1
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        backgroundColor = .clear
    }

    deinit { stopAnimating() }

    override func layoutSubviews() {
        super.layoutSubviews()
        orbRadius = min(bounds.width, bounds.height) * 0.46
    }

    override var isHighlighted: Bool {
        didSet {
            if isHighlighted {
                if ripples.count < Water.maxRipples { spawnIdleStyleRipple() }
                UIView.animate(withDuration: 0.26, delay: 0, usingSpringWithDamping: 0.65, initialSpringVelocity: 0.8) {
                    self.transform = CGAffineTransform(scaleX: 1.07, y: 1.07)
                }
            } else {
                UIView.animate(withDuration: 0.18) { self.transform = .identity }
            }
        }
    }

    func setState(enabled: Bool, recording: Bool, processing: Bool) {
        let newMode: Mode = processing ? .processing : (recording ? .recording : .idle)
        if newMode != mode {
            ripples.removeAll()
            lastSpawnTime = 0
        }
        mode = newMode
        alpha = enabled ? 1 : 0.48
        isUserInteractionEnabled = enabled && !processing
        if mode == .idle {
            energy = 0
            smoothedEnergy = 0
        }
        startAnimating()
        setNeedsDisplay()
    }

    func updateLevel(_ level: Float) {
        energy = CGFloat(max(0, min(1, level)))
    }

    private func startAnimating() {
        stopAnimating()
        lastSpawnTime = 0
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
        ripples.removeAll()
    }

    private func sizeScale() -> CGFloat {
        min(max(orbRadius / Water.refOrbRadius, 0.9), 3.2)
    }

    @objc private func step() {
        let now = CACurrentMediaTime()
        flowPhase += Water.flowPhaseStep
        if mode == .recording {
            smoothedEnergy += (energy - smoothedEnergy) * 0.06
        } else {
            smoothedEnergy = 0
        }

        switch mode {
        case .recording:
            let interval = max(1.8, 2.4 - 0.5 * Double(smoothedEnergy))
            if ripples.count < Water.maxRipples,
               lastSpawnTime == 0 || now - lastSpawnTime >= interval {
                spawnIdleStyleRipple()
                lastSpawnTime = now
            }
        case .idle:
            if lastSpawnTime == 0 || now - lastSpawnTime > 3.2 {
                spawnIdleStyleRipple()
                lastSpawnTime = now
            }
        case .processing:
            if lastProcessingTick == 0 || now - lastProcessingTick > 0.4 {
                processingPhase = (processingPhase + 1) % 3
                lastProcessingTick = now
            }
            if lastSpawnTime == 0 || now - lastSpawnTime > 0.85 {
                spawnIdleStyleRipple()
                lastSpawnTime = now
            }
        }

        let maxR = orbRadius * 0.80
        ripples = ripples.compactMap { r in
            var x = r
            x.radius += x.speed * Water.expand
            x.phase1 += Water.ripplePhaseStep
            x.phase2 -= Water.ripplePhaseStep * 0.6
            x.life -= Water.lifeDecayPerFrame
            return (x.life > 0 && x.radius < maxR) ? x : nil
        }
        setNeedsDisplay()
    }

    private func spawnIdleStyleRipple() {
        let scale = sizeScale()
        let ec = Water.idleVisualEnergy
        let wobbleCap = Water.maxWobblePx * min(scale, 1.8)
        let wobble = min(wobbleCap, (0.85 + ec * 0.65) * min(scale, 1.35))
        ripples.append(Ripple(
            radius: orbRadius * 0.11,
            phase1: flowPhase,
            phase2: flowPhase * 0.5,
            amplitude: wobble,
            life: 1,
            speed: (0.30 + ec * 0.14) * scale,
            waves1: 3,
            waves2: 2
        ))
    }

    override func draw(_ rect: CGRect) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = orbRadius
        let pill = CGRect(x: c.x - r, y: c.y - r * 0.88, width: r * 2, height: r * 1.76)

        drawWaterBackground(pill: pill)
        drawSurfaceShimmer(pill: pill)
        for ripple in ripples {
            drawRipple(center: c, ripple: ripple)
        }
        drawMicIcon(center: c)
    }

    private func drawWaterBackground(pill: CGRect) {
        let path = UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2)
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        path.addClip()
        if let g = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [Water.bgTop.cgColor, Water.bgBottom.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(g, start: CGPoint(x: pill.midX, y: pill.minY), end: CGPoint(x: pill.midX, y: pill.maxY), options: [])
        }
        ctx.restoreGState()
        Water.rim.setStroke()
        path.lineWidth = mode == .recording ? 1.6 : 1.1
        path.stroke()
    }

    private func drawSurfaceShimmer(pill: CGRect) {
        let path = UIBezierPath()
        let y = pill.minY + pill.height * 0.38
        let amp: CGFloat = 0.55
        let steps = 24
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = pill.minX + 6 + t * (pill.width - 12)
            let wave = amp * sin(t * .pi * 3.2 + flowPhase)
            let p = CGPoint(x: x, y: y + wave)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        let shimmerAlpha: CGFloat = mode == .recording ? 0.43 : 0.35
        Water.rippleLight.withAlphaComponent(shimmerAlpha).setStroke()
        path.lineWidth = 1
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawRipple(center: CGPoint, ripple: Ripple) {
        let path = irregularRing(
            center: center,
            radius: ripple.radius,
            amp: ripple.amplitude * ripple.life,
            waves1: ripple.waves1,
            waves2: ripple.waves2,
            phase1: ripple.phase1,
            phase2: ripple.phase2
        )
        let a = ripple.life * (mode == .recording ? 0.68 : 0.5)
        Water.rippleDeep.withAlphaComponent(a * 0.35).setStroke()
        path.lineWidth = 1.6
        path.stroke()
        Water.rippleMid.withAlphaComponent(a * 0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
        Water.rippleLight.withAlphaComponent(a * 0.4).setStroke()
        path.lineWidth = 0.6
        path.stroke()
    }

    private func irregularRing(
        center: CGPoint,
        radius: CGFloat,
        amp: CGFloat,
        waves1: Int,
        waves2: Int,
        phase1: CGFloat,
        phase2: CGFloat
    ) -> UIBezierPath {
        let path = UIBezierPath()
        let n = 56
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            let wobble = amp * sin(CGFloat(waves1) * t + phase1) + amp * 0.15 * sin(CGFloat(waves2) * t + phase2)
            let rr = max(2, radius + wobble)
            let p = CGPoint(x: center.x + cos(t) * rr, y: center.y + sin(t) * rr)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.close()
        return path
    }

    private func drawMicIcon(center: CGPoint) {
        if mode == .processing {
            let gap: CGFloat = 9
            for i in 0..<3 {
                let on = i == processingPhase
                let s: CGFloat = on ? 4.5 : 3.2
                Water.rippleDeep.withAlphaComponent(on ? 0.95 : 0.35).setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - gap + CGFloat(i) * gap - s / 2, y: center.y - s / 2, width: s, height: s)).fill()
            }
            return
        }

        let body = UIBezierPath(roundedRect: CGRect(x: center.x - 5.5, y: center.y - 10, width: 11, height: 12.5), cornerRadius: 5.5)
        Water.micHighlight.setFill()
        body.fill()
        Water.mic.setStroke()
        body.lineWidth = 1.2
        body.stroke()

        if mode == .recording {
            LobsterWaterPalette.accentBright.setFill()
            UIBezierPath(roundedRect: CGRect(x: center.x - 3.5, y: center.y - 7.5, width: 7, height: 7), cornerRadius: 1.4).fill()
        }

        let stand = UIBezierPath()
        stand.lineWidth = 2
        stand.lineCapStyle = .round
        Water.mic.setStroke()
        stand.move(to: CGPoint(x: center.x, y: center.y + 2.5))
        stand.addLine(to: CGPoint(x: center.x, y: center.y + 8))
        stand.move(to: CGPoint(x: center.x - 6.5, y: center.y + 8))
        stand.addLine(to: CGPoint(x: center.x + 6.5, y: center.y + 8))
        stand.stroke()
    }
}
