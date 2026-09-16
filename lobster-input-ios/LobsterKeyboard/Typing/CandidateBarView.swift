import UIKit

protocol CandidateBarDelegate: AnyObject {
    func candidateSelected(_ candidate: PinyinCandidate)
    func returnToVoiceTapped()
    func toggleLayoutTapped()
    func micRecordStart()
    func micRecordEnd()
    func micRecordCancel()
    func returnVoiceText() -> String
    func layoutSwitchText() -> String
    func expandCandidatesTapped()
    func pinyinOptionSelected(_ pinyin: String)
}

/// 候选栏(视图层)。含状态条、候选分页、T9 编号候选、麦克风录音态。
final class CandidateBarView: UIView {

    weak var delegate: CandidateBarDelegate?

    /// 返回语音(模式切换)主按钮:与 VoiceKeyboardView.keyboardButton 同规格 Primary pill
    private let modeButton = SapphirePillButton()
    private let layoutButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)
    private var micButton: MicButtonView!
    private let statusLabel = UILabel()
    private let composingLabel = UILabel()
    private let scroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let pinyinScroll = UIScrollView()
    private let pinyinStack = UIStackView()
    private var pinyinRowHeight: NSLayoutConstraint!
    private let waveform = WaveformView()
    private var cachedCandidates: [PinyinCandidate] = []
    private var pinyinOptions: [String] = []
    private var micWanted = true
    private var candidatePage = 0
    private let pageSize = 8
    private var numberedMode = false
    private var statusHideWork: DispatchWorkItem?

    init(delegate: CandidateBarDelegate) {
        self.delegate = delegate
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // 9 宫格前导音节自选行(隐藏时高 0,不占空间)
        pinyinStack.axis = .horizontal
        pinyinStack.alignment = .center
        pinyinStack.spacing = 6
        pinyinStack.translatesAutoresizingMaskIntoConstraints = false
        pinyinScroll.showsHorizontalScrollIndicator = false
        pinyinScroll.translatesAutoresizingMaskIntoConstraints = false
        pinyinScroll.addSubview(pinyinStack)

        modeButton.setContentHuggingPriority(.required, for: .horizontal)
        modeButton.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        configurePill(layoutButton, action: #selector(layoutTapped))
        configurePill(expandButton, action: #selector(expandTapped))
        expandButton.setTitle("▸", for: .normal)
        expandButton.isHidden = true

        micButton = MicButtonView(
            onRecordStart: { [weak self] in self?.setRecording(true); self?.delegate?.micRecordStart() },
            onRecordEnd: { [weak self] in self?.setRecording(false); self?.delegate?.micRecordEnd() },
            onRecordCancel: { [weak self] in self?.setRecording(false); self?.delegate?.micRecordCancel() }
        )
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.widthAnchor.constraint(equalToConstant: 38).isActive = true
        // MicButtonView 是裸 UIView 无 intrinsicContentSize,row.alignment=.center 下
        // 高度会塌缩为 0:图标画得出来(contentMode=.center 不裁剪)但 hit-test 区域为零,
        // 点击永远无响应(线上实测 bug)。显式给高度 44 保证 ≥44pt 触控目标。
        micButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        micButton.accessibilityLabel = MobileStrings.a11yKeyMic()

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = LobsterWaterPalette.danger
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.isHidden = true

        composingLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        composingLabel.textColor = LobsterWaterPalette.accent
        composingLabel.setContentHuggingPriority(.required, for: .horizontal)

        candidateStack.axis = .horizontal
        candidateStack.alignment = .center
        candidateStack.spacing = 2
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(candidateStack)

        let candidateRow = UIStackView(arrangedSubviews: [composingLabel, scroll, expandButton])
        candidateRow.axis = .horizontal
        candidateRow.alignment = .center
        candidateRow.spacing = 6

        let center = UIView()
        candidateRow.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.isOpaque = false
        waveform.backgroundColor = .clear
        waveform.isHidden = true
        center.addSubview(candidateRow)
        center.addSubview(waveform)
        center.addSubview(statusLabel)

        let row = UIStackView(arrangedSubviews: [modeButton, micButton, center, layoutButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        let outer = UIStackView(arrangedSubviews: [pinyinScroll, row])
        outer.axis = .vertical
        outer.alignment = .fill
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        pinyinRowHeight = pinyinScroll.heightAnchor.constraint(equalToConstant: 0)
        pinyinScroll.isHidden = true

        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: 52),
            pinyinRowHeight,
            pinyinStack.topAnchor.constraint(equalTo: pinyinScroll.topAnchor),
            pinyinStack.bottomAnchor.constraint(equalTo: pinyinScroll.bottomAnchor),
            pinyinStack.leadingAnchor.constraint(equalTo: pinyinScroll.leadingAnchor, constant: 4),
            pinyinStack.trailingAnchor.constraint(equalTo: pinyinScroll.trailingAnchor),
            pinyinStack.heightAnchor.constraint(equalTo: pinyinScroll.heightAnchor),
            candidateRow.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            candidateRow.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            candidateRow.topAnchor.constraint(equalTo: center.topAnchor),
            candidateRow.bottomAnchor.constraint(equalTo: center.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: center.leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: center.trailingAnchor, constant: -4),
            statusLabel.centerYAnchor.constraint(equalTo: center.centerYAnchor),
            waveform.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            waveform.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            waveform.topAnchor.constraint(equalTo: center.topAnchor),
            waveform.bottomAnchor.constraint(equalTo: center.bottomAnchor),
            candidateStack.topAnchor.constraint(equalTo: scroll.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            candidateStack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            candidateStack.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
        center.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    /// Secondary pill:Sapphire 3D 键帽质感(func 渐变 + 描边 + 底缘投影),文字 accentDeep。
    private func configurePill(_ button: UIButton, action: Selector) {
        button.titleLabel?.font = .systemFont(ofSize: KeyboardMetrics.pillFontSize, weight: .semibold)
        button.setTitleColor(LobsterWaterPalette.accentDeep, for: .normal)
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 11, bottom: 6, right: 11)
        button.heightAnchor.constraint(equalToConstant: KeyboardMetrics.pillHeight).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.applyKeycapStyle(corner: .capsule)
    }

    @objc private func modeTapped() { delegate?.returnToVoiceTapped() }
    @objc private func layoutTapped() { delegate?.toggleLayoutTapped() }
    @objc private func expandTapped() { delegate?.expandCandidatesTapped() }

    func render(composingDisplay: String, candidates: [PinyinCandidate], layoutLabel: String, numbered: Bool) {
        modeButton.setTitle(delegate?.returnVoiceText(), for: .normal)
        layoutButton.setTitle(layoutLabel, for: .normal)
        modeButton.accessibilityLabel = delegate?.returnVoiceText()
        layoutButton.accessibilityLabel = layoutLabel

        guard statusLabel.isHidden else {
            composingLabel.isHidden = true
            scroll.isHidden = true
            expandButton.isHidden = true
            return
        }

        composingLabel.text = composingDisplay
        composingLabel.isHidden = composingDisplay.isEmpty

        // 方案A:打字中(composing 非空)收起两侧(返回语音/麦克风/布局),候选占满整行;
        // composing 一空(选词/联想/空)立即恢复,避免输入结束功能缺失。
        // 1 键符号候选态(isSymbol)同样收起两侧:13 个符号需要整行空间,与候选词展开效果对齐
        // (emoji 联想态不收起,保持原状)。
        let typing = !composingDisplay.isEmpty || candidates.first?.isSymbol == true
        modeButton.isHidden = typing
        micButton.isHidden = typing || !micWanted
        // 布局切换(26↔九宫格)仅中文有意义:label 为空(英/俄/韩)时隐藏
        layoutButton.isHidden = typing || layoutLabel.isEmpty

        numberedMode = numbered
        cachedCandidates = candidates
        if candidatePage * pageSize >= candidates.count { candidatePage = 0 }
        rebuildCandidateButtons()

        expandButton.isHidden = candidates.count <= pageSize
        scroll.setContentOffset(.zero, animated: false)
    }

    func showStatus(_ message: String?, autoHideAfter: TimeInterval = 3) {
        statusHideWork?.cancel()
        guard let message, !message.isEmpty else {
            statusLabel.isHidden = true
            scroll.isHidden = false
            return
        }
        statusLabel.text = message
        statusLabel.isHidden = false
        scroll.isHidden = true
        composingLabel.isHidden = true
        expandButton.isHidden = true
        TypingAccessibilityLabels.announceStatus(on: self, message: message)
        let work = DispatchWorkItem { [weak self] in
            self?.statusLabel.isHidden = true
            self?.scroll.isHidden = false
        }
        statusHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: work)
    }

    func nextCandidatePage() {
        guard cachedCandidates.count > pageSize else { return }
        let maxPage = (cachedCandidates.count - 1) / pageSize
        candidatePage = candidatePage >= maxPage ? 0 : candidatePage + 1
        rebuildCandidateButtons()
    }

    private func rebuildCandidateButtons() {
        candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 拼音自选项内联在候选前(带边框区分),点选收窄;整行横滑,高度固定
        for p in pinyinOptions {
            let b = UIButton(type: .system)
            b.setTitle(p, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            b.setTitleColor(LobsterWaterPalette.accentDeep, for: .normal)
            b.contentEdgeInsets = UIEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
            b.addTarget(self, action: #selector(pinyinTapped(_:)), for: .touchUpInside)
            // 内联拼音 chip 同款键帽质感(胶囊)
            b.applyKeycapStyle(corner: .capsule)
            candidateStack.addArrangedSubview(b)
        }
        let start = candidatePage * pageSize
        let slice = Array(cachedCandidates.dropFirst(start).prefix(pageSize))
        for (i, c) in slice.enumerated() {
            let globalIndex = start + i
            let title = numberedMode ? "\(globalIndex + 1). \(c.word)" : c.word
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: numberedMode ? 16 : 18, weight: .regular)
            b.setTitleColor(LobsterWaterPalette.text, for: .normal)
            b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
            if globalIndex == 0 && candidatePage == 0 {
                // 首选候选高亮:accent @ 16% 玻璃填充
                b.backgroundColor = LobsterWaterPalette.accent.withAlphaComponent(0.16)
                b.layer.cornerRadius = KeyboardMetrics.keyCornerRadius
            }
            b.tag = globalIndex
            b.accessibilityLabel = TypingAccessibilityLabels.candidateLabel(c, index: globalIndex)
            b.addTarget(self, action: #selector(candidateTapped(_:)), for: .touchUpInside)
            SapphirePressFeedback.install(on: b)
            candidateStack.addArrangedSubview(b)
        }
    }

    @objc private func candidateTapped(_ sender: UIButton) {
        guard sender.tag < cachedCandidates.count else { return }
        delegate?.candidateSelected(cachedCandidates[sender.tag])
    }

    /// 更新拼音自选项(内联到候选行,独立行隐藏,不改键盘高度)。
    func renderPinyinOptions(_ options: [String]) {
        pinyinOptions = options
        pinyinScroll.isHidden = true
        pinyinRowHeight.constant = 0
        rebuildCandidateButtons()
    }

    @objc private func pinyinTapped(_ sender: UIButton) {
        if let p = sender.title(for: .normal) { delegate?.pinyinOptionSelected(p) }
    }

    func setRecording(_ active: Bool) {
        if active {
            waveform.isHidden = false
            scroll.isHidden = true
            composingLabel.isHidden = true
            expandButton.isHidden = true
            statusLabel.isHidden = true
            waveform.start()
        } else {
            waveform.stop()
            waveform.isHidden = true
            scroll.isHidden = statusLabel.isHidden ? false : true
            micButton.resetRecording()
        }
    }

    func updateLevel(_ level: CGFloat) { waveform.setLevel(level) }

    func setRecordProgress(_ remaining: CGFloat) {
        micButton.setProgress(remaining)
        let warn = remaining <= 0.16
        micButton.setWarning(warn)
        waveform.setWarning(warn)
    }
}
