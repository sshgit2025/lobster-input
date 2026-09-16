import UIKit

protocol KeyViewDelegate: AnyObject {
    func keyShiftActive() -> Bool
    func keyCapsLock() -> Bool
    func keyMicActive() -> Bool
    func keyChineseMode() -> Bool
    func keyTapped(_ spec: TypingKeySpec)
    func keyLongPress(_ spec: TypingKeySpec)
    func keyShowBubble(_ view: KeyView, text: String)
    func keyHideBubble()
    func keyDeletePressDown()
    func keyDeletePressUp()
}

/// 自绘键帽(视图层)。Sapphire Glass 3D 键帽:纵向渐变填充 + 底缘投影,
/// 按压换 PRESS 渐变并整体下沉 1pt;功能键用 SF Symbols(原生精致),
/// 字母/T9 用文字;字母弹出气泡。不持有键盘状态,经 delegate 查询并回调。
final class KeyView: UIView {

    let spec: TypingKeySpec
    weak var delegate: KeyViewDelegate?

    private let label = UILabel()
    private let subLabel = UILabel()
    private let iconView = UIImageView()
    /// 键帽渐变背景层(圆角/描边都在这层,随按压整体下移 1pt)
    private let capGradient = CAGradientLayer()
    private var pressed = false
    private var longWork: DispatchWorkItem?
    private var longFired = false

    init(spec: TypingKeySpec, delegate: KeyViewDelegate) {
        self.spec = spec
        self.delegate = delegate
        super.init(frame: .zero)
        setup()
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .clear
        layer.cornerRadius = KeyboardMetrics.keyCornerRadius
        layer.shadowColor = LobsterWaterPalette.keyShadow.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 1.5)

        capGradient.cornerRadius = KeyboardMetrics.keyCornerRadius
        capGradient.borderWidth = 1
        capGradient.borderColor = LobsterWaterPalette.border.cgColor
        capGradient.startPoint = CGPoint(x: 0.5, y: 0)
        capGradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.insertSublayer(capGradient, at: 0)

        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)

        subLabel.textAlignment = .center
        subLabel.textColor = LobsterWaterPalette.muted
        subLabel.font = .systemFont(ofSize: 9, weight: .regular)
        addSubview(subLabel)

        iconView.contentMode = .center
        addSubview(iconView)

        isUserInteractionEnabled = true
        applyAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCap()
    }

    /// 键帽几何:按压时渐变层与内容整体下移 1pt、投影 offset 收窄,形成按下沉效果。
    /// CATransaction 关闭隐式动画,避免按压态切换拖影。
    private func layoutCap() {
        let dy: CGFloat = pressed ? 1 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capGradient.frame = bounds.offsetBy(dx: 0, dy: dy)
        layer.shadowOffset = CGSize(width: 0, height: pressed ? 0.5 : 1.5)
        layer.shadowPath = UIBezierPath(
            roundedRect: capGradient.frame,
            cornerRadius: KeyboardMetrics.keyCornerRadius
        ).cgPath
        CATransaction.commit()
        label.frame = bounds.offsetBy(dx: 0, dy: dy)
        iconView.frame = bounds.offsetBy(dx: 0, dy: dy)
        if spec.sub != nil, spec.type == .t9 || spec.type == .syllable || spec.type == .modeCycle {
            label.frame = bounds.offsetBy(dx: 0, dy: -5 + dy)
            // 轮换键:图标上移给下方标签留位
            iconView.frame = bounds.offsetBy(dx: 0, dy: -5 + dy)
            subLabel.frame = CGRect(x: 0, y: bounds.height - 16 + dy, width: bounds.width, height: 12)
        }
    }

    private var isFunc: Bool {
        switch spec.type {
        // symCands(9 宫格 1 键 @#)与字母键同款键帽:它位于 T9 键区内,视觉须与 2-9 键一致
        case .letter, .t9, .symChar, .symCands: return false
        default: return true
        }
    }

    func applyAppearance() {
        let enter = spec.type == .enter
        let micOn = spec.type == .mic && (delegate?.keyMicActive() ?? false)
        let onAccent = enter || micOn

        // 键帽纵向渐变:字母 keyTop→keyBottom;功能键 funcTop→funcBottom;按压换 PRESS 渐变;
        // 回车/麦克风激活 enterTop→enterBottom + 顶部内高光细描边(白@35%)+ accentDeep@45% 投影。
        let colors: [CGColor]
        if onAccent {
            colors = [LobsterWaterPalette.enterTop.cgColor, LobsterWaterPalette.enterBottom.cgColor]
        } else if isFunc {
            colors = pressed
                ? [LobsterWaterPalette.funcPressTop.cgColor, LobsterWaterPalette.funcPressBottom.cgColor]
                : [LobsterWaterPalette.funcTop.cgColor, LobsterWaterPalette.funcBottom.cgColor]
        } else {
            colors = pressed
                ? [LobsterWaterPalette.keyPressTop.cgColor, LobsterWaterPalette.keyPressBottom.cgColor]
                : [LobsterWaterPalette.keyTop.cgColor, LobsterWaterPalette.keyBottom.cgColor]
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capGradient.colors = colors
        capGradient.borderColor = onAccent
            ? UIColor.white.withAlphaComponent(0.35).cgColor
            : LobsterWaterPalette.border.cgColor
        layer.shadowColor = onAccent
            ? LobsterWaterPalette.accentDeep.withAlphaComponent(0.45).cgColor
            : LobsterWaterPalette.keyShadow.cgColor
        CATransaction.commit()
        layoutCap()

        // 重置
        label.isHidden = true; iconView.isHidden = true; subLabel.isHidden = true

        switch spec.type {
        case .delete:
            setIcon("delete.left", tint: pressed ? LobsterWaterPalette.accentDeep : LobsterWaterPalette.text)
        case .enter:
            setIcon("return", tint: .white)
            label.isHidden = false
            label.text = spec.main
            label.font = .systemFont(ofSize: spec.main.count > 2 ? 12 : 14, weight: .semibold)
            label.textColor = .white
            iconView.isHidden = spec.main.count <= 2
        case .shift:
            let caps = delegate?.keyCapsLock() ?? false
            let on = (delegate?.keyShiftActive() ?? false) || caps
            setIcon(caps ? "capslock.fill" : (on ? "shift.fill" : "shift"),
                    tint: on ? LobsterWaterPalette.accent : LobsterWaterPalette.text)
        case .mic:
            setIcon("mic.fill", tint: micOn ? .white : LobsterWaterPalette.accentDeep)
        case .letter:
            setText(displayText(), size: 19, weight: .regular, color: LobsterWaterPalette.text)
        case .t9:
            setText(spec.main, size: 15, weight: .semibold, color: LobsterWaterPalette.text)
            if let sub = spec.sub { subLabel.text = sub; subLabel.isHidden = false }
        case .modeCycle:
            // 模式轮换键:双弧循环箭头(非地球,避免与 iOS 系统地球键歧义)+ 下一模式短标签
            setIcon("arrow.triangle.2.circlepath", tint: pressed ? LobsterWaterPalette.accentDeep : LobsterWaterPalette.text)
            if let sub = spec.sub, !sub.isEmpty { subLabel.text = sub; subLabel.isHidden = false }
        default:
            let bold: Bool = [.lang, .num, .symbol, .alpha, .symPage, .layout, .syllable, .undo, .symBoard].contains(spec.type)
            setText(spec.main, size: spec.main.count > 1 ? 14 : 17,
                    weight: bold ? .semibold : .regular,
                    color: onAccent ? .white : LobsterWaterPalette.text)
            // 分词键(数字1)等:右下角小数字,对齐九宫格字母键
            if let sub = spec.sub { subLabel.text = sub; subLabel.isHidden = false }
        }
        accessibilityLabel = TypingAccessibilityLabels.keyLabel(
            for: spec,
            shiftActive: delegate?.keyShiftActive() ?? false,
            capsLock: delegate?.keyCapsLock() ?? false
        )
    }

    private func setText(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) {
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isHidden = false
    }

    private func setIcon(_ name: String, tint: UIColor) {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        iconView.image = UIImage(systemName: name, withConfiguration: config)?.withRenderingMode(.alwaysTemplate)
        iconView.tintColor = tint
        iconView.isHidden = false
    }

    private func displayText() -> String {
        let shifted = (delegate?.keyShiftActive() ?? false) || (delegate?.keyCapsLock() ?? false)
        // 韩语双辅音等 shift 变体键:shift 态显示变体(ㅂ→ㅃ)
        if spec.type == .letter, shifted, let sv = spec.shiftValue { return sv }
        // 拉丁/西里尔:非中文模式 shift 态大写
        if spec.type == .letter, !(delegate?.keyChineseMode() ?? true), shifted {
            return spec.main.uppercased()
        }
        return spec.main
    }

    // MARK: - Touch
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressed = true; applyAppearance(); longFired = false
        if spec.type == .delete { delegate?.keyDeletePressDown(); return }
        if spec.type == .letter { delegate?.keyShowBubble(self, text: displayText()) }
        if spec.longValue != nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.longFired = true
                self.delegate?.keyHideBubble()
                self.delegate?.keyLongPress(self.spec)
            }
            longWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressed = false; applyAppearance()
        longWork?.cancel()
        if spec.type == .delete { delegate?.keyDeletePressUp(); return }
        delegate?.keyHideBubble()
        if longFired { return }
        if let t = touches.first {
            let p = t.location(in: self)
            let hit = bounds.insetBy(dx: -12, dy: -16)
            if hit.contains(p) { delegate?.keyTapped(spec) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressed = false; applyAppearance()
        longWork?.cancel()
        if spec.type == .delete { delegate?.keyDeletePressUp() } else { delegate?.keyHideBubble() }
    }
}
