import UIKit

/// 麦克风按钮(键盘候选栏)。按住即录(松手结束);滑出键区取消。
final class MicButtonView: UIView {

    private let onRecordStart: () -> Void
    private let onRecordEnd: () -> Void
    private let onRecordCancel: () -> Void

    private let icon = UIImageView()
    private let ring = CAShapeLayer()
    private var recording = false
    private var progress: CGFloat = 1
    private var warning = false
    private var micEnabled = true

    init(
        onRecordStart: @escaping () -> Void,
        onRecordEnd: @escaping () -> Void,
        onRecordCancel: @escaping () -> Void = {}
    ) {
        self.onRecordStart = onRecordStart
        self.onRecordEnd = onRecordEnd
        self.onRecordCancel = onRecordCancel
        super.init(frame: .zero)
        setup()
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        icon.contentMode = .center
        addSubview(icon)
        ring.fillColor = UIColor.clear.cgColor
        ring.lineCap = .round
        ring.isHidden = true
        layer.addSublayer(ring)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        applyAppearance()
    }

    /// 单击切换:未录音→开始实时识别;录音中→结束(按任意键也结束,由容器拦截)。
    @objc private func tapped() {
        guard micEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if recording { recording = false; applyAppearance(); onRecordEnd() }
        else { recording = true; progress = 1; warning = false; applyAppearance(); onRecordStart() }
    }

    /// 未登录置灰禁用。
    func setEnabledState(_ enabled: Bool) {
        guard micEnabled != enabled else { return }
        micEnabled = enabled
        if !enabled && recording { recording = false; onRecordEnd() }
        applyAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = bounds
        let r = min(bounds.width, bounds.height) / 2 - 2
        ring.frame = bounds
        ring.path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                                 radius: r, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
        ring.lineWidth = 2.2
    }

    private func applyAppearance() {
        let accent = warning ? LobsterWaterPalette.danger : LobsterWaterPalette.accent
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.image = UIImage(systemName: recording ? "mic.fill" : "mic", withConfiguration: config)?.withRenderingMode(.alwaysTemplate)
        icon.tintColor = !micEnabled ? LobsterWaterPalette.border : (recording ? accent : LobsterWaterPalette.accentDeep)
        ring.isHidden = !recording
        ring.strokeColor = accent.cgColor
        ring.strokeEnd = progress
        accessibilityLabel = MobileStrings.a11yKeyMic()
    }

    func resetRecording() { if recording { recording = false; applyAppearance() } }
    func setProgress(_ remaining: CGFloat) { progress = max(0, min(1, remaining)); ring.strokeEnd = progress }
    func setWarning(_ w: Bool) { if warning != w { warning = w; applyAppearance() } }
    var isRecording: Bool { recording }
}
