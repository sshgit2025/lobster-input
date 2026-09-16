import UIKit

enum KeyboardPersonaModule {
    case transcribe
    case rewrite
}

protocol VoiceKeyboardViewDelegate: AnyObject {
    func voiceKeyboardDidTapRecord()
    func voiceKeyboardDidBeginRealtimeRecord()
    func voiceKeyboardDidEndRealtimeRecord()
    func voiceKeyboardDidTapRewrite()
    func voiceKeyboardDidTapUndo()
    func voiceKeyboardDidTapRestore()
    func voiceKeyboardDidTapQuickAction(_ action: KeyboardQuickAction)
    func voiceKeyboardDidTapClearInput()
    func voiceKeyboardDidTapBackspace()
    func voiceKeyboardDidTapNewline()
    func voiceKeyboardDidTapSymbol(_ symbol: String)
    func voiceKeyboardDidChangeFastMode(_ enabled: Bool)
    func voiceKeyboardDidChangeHandLayout(rightHand: Bool)
    func voiceKeyboardDidTapNextKeyboard()
    func voiceKeyboardDidTapKeyboard()
    func voiceKeyboardDidTapDismiss()
    func voiceKeyboardDidTapOpenApp()
    func voiceKeyboardDidRefreshPersonas()
    func voiceKeyboardDidActivatePersona(_ persona: KeyboardPersona)
    func voiceKeyboardDidDeactivatePersonas()
    func voiceKeyboardDidTogglePersonaModule(_ persona: KeyboardPersona, module: KeyboardPersonaModule)
}

final class VoiceKeyboardView: UIView {

    weak var delegate: VoiceKeyboardViewDelegate?

    enum Palette {
        static let panel = LobsterWaterPalette.panel
        static let surface = LobsterWaterPalette.surface
        static let surfaceMuted = LobsterWaterPalette.surfaceMuted
        static let border = LobsterWaterPalette.border
        static let button = LobsterWaterPalette.button
        static let buttonStrong = LobsterWaterPalette.buttonStrong
        static let accent = LobsterWaterPalette.accent
        static let accentBright = LobsterWaterPalette.accentBright
        static let accentDeep = LobsterWaterPalette.accentDeep
        static let accentSoft = LobsterWaterPalette.accentSoft
        static let text = LobsterWaterPalette.text
        static let muted = LobsterWaterPalette.muted
    }

    private enum ShortcutAction {
        case quick(KeyboardQuickAction)
        case clearInput
    }

    private let rootStack = UIStackView()
    private let voicePanel = UIStackView()
    private let header = UIStackView()
    private let brandLabel = UILabel()
    private let handButton = UIButton(type: .system)
    private let atButton = UIButton(type: .system)
    private let personaButton = UIButton(type: .system)
    private let symbolButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let backspaceButton = UIButton(type: .system)
    private let keyboardButton = SapphirePillButton()

    private let unavailablePanel = UIStackView()
    private let unavailableTitle = UILabel()
    private let unavailableBody = UILabel()
    private let switchKeyboardButton = UIButton(type: .system)
    private let openAppButton = UIButton(type: .system)

    private let contentRow = UIStackView()
    private let actionColumn = UIStackView()
    private let voiceColumn = UIStackView()
    private let statusLabel = UILabel()
    private let sessionBadgeLabel = UILabel()
    private let recordButton = KeyboardRecordOrbView()
    private let fastModeButton = UIButton(type: .system)
    private let restoreButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let newlineButton = UIButton(type: .system)
    private let rewriteButton = UIButton(type: .system)
    private let commandHintLabel = UILabel()

    private let symbolPanel = UIStackView()
    private let personaPanel = UIStackView()

    private var fastModeEnabled = false
    private var realtimeRecognitionEnabled = false
    private var realtimeTouchAllowedByState = false
    private var realtimeTouchEnabled = false
    private var realtimeTouchActive = false
    private var rightHandLayout = true
    private var currentPersonas: [KeyboardPersona] = []
    private var selectedPersonaID: String?
    private var personasLoading = false
    private var personasRefreshing = false
    private var pendingPersonaID: String?
    private var backspaceTimer: Timer?
    private var backspaceLongPressFired = false

    private let keyboardHeight: CGFloat = 258
    private let panelContentHeight: CGFloat = 242

    /// Sapphire 面板纵向渐变背景(panelTop→panelBottom),frame 在 layoutSubviews 同步。
    private let backgroundGradient = CAGradientLayer()

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: keyboardHeight)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    func wireInputModeListTarget(_ target: Any?, action: Selector) {
        globeButton.removeTarget(self, action: #selector(globeTapped), for: .touchUpInside)
        globeButton.addTarget(target, action: action, for: .allTouchEvents)
    }

    func setNeedsSwitchKey(_ needed: Bool) {
        globeButton.isHidden = !needed
    }

    func setLoggedIn(_ loggedIn: Bool, canRewrite: Bool, canUndo: Bool, canRestore: Bool) {
        refreshStaticLabels()
        showVoicePanel()
        unavailablePanel.isHidden = true
        contentRow.isHidden = false
        commandHintLabel.isHidden = false
        if loggedIn {
            setIdle(canRewrite: canRewrite, canUndo: canUndo, canRestore: canRestore)
        } else {
            showUnavailable(creditsExhausted: false)
        }
    }

    func setRequiresFullAccess() {
        setRealtimeTouchHandling(false)
        refreshStaticLabels()
        showVoicePanel()
        unavailablePanel.isHidden = false
        contentRow.isHidden = true
        commandHintLabel.isHidden = true
        unavailableTitle.text = MobileStrings.fullAccessTitle()
        unavailableBody.text = MobileStrings.fullAccessBody()
        setRecord(enabled: false, recording: false, processing: false)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false)
    }

    func showUnavailable(creditsExhausted: Bool) {
        setRealtimeTouchHandling(false)
        refreshStaticLabels()
        showVoicePanel()
        unavailablePanel.isHidden = false
        contentRow.isHidden = true
        commandHintLabel.isHidden = true
        unavailableTitle.text = MobileStrings.inputUnavailableTitle(creditsExhausted: creditsExhausted)
        unavailableBody.text = MobileStrings.inputUnavailableBody(creditsExhausted: creditsExhausted)
        setRecord(enabled: false, recording: false, processing: false)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false)
    }

    func setAccountChecking() {
        setRealtimeTouchHandling(false)
        setStatus(MobileStrings.checkingAccount(), color: Palette.muted)
        setRecord(enabled: false, recording: false, processing: true)
    }

    func setIdle(canRewrite: Bool, canUndo: Bool, canRestore: Bool) {
        setRealtimeTouchHandling(true)
        unavailablePanel.isHidden = true
        contentRow.isHidden = false
        commandHintLabel.isHidden = false
        let prompt = realtimeRecognitionEnabled && !canRewrite ? MobileStrings.holdToSpeak() : (canRewrite ? MobileStrings.rewriteHint() : MobileStrings.tapToSpeak())
        setStatus(prompt, color: Palette.muted)
        setRecord(enabled: true, recording: false, processing: false)
        updateActionAvailability(canRewrite: canRewrite, canUndo: canUndo, canRestore: canRestore)
    }

    func setSessionBadge(_ badge: KeyboardVoiceSessionBadge) {
        switch badge {
        case .ready:
            sessionBadgeLabel.text = "● " + MobileStrings.voiceSessionReadyBadge()
            sessionBadgeLabel.textColor = LobsterWaterPalette.accentBright
            sessionBadgeLabel.isHidden = false
        case .connecting:
            sessionBadgeLabel.text = "◌ " + MobileStrings.voiceSessionConnecting()
            sessionBadgeLabel.textColor = Palette.accent
            sessionBadgeLabel.isHidden = false
        case .needsApp:
            sessionBadgeLabel.text = "○ " + MobileStrings.voiceSessionNeedsAppBadge()
            sessionBadgeLabel.textColor = Palette.muted
            sessionBadgeLabel.isHidden = false
        }
    }

    func hideSessionBadge() {
        sessionBadgeLabel.isHidden = true
    }

    func setRecording(isRewrite: Bool, remainingSeconds: Int) {
        setRealtimeTouchHandling(false)
        showVoicePanel()
        unavailablePanel.isHidden = true
        contentRow.isHidden = false
        commandHintLabel.isHidden = false
        let countdown = MobileStrings.recordingCountdown(remainingSeconds)
        let text = "\(MobileStrings.tapAgainRecording(isRewrite))\n\(countdown)"
        setStatus(text, color: Palette.accent)
        setRecord(enabled: true, recording: true, processing: false)
        setSessionBadge(.ready)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false)
    }

    func setRealtimeConnecting() {
        setRealtimeTouchHandling(true)
        showVoicePanel()
        unavailablePanel.isHidden = true
        contentRow.isHidden = false
        commandHintLabel.isHidden = false
        setStatus(MobileStrings.realtimeConnecting(), color: Palette.muted)
        setRecord(enabled: true, recording: false, processing: true)
        setSessionBadge(.connecting)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false, utilityEnabled: true)
    }

    func setRealtimeRecording(remainingSeconds: Int) {
        setRealtimeTouchHandling(true)
        showVoicePanel()
        unavailablePanel.isHidden = true
        contentRow.isHidden = false
        commandHintLabel.isHidden = false
        let text = "\(MobileStrings.releaseToSend())\n\(MobileStrings.recordingCountdown(remainingSeconds))"
        setStatus(text, color: Palette.accent)
        setRecord(enabled: true, recording: true, processing: false)
        setSessionBadge(.ready)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false)
    }

    func setRealtimeProcessing() {
        setRealtimeTouchHandling(false)
        showVoicePanel()
        setStatus(MobileStrings.realtimeFinishing(), color: Palette.muted)
        setRecord(enabled: false, recording: false, processing: true)
        setSessionBadge(.ready)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false, utilityEnabled: false)
    }

    func setWakingSession(isRewrite: Bool) {
        setRealtimeTouchHandling(false)
        showVoicePanel()
        unavailablePanel.isHidden = true
        contentRow.isHidden = false
        commandHintLabel.isHidden = false
        setStatus(MobileStrings.voiceSessionWakeAppHint(), color: Palette.muted)
        setRecord(enabled: true, recording: false, processing: true)
        setSessionBadge(.connecting)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false, utilityEnabled: true)
    }

    func setProcessing(isRewrite: Bool) {
        setRealtimeTouchHandling(false)
        showVoicePanel()
        setStatus(MobileStrings.processing(isRewrite), color: Palette.muted)
        setRecord(enabled: false, recording: false, processing: true)
        setSessionBadge(.ready)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false, utilityEnabled: false)
    }

    func setKeyboardHandoffStarting(isRewrite: Bool) {
        setRealtimeTouchHandling(false)
        showVoicePanel()
        unavailablePanel.isHidden = true
        contentRow.isHidden = false
        commandHintLabel.isHidden = false
        setStatus(MobileStrings.processingShort(), color: Palette.muted)
        setRecord(enabled: false, recording: false, processing: true)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false)
    }

    func setQuickProcessing() {
        setRealtimeTouchHandling(false)
        showVoicePanel()
        setStatus(MobileStrings.quickProcessing(), color: Palette.muted)
        setRecord(enabled: false, recording: false, processing: true)
        updateActionAvailability(canRewrite: false, canUndo: false, canRestore: false)
    }

    func showInserted(canRewrite: Bool, canUndo: Bool, canRestore: Bool, rewritten: Bool = false) {
        setRealtimeTouchHandling(true)
        setStatus(rewritten ? MobileStrings.rewritten() : MobileStrings.inserted(), color: Palette.muted)
        setRecord(enabled: true, recording: false, processing: false)
        updateActionAvailability(canRewrite: canRewrite, canUndo: canUndo, canRestore: canRestore)
    }

    func showError(_ message: String, canRewrite: Bool, canUndo: Bool, canRestore: Bool) {
        setRealtimeTouchHandling(true)
        setStatus(message, color: LobsterWaterPalette.danger)
        setRecord(enabled: true, recording: false, processing: false)
        updateActionAvailability(canRewrite: canRewrite, canUndo: canUndo, canRestore: canRestore)
    }

    func showTransientStatus(_ message: String) {
        setStatus(message, color: Palette.muted)
    }

    func updateAudioLevel(_ level: Float) {
        recordButton.updateLevel(level)
    }

    private func setRealtimeTouchHandling(_ enabled: Bool) {
        realtimeTouchAllowedByState = enabled
        realtimeTouchEnabled = realtimeRecognitionEnabled && realtimeTouchAllowedByState
        if !realtimeTouchEnabled {
            realtimeTouchActive = false
        }
    }

    func setFastMode(_ enabled: Bool) {
        fastModeEnabled = enabled
        fastModeButton.configuration?.title = fastModeTitle()
        // 开关状态用高亮键帽表示(开=蓝宝石强调白字,关=常态玻璃),
        // 不再用"极速 开/关"两段文案(俄语 Быстро ВКЛ 最长最挤)
        fastModeButton.configuration?.baseForegroundColor = enabled ? UIColor.white : Palette.accentDeep
        fastModeButton.applyKeycapStyle(accent: enabled, corner: .capsule)
        fastModeButton.alpha = 1
    }

    func setRealtimeRecognitionEnabled(_ enabled: Bool) {
        realtimeRecognitionEnabled = enabled
        realtimeTouchEnabled = realtimeRecognitionEnabled && realtimeTouchAllowedByState
        if !realtimeTouchEnabled {
            realtimeTouchActive = false
        }
        if enabled {
            setStatus(MobileStrings.holdToSpeak(), color: Palette.muted)
        }
    }

    func setHandLayout(rightHand: Bool) {
        rightHandLayout = rightHand
        handButton.configuration?.title = rightHand ? MobileStrings.rightHand() : MobileStrings.leftHand()
        rebuildShortcutRows()
        applyHandLayout()
    }

    func setPersonas(
        _ personas: [KeyboardPersona],
        loading: Bool,
        refreshing: Bool,
        pendingID: String?
    ) {
        currentPersonas = personas
        personasLoading = loading
        personasRefreshing = refreshing
        pendingPersonaID = pendingID
        if let id = selectedPersonaID, !personas.contains(where: { $0.id == id }) {
            selectedPersonaID = nil
        }
        rebuildPersonaPanel()
    }

    // MARK: - Setup

    private func setupUI() {
        // 纯色仅作 fallback,可见背景为纵向渐变
        backgroundColor = Palette.panel
        backgroundGradient.colors = [LobsterWaterPalette.panelTop.cgColor, LobsterWaterPalette.panelBottom.cgColor]
        backgroundGradient.startPoint = CGPoint(x: 0.5, y: 0)
        backgroundGradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.insertSublayer(backgroundGradient, at: 0)

        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        // 底边改为钉死(999 可让步):让 voicePanel 吃满面板高度,内容行垂直均衡、
        // commandHintLabel 固定在底部,消除底部死留白
        let rootBottom = rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        rootBottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rootBottom,
        ])

        setupVoicePanel()
        setupSymbolPanel()
        setupPersonaPanel()
        refreshStaticLabels()
        setFastMode(false)
        setHandLayout(rightHand: true)
        setIdle(canRewrite: false, canUndo: false, canRestore: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundGradient.frame = bounds
        CATransaction.commit()
    }

    private func setupVoicePanel() {
        voicePanel.axis = .vertical
        voicePanel.alignment = .fill
        voicePanel.spacing = 8
        rootStack.addArrangedSubview(voicePanel)

        setupHeader()
        setupUnavailablePanel()
        setupContentRow()

        commandHintLabel.font = .systemFont(ofSize: 10, weight: .medium)
        commandHintLabel.textColor = Palette.muted
        commandHintLabel.alpha = 0.72
        commandHintLabel.textAlignment = .center
        commandHintLabel.adjustsFontSizeToFitWidth = true
        commandHintLabel.minimumScaleFactor = 0.7
        commandHintLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 底部行:左侧「单手(左右手镜像)」低频开关 + 右侧命令提示文案。
        // 单手从麦克风语音列迁到这里,给它一个够宽、不挤压任何区域的低显著度位置。
        configurePill(handButton, title: "", width: 56, action: #selector(handTapped))
        let bottomBar = UIStackView(arrangedSubviews: [handButton, commandHintLabel])
        bottomBar.axis = .horizontal
        bottomBar.alignment = .center
        bottomBar.spacing = 10
        // 提示固定底部:纵向 hugging 提到 required,让 contentRow 吃掉剩余高度(垂直均衡)
        bottomBar.setContentHuggingPriority(.required, for: .vertical)
        voicePanel.addArrangedSubview(bottomBar)
    }

    private func setupHeader() {
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 5
        voicePanel.addArrangedSubview(header)
        // 顶栏统一 44pt 工具栏,按钮 32pt 垂直居中:
        // 语音端按钮顶 Y = 8(rootStack top)+ (44-32)/2 = 14,
        // 打字端按钮顶 Y = 4(candidateBar top)+ (52-32)/2 = 14,两模式对齐
        header.heightAnchor.constraint(equalToConstant: KeyboardMetrics.toolbarHeight).isActive = true

        // 模式切换主按钮(Primary pill):蓝宝石渐变白字,点击切到打字键盘。
        keyboardButton.setTitle(MobileStrings.keyboardModeLabel(), for: .normal)
        keyboardButton.addTarget(self, action: #selector(keyboardModeTapped), for: .touchUpInside)
        header.addArrangedSubview(keyboardButton)
        // 弹性空白:把右侧功能键推到右边(品牌名已移除)
        let headerSpacer = UIView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(headerSpacer)

        // 2026-07 语音面板重排版(三端同步,预算模型 test_voice_toolbar_layout.py):
        // @ 回归工具栏右侧显眼位置(微信聊天高频符号),一键可达,不必进符号面板;
        // "单手"迁至底部提示行(低频设置项),不再挤占麦克风语音列工具行。
        // @ 键:放右侧功能簇首位、字号加大突出高频地位
        configurePill(atButton, title: "@", width: 40, action: #selector(atTapped))
        atButton.configuration?.titleTextAttributesTransformer = Self.textAttributes(size: 17, weight: .semibold)
        header.addArrangedSubview(atButton)
        configurePill(personaButton, title: "", width: 46, action: #selector(personaTapped))
        configurePill(symbolButton, title: "", width: 42, action: #selector(symbolTapped))
        header.addArrangedSubview(personaButton)
        header.addArrangedSubview(symbolButton)
        configureIcon(globeButton, icon: "globe", width: 30, action: #selector(globeTapped))
        configureIcon(dismissButton, icon: "keyboard.chevron.compact.down", width: 30, action: #selector(dismissTapped))
        configureIcon(backspaceButton, icon: "delete.left", width: 34, action: #selector(backspaceTapped))
        installBackspaceRepeat()
    }

    @objc private func keyboardModeTapped() {
        delegate?.voiceKeyboardDidTapKeyboard()
    }

    private func setupUnavailablePanel() {
        unavailablePanel.axis = .vertical
        unavailablePanel.alignment = .fill
        unavailablePanel.spacing = 7
        unavailablePanel.backgroundColor = Palette.surface
        unavailablePanel.layer.cornerRadius = 16
        unavailablePanel.layer.borderWidth = 1
        unavailablePanel.layer.borderColor = Palette.border.cgColor
        unavailablePanel.isLayoutMarginsRelativeArrangement = true
        unavailablePanel.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        voicePanel.addArrangedSubview(unavailablePanel)
        // 底边钉死后此面板可拉伸吃满剩余高度(内部 spacer 吸收余量),避免固定高与钉底冲突
        unavailablePanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 154).isActive = true

        unavailableTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        unavailableTitle.textColor = Palette.accentDeep
        unavailableTitle.textAlignment = .center
        unavailablePanel.addArrangedSubview(unavailableTitle)

        unavailableBody.font = .systemFont(ofSize: 11, weight: .regular)
        unavailableBody.textColor = Palette.muted
        unavailableBody.numberOfLines = 3
        unavailableBody.textAlignment = .center
        unavailablePanel.addArrangedSubview(unavailableBody)

        let spacer = UIView()
        unavailablePanel.addArrangedSubview(spacer)

        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 7
        row.heightAnchor.constraint(equalToConstant: 38).isActive = true
        configurePill(switchKeyboardButton, title: "", width: nil, action: #selector(globeTapped), strong: true)
        configurePill(openAppButton, title: "", width: nil, action: #selector(openAppTapped), strong: false)
        row.addArrangedSubview(switchKeyboardButton)
        row.addArrangedSubview(openAppButton)
        unavailablePanel.addArrangedSubview(row)
    }

    private func setupContentRow() {
        contentRow.axis = .horizontal
        contentRow.alignment = .center
        contentRow.spacing = 8
        voicePanel.addArrangedSubview(contentRow)

        setupActionColumn()
        setupVoiceColumn()
        applyHandLayout()
    }

    private func setupActionColumn() {
        actionColumn.axis = .vertical
        actionColumn.alignment = .fill
        actionColumn.spacing = 7

        let primaryRow = UIStackView()
        primaryRow.axis = .horizontal
        primaryRow.distribution = .fillEqually
        primaryRow.spacing = 7
        primaryRow.heightAnchor.constraint(equalToConstant: 38).isActive = true
        actionColumn.addArrangedSubview(primaryRow)

        let quickTop = UIStackView()
        quickTop.axis = .horizontal
        quickTop.distribution = .fillEqually
        quickTop.spacing = 7
        quickTop.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let quickBottom = UIStackView()
        quickBottom.axis = .horizontal
        quickBottom.distribution = .fillEqually
        quickBottom.spacing = 7
        quickBottom.heightAnchor.constraint(equalToConstant: 38).isActive = true

        actionColumn.addArrangedSubview(quickTop)
        actionColumn.addArrangedSubview(quickBottom)
        actionColumn.tag = 900
        primaryRow.tag = 901
        quickTop.tag = 902
        quickBottom.tag = 903
        rebuildShortcutRows()
    }

    private func setupVoiceColumn() {
        voiceColumn.axis = .vertical
        voiceColumn.alignment = .fill
        voiceColumn.spacing = 7
        voiceColumn.backgroundColor = Palette.surface
        voiceColumn.layer.cornerRadius = 16
        voiceColumn.layer.borderWidth = 1
        voiceColumn.layer.borderColor = Palette.border.cgColor
        voiceColumn.isLayoutMarginsRelativeArrangement = true
        voiceColumn.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        voiceColumn.widthAnchor.constraint(equalToConstant: 98).isActive = true

        sessionBadgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        sessionBadgeLabel.textAlignment = .center
        sessionBadgeLabel.numberOfLines = 1
        sessionBadgeLabel.adjustsFontSizeToFitWidth = true
        sessionBadgeLabel.minimumScaleFactor = 0.7
        sessionBadgeLabel.isHidden = true
        sessionBadgeLabel.heightAnchor.constraint(equalToConstant: 14).isActive = true
        voiceColumn.addArrangedSubview(sessionBadgeLabel)

        statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.numberOfLines = 2
        statusLabel.textAlignment = .center
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.68
        statusLabel.heightAnchor.constraint(equalToConstant: 30).isActive = true
        voiceColumn.addArrangedSubview(statusLabel)

        recordButton.heightAnchor.constraint(equalToConstant: 58).isActive = true
        recordButton.widthAnchor.constraint(equalToConstant: 82).isActive = true
        recordButton.addTarget(self, action: #selector(recordTouchDown), for: .touchDown)
        recordButton.addTarget(self, action: #selector(recordTouchEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        let recordWrap = UIView()
        recordWrap.addSubview(recordButton)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recordButton.centerXAnchor.constraint(equalTo: recordWrap.centerXAnchor),
            recordButton.topAnchor.constraint(equalTo: recordWrap.topAnchor),
            recordButton.bottomAnchor.constraint(equalTo: recordWrap.bottomAnchor),
        ])
        voiceColumn.addArrangedSubview(recordWrap)

        let toolRow = UIStackView()
        toolRow.axis = .horizontal
        toolRow.distribution = .fillEqually
        toolRow.spacing = 5
        toolRow.heightAnchor.constraint(equalToConstant: 26).isActive = true
        // 麦克风语音列工具行:只保留「极速 / 还原」两钮(单手已迁至底部提示行),
        // 两钮等分 82pt 内容宽,俄语文案不再被三等分挤压
        configurePill(fastModeButton, title: "", width: nil, action: #selector(fastModeTapped))
        configurePill(restoreButton, title: "", width: nil, action: #selector(restoreTapped))
        toolRow.addArrangedSubview(fastModeButton)
        toolRow.addArrangedSubview(restoreButton)
        voiceColumn.addArrangedSubview(toolRow)
    }

    private func setupSymbolPanel() {
        symbolPanel.axis = .vertical
        symbolPanel.alignment = .fill
        symbolPanel.spacing = 6
        symbolPanel.isHidden = true
        rootStack.addArrangedSubview(symbolPanel)
        // 固定面板高度(与人设面板一致),符号网格 gridScroll 撑满剩余高度,避免只显示半屏
        symbolPanel.heightAnchor.constraint(equalToConstant: panelContentHeight).isActive = true
        rebuildSymbolPanel()
    }

    private func setupPersonaPanel() {
        personaPanel.axis = .vertical
        personaPanel.alignment = .fill
        personaPanel.spacing = 7
        personaPanel.isHidden = true
        rootStack.addArrangedSubview(personaPanel)
        personaPanel.heightAnchor.constraint(equalToConstant: panelContentHeight).isActive = true
        rebuildPersonaPanel()
    }

    private func configurePill(
        _ button: UIButton,
        title: String,
        width: CGFloat?,
        action: Selector,
        strong: Bool = false
    ) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .capsule
        config.baseForegroundColor = strong ? UIColor.white : Palette.accentDeep
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5)
        config.titleTextAttributesTransformer = Self.textAttributes(size: 11, weight: .semibold)
        button.configuration = config
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.55
        button.addTarget(self, action: action, for: .touchUpInside)
        // 3D 键帽质感:填充/描边/投影由键帽层承担(含按压反馈)
        button.applyKeycapStyle(accent: strong, corner: .capsule)
        if let width {
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func configureIcon(_ button: UIButton, icon: String, width: CGFloat, action: Selector) {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: icon)
        config.cornerStyle = .capsule
        config.baseForegroundColor = Palette.accentDeep
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
        button.applyKeycapStyle(corner: .capsule)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        header.addArrangedSubview(button)
    }

    private static func textAttributes(size: CGFloat, weight: UIFont.Weight) -> UIConfigurationTextAttributesTransformer {
        UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: size, weight: weight)
            return outgoing
        }
    }

    // MARK: - Rendering

    private func refreshStaticLabels() {
        brandLabel.text = MobileStrings.keyboardTitle()
        personaButton.configuration?.title = MobileStrings.persona()
        symbolButton.configuration?.title = MobileStrings.symbols()
        handButton.configuration?.title = rightHandLayout ? MobileStrings.rightHand() : MobileStrings.leftHand()
        fastModeButton.configuration?.title = fastModeTitle()
        restoreButton.configuration?.title = MobileStrings.restoreVoice()
        switchKeyboardButton.configuration?.title = MobileStrings.switchKeyboard()
        openAppButton.configuration?.title = MobileStrings.openApp()
        commandHintLabel.text = MobileStrings.commandHint()
    }

    private func setStatus(_ text: String, color: UIColor) {
        statusLabel.text = text
        statusLabel.textColor = color
    }

    private func setRecord(enabled: Bool, recording: Bool, processing: Bool) {
        recordButton.setState(enabled: enabled, recording: recording, processing: processing)
        recordButton.isEnabled = enabled
    }

    private func updateActionAvailability(canRewrite: Bool, canUndo: Bool, canRestore: Bool, utilityEnabled: Bool = true) {
        rewriteButton.isEnabled = canRewrite
        rewriteButton.alpha = canRewrite ? 1 : 0.35
        undoButton.isEnabled = canUndo
        undoButton.alpha = canUndo ? 1 : 0.35
        restoreButton.isEnabled = canRestore
        restoreButton.alpha = canRestore ? 1 : 0.35
        newlineButton.isEnabled = utilityEnabled
        newlineButton.alpha = utilityEnabled ? 1 : 0.35
        backspaceButton.isEnabled = utilityEnabled
        backspaceButton.alpha = utilityEnabled ? 1 : 0.35
    }

    private func fastModeTitle() -> String {
        // 只显示「极速」,开关状态改由高亮键帽表达(见 setFastMode)
        MobileStrings.fastMode()
    }

    private func showVoicePanel() {
        voicePanel.isHidden = false
        symbolPanel.isHidden = true
        personaPanel.isHidden = true
    }

    /// 子面板切换轻过渡(crossDissolve 0.18s)。仅用于用户点击的面板切换,
    /// 状态机驱动的 showVoicePanel 保持硬切,避免频繁状态刷新引起闪烁。
    private func animatePanelSwitch(_ changes: @escaping () -> Void) {
        UIView.transition(
            with: rootStack,
            duration: KeyboardMetrics.panelTransitionDuration,
            options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: changes
        )
    }

    private func applyHandLayout() {
        contentRow.arrangedSubviews.forEach { contentRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        if rightHandLayout {
            contentRow.addArrangedSubview(actionColumn)
            contentRow.addArrangedSubview(voiceColumn)
        } else {
            contentRow.addArrangedSubview(voiceColumn)
            contentRow.addArrangedSubview(actionColumn)
        }
    }

    private func rebuildShortcutRows() {
        guard
            let primaryRow = actionColumn.arrangedSubviews.first(where: { $0.tag == 901 }) as? UIStackView,
            let quickTop = actionColumn.arrangedSubviews.first(where: { $0.tag == 902 }) as? UIStackView,
            let quickBottom = actionColumn.arrangedSubviews.first(where: { $0.tag == 903 }) as? UIStackView
        else { return }

        [primaryRow, quickTop, quickBottom].forEach { row in
            row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        }

        let primary: [(String, Selector, UIButton)] = [
            (MobileStrings.newline(), #selector(newlineTapped), newlineButton),
            (MobileStrings.undo(), #selector(undoTapped), undoButton),
            (MobileStrings.rewrite(), #selector(rewriteTapped), rewriteButton),
        ]
        for (title, selector, button) in mirrored(primary) {
            configureRowButton(button, title: title, action: selector, strong: button === rewriteButton)
            primaryRow.addArrangedSubview(button)
        }

        let top: [(String, ShortcutAction)] = [
            (MobileStrings.quickFormat(), .quick(.format)),
            (MobileStrings.quickPolish(), .quick(.polish)),
        ]
        let bottom: [(String, ShortcutAction)] = [
            (MobileStrings.quickConcise(), .quick(.concise)),
            (MobileStrings.clearInput(), .clearInput),
        ]
        for item in mirrored(top) { quickTop.addArrangedSubview(quickActionButton(title: item.0, action: item.1)) }
        for item in mirrored(bottom) { quickBottom.addArrangedSubview(quickActionButton(title: item.0, action: item.1)) }
    }

    private func mirrored<T>(_ items: [T]) -> [T] {
        rightHandLayout ? items : items.reversed()
    }

    private func configureRowButton(_ button: UIButton, title: String, action: Selector, strong: Bool = false) {
        button.removeTarget(nil, action: nil, for: .allEvents)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .fixed
        config.background.cornerRadius = KeyboardMetrics.keycapRectCornerRadius
        config.baseForegroundColor = strong ? UIColor.white : Palette.accentDeep
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)
        config.titleTextAttributesTransformer = Self.textAttributes(size: 12, weight: .semibold)
        button.configuration = config
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.58
        button.addTarget(self, action: action, for: .touchUpInside)
        // 强调态(改写)与回车键同源 enter 渐变,其余功能键 func 渐变
        button.applyKeycapStyle(accent: strong, corner: .rounded(KeyboardMetrics.keycapRectCornerRadius))
    }

    private func quickActionButton(title: String, action: ShortcutAction) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .fixed
        config.background.cornerRadius = KeyboardMetrics.keycapRectCornerRadius
        config.baseForegroundColor = Palette.accentDeep
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)
        config.titleTextAttributesTransformer = Self.textAttributes(size: 12, weight: .semibold)
        button.configuration = config
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.58
        button.applyKeycapStyle(corner: .rounded(KeyboardMetrics.keycapRectCornerRadius))
        button.addAction(UIAction { [weak self] _ in
            switch action {
            case .quick(let quickAction):
                self?.delegate?.voiceKeyboardDidTapQuickAction(quickAction)
            case .clearInput:
                self?.delegate?.voiceKeyboardDidTapClearInput()
            }
        }, for: .touchUpInside)
        return button
    }

    /// 语音模式符号面板当前分类(与键盘模式符号板共用 SymbolData 数据与最近使用存储)。
    private var voiceSymbolCategory = SymbolData.recentID
    private let symbolPrefs = TypingPreferences()

    private func rebuildSymbolPanel() {
        symbolPanel.arrangedSubviews.forEach { symbolPanel.removeArrangedSubview($0); $0.removeFromSuperview() }
        let recents = symbolPrefs.recentSymbols()
        if voiceSymbolCategory == SymbolData.recentID && recents.isEmpty { voiceSymbolCategory = "zh" }
        let uiLang = MobileStrings.language.rawValue

        // 头部:返回 + 标题
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 6
        headerRow.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let back = panelBackButton(action: #selector(symbolBackTapped))
        headerRow.addArrangedSubview(back)

        let title = UILabel()
        title.text = MobileStrings.symbols()
        title.textColor = Palette.accentDeep
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textAlignment = .center
        headerRow.addArrangedSubview(title)
        // 右侧占位平衡返回钮宽度,保持标题居中
        let spacer = UIView()
        spacer.widthAnchor.constraint(equalToConstant: 50).isActive = true
        headerRow.addArrangedSubview(spacer)
        symbolPanel.addArrangedSubview(headerRow)

        // 分类标签行(横向滚动):最近 + 全部分类
        let catStack = UIStackView()
        catStack.axis = .horizontal
        catStack.spacing = 4
        let catIds = [SymbolData.recentID] + SymbolData.categories.map { $0.id }
        for id in catIds {
            let active = id == voiceSymbolCategory
            let b = UIButton(type: .system)
            b.setTitle(SymbolData.label(id, lang: uiLang), for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            b.setTitleColor(active ? .white : Palette.accentDeep, for: .normal)
            b.backgroundColor = active ? Palette.accent : Palette.button
            b.layer.cornerRadius = 13
            if !active {
                b.layer.borderWidth = 1
                b.layer.borderColor = Palette.border.cgColor
            }
            b.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
            b.addAction(UIAction { [weak self] _ in
                self?.voiceSymbolCategory = id
                self?.rebuildSymbolPanel()
            }, for: .touchUpInside)
            catStack.addArrangedSubview(b)
        }
        let catScroll = UIScrollView()
        catScroll.showsHorizontalScrollIndicator = false
        catStack.translatesAutoresizingMaskIntoConstraints = false
        catScroll.addSubview(catStack)
        NSLayoutConstraint.activate([
            catStack.topAnchor.constraint(equalTo: catScroll.topAnchor),
            catStack.bottomAnchor.constraint(equalTo: catScroll.bottomAnchor),
            catStack.leadingAnchor.constraint(equalTo: catScroll.leadingAnchor, constant: 2),
            catStack.trailingAnchor.constraint(equalTo: catScroll.trailingAnchor),
            catStack.heightAnchor.constraint(equalTo: catScroll.heightAnchor),
        ])
        catScroll.heightAnchor.constraint(equalToConstant: 30).isActive = true
        symbolPanel.addArrangedSubview(catScroll)

        // 符号网格(固定高,纵向滚动,不加高面板)
        let items = voiceSymbolCategory == SymbolData.recentID
            ? recents
            : (SymbolData.categories.first { $0.id == voiceSymbolCategory }?.items ?? [])
        let gridStack = UIStackView()
        gridStack.axis = .vertical
        gridStack.spacing = 4
        for rowSymbols in items.chunked(into: 8) {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .center
            row.distribution = .fillEqually
            row.spacing = 4
            row.heightAnchor.constraint(equalToConstant: 36).isActive = true
            rowSymbols.forEach { symbol in
                let b = UIButton(type: .system)
                configureLooseSymbolButton(b, title: symbol)
                b.addAction(UIAction { [weak self] _ in
                    self?.delegate?.voiceKeyboardDidTapSymbol(symbol)
                    self?.symbolPrefs.recordRecentSymbol(symbol)
                }, for: .touchUpInside)
                row.addArrangedSubview(b)
            }
            // 尾行补齐,保持等宽
            if rowSymbols.count < 8 {
                for _ in rowSymbols.count..<8 { row.addArrangedSubview(UIView()) }
            }
            gridStack.addArrangedSubview(row)
        }
        let gridScroll = UIScrollView()
        gridScroll.showsVerticalScrollIndicator = false
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.addSubview(gridStack)
        NSLayoutConstraint.activate([
            gridStack.topAnchor.constraint(equalTo: gridScroll.topAnchor),
            gridStack.bottomAnchor.constraint(equalTo: gridScroll.bottomAnchor),
            gridStack.leadingAnchor.constraint(equalTo: gridScroll.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: gridScroll.trailingAnchor),
            gridStack.widthAnchor.constraint(equalTo: gridScroll.widthAnchor),
        ])
        gridScroll.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        symbolPanel.addArrangedSubview(gridScroll)
    }

    private func configureLooseSymbolButton(_ button: UIButton, title: String) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .capsule
        config.baseForegroundColor = Palette.accentDeep
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        config.titleTextAttributesTransformer = Self.textAttributes(size: 12, weight: .semibold)
        button.configuration = config
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.62
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.applyKeycapStyle(corner: .capsule)
    }

    private func panelBackButton(action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = MobileStrings.back()
        config.image = UIImage(systemName: "chevron.left")
        config.imagePadding = 2
        config.imagePlacement = .leading
        config.cornerStyle = .capsule
        config.baseForegroundColor = Palette.accentDeep
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 8)
        config.titleTextAttributesTransformer = Self.textAttributes(size: 12, weight: .semibold)
        button.configuration = config
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.62
        button.widthAnchor.constraint(equalToConstant: 68).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.applyKeycapStyle(corner: .capsule)
        return button
    }

    private func rebuildPersonaPanel() {
        personaPanel.arrangedSubviews.forEach { personaPanel.removeArrangedSubview($0); $0.removeFromSuperview() }

        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 6
        headerRow.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let back = panelBackButton(action: #selector(personaBackTapped))
        headerRow.addArrangedSubview(back)

        let title = UILabel()
        title.text = selectedPersona()?.name ?? MobileStrings.persona()
        title.textColor = Palette.accentDeep
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7
        headerRow.addArrangedSubview(title)

        let reload = UIButton(type: .system)
        configureLooseSymbolButton(reload, title: personasRefreshing ? MobileStrings.processingShort() : MobileStrings.refresh())
        reload.widthAnchor.constraint(equalToConstant: 58).isActive = true
        reload.alpha = personasRefreshing ? 0.55 : 1
        reload.isEnabled = !personasRefreshing
        reload.addTarget(self, action: #selector(personaRefreshTapped), for: .touchUpInside)
        headerRow.addArrangedSubview(reload)
        personaPanel.addArrangedSubview(headerRow)

        let hint = UILabel()
        hint.text = selectedPersonaID == nil ? MobileStrings.personaHint() : MobileStrings.personaModuleHint()
        hint.textColor = Palette.muted
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.adjustsFontSizeToFitWidth = true
        hint.minimumScaleFactor = 0.7
        hint.heightAnchor.constraint(equalToConstant: 22).isActive = true
        personaPanel.addArrangedSubview(hint)

        if personasLoading {
            personaPanel.addArrangedSubview(centerLabel(MobileStrings.processingShort()))
            return
        }

        if let persona = selectedPersona() {
            personaPanel.addArrangedSubview(personaDetailView(persona))
        } else {
            personaPanel.addArrangedSubview(personaListView())
        }
    }

    private func selectedPersona() -> KeyboardPersona? {
        guard let selectedPersonaID else { return nil }
        return currentPersonas.first(where: { $0.id == selectedPersonaID })
    }

    private func personaListView() -> UIView {
        guard !currentPersonas.isEmpty else {
            return centerLabel(MobileStrings.personaEmpty())
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        currentPersonas.forEach { stack.addArrangedSubview(personaRow($0)) }
        return scroll
    }

    private func personaRow(_ persona: KeyboardPersona) -> UIView {
        let row = UIControl()
        row.backgroundColor = persona.isActive ? Palette.buttonStrong : Palette.button
        row.layer.cornerRadius = 12
        row.heightAnchor.constraint(equalToConstant: 48).isActive = true
        if !persona.isBuiltin {
            row.addAction(UIAction { [weak self] _ in
                self?.selectedPersonaID = persona.id
                self?.rebuildPersonaPanel()
            }, for: .touchUpInside)
        }

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
        ])

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 2
        let name = UILabel()
        name.text = persona.name
        name.textColor = persona.isActive ? Palette.accentDeep : Palette.text
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.7
        let desc = UILabel()
        desc.text = persona.description?.isEmpty == false
            ? persona.description
            : (persona.isBuiltin ? "" : moduleSummary(persona.prompts))
        desc.textColor = Palette.muted
        desc.font = .systemFont(ofSize: 10, weight: .regular)
        desc.adjustsFontSizeToFitWidth = true
        desc.minimumScaleFactor = 0.65
        textStack.addArrangedSubview(name)
        textStack.addArrangedSubview(desc)
        stack.addArrangedSubview(textStack)

        let action = personaActionButton(persona)
        stack.addArrangedSubview(action)
        return row
    }

    private func personaDetailView(_ persona: KeyboardPersona) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 7
        if let description = persona.description, !description.isEmpty {
            let label = UILabel()
            label.text = description
            label.textColor = Palette.muted
            label.font = .systemFont(ofSize: 11)
            label.numberOfLines = 2
            stack.addArrangedSubview(label)
        }
        stack.addArrangedSubview(moduleRow(persona: persona, module: .transcribe))
        stack.addArrangedSubview(moduleRow(persona: persona, module: .rewrite))
        let action = personaActionButton(persona)
        action.heightAnchor.constraint(equalToConstant: 38).isActive = true
        stack.addArrangedSubview(action)
        return stack
    }

    private func personaActionButton(_ persona: KeyboardPersona) -> UIButton {
        let isPending = pendingPersonaID == persona.id
        let button = UIButton(type: .system)
        configureLooseSymbolButton(
            button,
            title: isPending ? MobileStrings.processingShort() : (persona.isActive ? MobileStrings.disable() : MobileStrings.enable())
        )
        button.widthAnchor.constraint(equalToConstant: 66).isActive = true
        button.isEnabled = pendingPersonaID == nil
        button.alpha = pendingPersonaID == nil || isPending ? 1 : 0.55
        button.addAction(UIAction { [weak self] _ in
            if persona.isActive {
                self?.delegate?.voiceKeyboardDidDeactivatePersonas()
            } else {
                self?.delegate?.voiceKeyboardDidActivatePersona(persona)
            }
        }, for: .touchUpInside)
        return button
    }

    private func moduleRow(persona: KeyboardPersona, module: KeyboardPersonaModule) -> UIView {
        let title = module == .transcribe ? MobileStrings.personaTranscribe() : MobileStrings.personaRewrite()
        let prompt = module == .transcribe ? persona.prompts.transcribePrompt : persona.prompts.rewritePrompt
        let enabled = module == .transcribe ? persona.prompts.transcribeEnabled : persona.prompts.rewriteEnabled
        let hasPrompt = !(prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let row = UIControl()
        row.backgroundColor = enabled ? Palette.buttonStrong : Palette.button
        row.layer.cornerRadius = 12
        row.alpha = hasPrompt ? 1 : 0.48
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        if hasPrompt && pendingPersonaID == nil {
            row.addAction(UIAction { [weak self] _ in
                self?.delegate?.voiceKeyboardDidTogglePersonaModule(persona, module: module)
            }, for: .touchUpInside)
        }

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        let label = UILabel()
        label.text = title
        label.textColor = enabled ? Palette.accentDeep : Palette.text
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(label)

        let state = UILabel()
        state.text = enabled ? MobileStrings.active() : (hasPrompt ? MobileStrings.inactive() : MobileStrings.builtin())
        state.textColor = enabled ? UIColor.white : Palette.muted
        state.font = .systemFont(ofSize: 11, weight: .semibold)
        state.textAlignment = .center
        state.backgroundColor = enabled ? Palette.accent : Palette.surfaceMuted
        state.layer.cornerRadius = 14
        state.clipsToBounds = true
        state.widthAnchor.constraint(equalToConstant: 66).isActive = true
        state.heightAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(state)
        return row
    }

    private func moduleSummary(_ prompts: KeyboardPromptSettings) -> String {
        var enabled: [String] = []
        if prompts.transcribeEnabled { enabled.append(MobileStrings.personaTranscribe()) }
        if prompts.rewriteEnabled { enabled.append(MobileStrings.personaRewrite()) }
        return enabled.isEmpty ? MobileStrings.builtin() : enabled.joined(separator: " / ")
    }

    private func centerLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = Palette.muted
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textAlignment = .center
        return label
    }

    // MARK: - Actions

    @objc private func recordTapped() {
        guard !realtimeTouchEnabled else { return }
        delegate?.voiceKeyboardDidTapRecord()
    }

    @objc private func recordTouchDown() {
        guard realtimeTouchEnabled, !realtimeTouchActive else { return }
        realtimeTouchActive = true
        delegate?.voiceKeyboardDidBeginRealtimeRecord()
    }

    @objc private func recordTouchEnded() {
        guard realtimeTouchEnabled, realtimeTouchActive else { return }
        realtimeTouchActive = false
        delegate?.voiceKeyboardDidEndRealtimeRecord()
    }
    @objc private func rewriteTapped() { delegate?.voiceKeyboardDidTapRewrite() }
    @objc private func undoTapped() { delegate?.voiceKeyboardDidTapUndo() }
    @objc private func restoreTapped() { delegate?.voiceKeyboardDidTapRestore() }
    @objc private func backspaceTapped() { delegate?.voiceKeyboardDidTapBackspace() }
    @objc private func newlineTapped() { delegate?.voiceKeyboardDidTapNewline() }
    @objc private func atTapped() { delegate?.voiceKeyboardDidTapSymbol("@") }
    @objc private func globeTapped() { delegate?.voiceKeyboardDidTapNextKeyboard() }
    @objc private func dismissTapped() { delegate?.voiceKeyboardDidTapDismiss() }
    @objc private func openAppTapped() { delegate?.voiceKeyboardDidTapOpenApp() }

    @objc private func fastModeTapped() {
        fastModeEnabled.toggle()
        setFastMode(fastModeEnabled)
        delegate?.voiceKeyboardDidChangeFastMode(fastModeEnabled)
    }

    @objc private func handTapped() {
        rightHandLayout.toggle()
        setHandLayout(rightHand: rightHandLayout)
        delegate?.voiceKeyboardDidChangeHandLayout(rightHand: rightHandLayout)
    }

    @objc private func symbolTapped() {
        animatePanelSwitch { [self] in
            voicePanel.isHidden = true
            personaPanel.isHidden = true
            symbolPanel.isHidden = false
            // 每次进入符号面板默认「最近」,不记忆上次选中的分类
            voiceSymbolCategory = SymbolData.recentID
            rebuildSymbolPanel()
        }
    }

    @objc private func personaTapped() {
        animatePanelSwitch { [self] in
            voicePanel.isHidden = true
            symbolPanel.isHidden = true
            personaPanel.isHidden = false
            selectedPersonaID = nil
            rebuildPersonaPanel()
        }
        delegate?.voiceKeyboardDidRefreshPersonas()
    }

    @objc private func symbolBackTapped() {
        animatePanelSwitch { [self] in showVoicePanel() }
    }

    @objc private func personaBackTapped() {
        if selectedPersonaID != nil {
            selectedPersonaID = nil
            animatePanelSwitch { [self] in rebuildPersonaPanel() }
        } else {
            animatePanelSwitch { [self] in showVoicePanel() }
        }
    }

    @objc private func personaRefreshTapped() {
        delegate?.voiceKeyboardDidRefreshPersonas()
    }

    private func installBackspaceRepeat() {
        backspaceButton.addTarget(self, action: #selector(backspaceTouchDown), for: .touchDown)
        backspaceButton.addTarget(self, action: #selector(backspaceTouchEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func backspaceTouchDown() {
        backspaceLongPressFired = false
        backspaceTimer?.invalidate()
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.backspaceLongPressFired = true
            self?.startBackspaceRepeat()
        }
    }

    @objc private func backspaceTouchEnd() {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspaceLongPressFired = false
    }

    private func startBackspaceRepeat() {
        backspaceTimer?.invalidate()
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.058, repeats: true) { [weak self] _ in
            self?.delegate?.voiceKeyboardDidTapBackspace()
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

final class SymbolBackButton: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        VoiceKeyboardView.Palette.button.setFill()
        UIBezierPath(ovalIn: rect).fill()
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX + 7, y: rect.midY - 8))
        path.addLine(to: CGPoint(x: rect.midX - 5, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX + 7, y: rect.midY + 8))
        path.lineWidth = 2.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        VoiceKeyboardView.Palette.accentDeep.setStroke()
        path.stroke()
    }
}
