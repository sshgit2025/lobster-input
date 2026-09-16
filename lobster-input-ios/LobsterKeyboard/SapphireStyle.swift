import UIKit

/// Sapphire Glass 主按钮(Primary pill):蓝宝石纵向渐变(accentBright→accent)+ 白字,
/// 高 32 / 圆角 16 / 字 13 semibold。专用于「语音⇄打字」两个模式切换按钮。
/// layerClass 直接用 CAGradientLayer,渐变 frame 自动跟随按钮,无需手动同步。
final class SapphirePillButton: UIButton {

    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSapphireStyle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSapphireStyle()
    }

    private func configureSapphireStyle() {
        if let gradient = layer as? CAGradientLayer {
            gradient.colors = [LobsterWaterPalette.accentBright.cgColor, LobsterWaterPalette.accent.cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }
        layer.cornerRadius = KeyboardMetrics.pillCornerRadius
        // 与回车键同源的底缘投影(accentDeep@45%),让主 pill 与 3D 键帽质感一致
        layer.masksToBounds = false
        layer.shadowColor = LobsterWaterPalette.accentDeep.withAlphaComponent(0.45).cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = KeyboardMetrics.keycapShadowRadius
        layer.shadowOffset = CGSize(width: 0, height: KeyboardMetrics.keycapShadowOffsetY)
        titleLabel?.font = .systemFont(ofSize: KeyboardMetrics.pillFontSize, weight: .semibold)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.7
        setTitleColor(.white, for: .normal)
        setTitleColor(UIColor.white.withAlphaComponent(0.72), for: .highlighted)
        contentEdgeInsets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        heightAnchor.constraint(equalToConstant: KeyboardMetrics.pillHeight).isActive = true
        SapphirePressFeedback.install(on: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 投影用显式 path(圆角胶囊),避免依赖渐变内容的 alpha 轮廓
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: KeyboardMetrics.pillCornerRadius).cgPath
    }
}

/// Sapphire 3D 键帽背景(与 KeyView 键帽同源):纵向渐变(funcTop→funcBottom / enterTop→enterBottom)
/// + 1pt 描边 + 底缘投影;按压换 PRESS 渐变并下沉 1pt。纯视觉层,不拦截触摸、不参与 intrinsicContentSize。
/// 以 subview 形式垫在按钮内容底下(UIButton.Configuration 的 background 置透明),autoresizing 跟随按钮 bounds。
final class SapphireKeycapView: UIView {

    enum Corner {
        /// 胶囊:圆角 = 高度一半
        case capsule
        /// 固定圆角矩形
        case rounded(CGFloat)
    }

    override class var layerClass: AnyClass { CAGradientLayer.self }

    private let accent: Bool
    private let corner: Corner
    private var pressed = false
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    init(accent: Bool, corner: Corner) {
        self.accent = accent
        self.corner = corner
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.borderWidth = 1
        layer.masksToBounds = false
        layer.shadowOpacity = 1
        layer.shadowRadius = KeyboardMetrics.keycapShadowRadius
        layer.shadowOffset = CGSize(width: 0, height: KeyboardMetrics.keycapShadowOffsetY)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 按压态:funcPress 渐变(强调态保持 enter 渐变,靠下沉/缩放反馈)+ 下沉 1pt + 投影收窄。
    func setPressed(_ value: Bool) {
        guard pressed != value else { return }
        pressed = value
        applyColors()
        transform = value
            ? CGAffineTransform(translationX: 0, y: KeyboardMetrics.keycapPressSink)
            : .identity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowOffset = CGSize(width: 0, height: value ? 0.5 : KeyboardMetrics.keycapShadowOffsetY)
        CATransaction.commit()
    }

    private var cornerRadiusValue: CGFloat {
        switch corner {
        case .capsule: return bounds.height / 2
        case .rounded(let radius): return radius
        }
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if accent {
            gradient.colors = [LobsterWaterPalette.enterTop.cgColor, LobsterWaterPalette.enterBottom.cgColor]
            layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
            layer.shadowColor = LobsterWaterPalette.accentDeep.withAlphaComponent(0.45).cgColor
        } else {
            gradient.colors = pressed
                ? [LobsterWaterPalette.funcPressTop.cgColor, LobsterWaterPalette.funcPressBottom.cgColor]
                : [LobsterWaterPalette.funcTop.cgColor, LobsterWaterPalette.funcBottom.cgColor]
            layer.borderColor = LobsterWaterPalette.border.cgColor
            layer.shadowColor = LobsterWaterPalette.keyShadow.cgColor
        }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = cornerRadiusValue
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        CATransaction.commit()
    }
}

/// 键帽按压态驱动(与 SapphirePressFeedback 并存):按下/松开时切换按钮内 SapphireKeycapView 的
/// pressed 视觉。仅追加 target-action,不吞按钮原有 action;重复 install 幂等。
final class SapphireKeycapPressHandler: NSObject {

    static let shared = SapphireKeycapPressHandler()

    static func install(on control: UIControl) {
        control.removeTarget(shared, action: nil, for: .allEvents)
        control.addTarget(shared, action: #selector(pressDown(_:)), for: [.touchDown, .touchDragEnter])
        control.addTarget(
            shared,
            action: #selector(pressUp(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    @objc private func pressDown(_ control: UIControl) { keycap(in: control)?.setPressed(true) }
    @objc private func pressUp(_ control: UIControl) { keycap(in: control)?.setPressed(false) }

    private func keycap(in control: UIControl) -> SapphireKeycapView? {
        control.subviews.first { $0 is SapphireKeycapView } as? SapphireKeycapView
    }
}

extension UIButton {
    /// 应用 Sapphire 3D 键帽质感(次级功能按钮用 funcTop→funcBottom,强调态用 enterTop→enterBottom,
    /// 与 KeyView / 回车键同源)。会把 UIButton.Configuration 或普通背景置透明,由键帽视图承担填充/描边/投影,
    /// 不改 cornerStyle 内边距、不影响 intrinsicContentSize 与已有 addTarget action。可重复调用(幂等)。
    func applyKeycapStyle(accent: Bool = false, corner: SapphireKeycapView.Corner = .capsule) {
        subviews.compactMap { $0 as? SapphireKeycapView }.forEach { $0.removeFromSuperview() }
        let keycap = SapphireKeycapView(accent: accent, corner: corner)
        keycap.frame = bounds
        keycap.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(keycap, at: 0)
        if var config = configuration {
            // Configuration 按钮:清空自带底色/描边,避免盖住键帽渐变(布局参数不动)
            config.baseBackgroundColor = .clear
            config.background.backgroundColor = .clear
            config.background.strokeWidth = 0
            configuration = config
        } else {
            backgroundColor = .clear
            layer.borderWidth = 0
        }
        SapphirePressFeedback.install(on: self)
        SapphireKeycapPressHandler.install(on: self)
    }
}

/// 通用按压反馈:按下 scale 0.96(0.08s 快速跟手),松开 spring 复位。
/// 变暗由按钮自身高亮态承担(UIButton.Configuration.filled 自动变暗 / system 按钮标题变暗 /
/// SapphirePillButton 的 highlighted 白字降透明),避免直接改 alpha 干扰禁用态透明度逻辑。
/// 仅追加 target-action,绝不吞掉按钮原有 action;重复 install 幂等(先移除自身再注册)。
final class SapphirePressFeedback: NSObject {

    static let shared = SapphirePressFeedback()

    static func install(on control: UIControl) {
        control.removeTarget(shared, action: nil, for: .allEvents)
        control.addTarget(shared, action: #selector(pressDown(_:)), for: [.touchDown, .touchDragEnter])
        control.addTarget(
            shared,
            action: #selector(pressUp(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    @objc private func pressDown(_ control: UIControl) {
        UIView.animate(
            withDuration: KeyboardMetrics.pressDuration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            control.transform = CGAffineTransform(scaleX: KeyboardMetrics.pressScale, y: KeyboardMetrics.pressScale)
        }
    }

    @objc private func pressUp(_ control: UIControl) {
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.5,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            control.transform = .identity
        }
    }
}
