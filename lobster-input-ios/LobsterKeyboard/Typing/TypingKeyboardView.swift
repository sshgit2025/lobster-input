import UIKit

/// 按 weight 比例横向排列子键的行视图(UIStackView 不支持权重,故手动布局)。
private final class KeyRowView: UIView {
    private var items: [(view: UIView?, weight: CGFloat)] = []
    private let spacing: CGFloat
    init(spacing: CGFloat) { self.spacing = spacing; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    func addKey(_ v: UIView, weight: CGFloat) { addSubview(v); items.append((v, weight)) }
    func addGap(weight: CGFloat) { items.append((nil, weight)) }

    var firstKeyView: UIView? { items.first(where: { $0.view != nil })?.view }
    /// 隐藏/恢复最左键(选择器覆盖时用 alpha 保留占位,避免重排抖动)。
    func setFirstKeyHidden(_ hidden: Bool) { firstKeyView?.alpha = hidden ? 0 : 1 }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !items.isEmpty else { return }
        let totalSpacing = spacing * CGFloat(items.count - 1)
        let avail = max(0, bounds.width - totalSpacing)
        let totalWeight = items.reduce(0) { $0 + $1.weight }
        var x: CGFloat = 0
        for (v, w) in items {
            let width = totalWeight > 0 ? avail * (w / totalWeight) : 0
            v?.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + spacing
        }
    }
}

/// 打字键盘面板(视图容器层)。组装候选栏 + 键区 + 按键气泡,委托给 KeyboardController。
final class TypingKeyboardView: UIView, KeyboardRenderer, KeyViewDelegate, CandidateBarDelegate {

    private let sessionHost: TypingSessionHost
    private let micCoordinator: TypingMicCoordinator
    private let controller: KeyboardController
    private let layoutFactory: KeyboardLayoutFactory
    private let candidateBar: CandidateBarView
    private let keyboardArea = UIStackView()
    private let inputBlocker = UIView()
    private let bubble = UILabel()
    /// Sapphire 面板纵向渐变背景(与语音面板同款),frame 在 layoutSubviews 同步。
    private let backgroundGradient = CAGradientLayer()
    private let panelHeight: CGFloat = 258

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: panelHeight) }

    init(sessionHost: TypingSessionHost, micCoordinator: TypingMicCoordinator, engine: PinyinEngine) {
        self.sessionHost = sessionHost
        self.micCoordinator = micCoordinator
        self.controller = KeyboardController(host: sessionHost, engine: engine)
        self.layoutFactory = KeyboardLayoutFactory(host: sessionHost)
        self.candidateBar = CandidateBarView(delegate: DummyCandidateDelegate.shared)
        super.init(frame: .zero)
        setup()
        sessionHost.setStatusCallback { [weak self] msg in self?.candidateBar.showStatus(msg) }
        sessionHost.setInputBlockedCallback { [weak self] blocked in self?.setInputBlocked(blocked) }
        engine.addLoadListener { [weak sessionHost] state, detail in
            sessionHost?.notifyEngineState(state, detail: detail)
        }
        engine.loadAsync()
        controller.bind(self)
        rebuildKeyboard()
        controller.refreshCandidates()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // 纯色仅作 fallback,可见背景为纵向渐变(与语音面板一致)
        backgroundColor = LobsterWaterPalette.panel
        backgroundGradient.colors = [LobsterWaterPalette.panelTop.cgColor, LobsterWaterPalette.panelBottom.cgColor]
        backgroundGradient.startPoint = CGPoint(x: 0.5, y: 0)
        backgroundGradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.insertSublayer(backgroundGradient, at: 0)
        candidateBar.delegate = self
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(candidateBar)

        keyboardArea.axis = .vertical
        keyboardArea.distribution = .fillEqually
        keyboardArea.spacing = 5
        keyboardArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardArea)

        inputBlocker.backgroundColor = LobsterWaterPalette.surface.withAlphaComponent(0.35)
        inputBlocker.isHidden = true
        inputBlocker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputBlocker)

        NSLayoutConstraint.activate([
            candidateBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            candidateBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            candidateBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            keyboardArea.topAnchor.constraint(equalTo: candidateBar.bottomAnchor, constant: 2),
            keyboardArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            keyboardArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            keyboardArea.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            inputBlocker.leadingAnchor.constraint(equalTo: keyboardArea.leadingAnchor),
            inputBlocker.trailingAnchor.constraint(equalTo: keyboardArea.trailingAnchor),
            inputBlocker.topAnchor.constraint(equalTo: keyboardArea.topAnchor),
            inputBlocker.bottomAnchor.constraint(equalTo: keyboardArea.bottomAnchor),
        ])

        bubble.textAlignment = .center
        bubble.font = .systemFont(ofSize: 26, weight: .semibold)
        bubble.textColor = LobsterWaterPalette.text
        bubble.backgroundColor = LobsterWaterPalette.surface
        bubble.layer.cornerRadius = KeyboardMetrics.keyCornerRadius
        bubble.layer.borderWidth = 1
        bubble.layer.borderColor = LobsterWaterPalette.border.cgColor
        // 不裁剪以便投影可见(圆角对 backgroundColor/border 依然生效)
        bubble.layer.masksToBounds = false
        bubble.layer.shadowColor = LobsterWaterPalette.keyShadow.cgColor
        bubble.layer.shadowOpacity = 1
        bubble.layer.shadowRadius = 5
        bubble.layer.shadowOffset = CGSize(width: 0, height: 2)
        bubble.isHidden = true
        addSubview(bubble)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundGradient.frame = bounds
        CATransaction.commit()
    }

    func resetComposing() { controller.reset() }

    /// 键盘会话结束(键盘收起):清除会话级粘性(数字页/自动英文)。
    func onSessionEnd() { controller.onSessionEnd() }

    func refreshEnterKey() {
        sessionHost.refreshEditorAction()
        rebuildKeyboard()
    }

    func setInputBlocked(_ blocked: Bool) {
        controller.setInputBlocked(blocked)
        inputBlocker.isHidden = !blocked
    }

    func updateMicLevel(_ level: CGFloat) { candidateBar.updateLevel(level) }
    func setMicProgress(_ remaining: CGFloat) { candidateBar.setRecordProgress(remaining) }
    func stopMicRecordingUI() { candidateBar.setRecording(false) }

    // MARK: KeyboardRenderer
    func rebuildKeyboard() {
        keyboardArea.arrangedSubviews.forEach { $0.removeFromSuperview() }
        keyboardArea.distribution = .fillEqually
        if controller.isSymBoardPage() { buildSymbolBoard(); return }
        let rows = layoutFactory.build(controller.layoutState())
        for row in rows {
            let rowView = KeyRowView(spacing: 5)
            for spec in row {
                if spec.type == .gap { rowView.addGap(weight: spec.weight) }
                else { rowView.addKey(KeyView(spec: spec, delegate: self), weight: spec.weight) }
            }
            keyboardArea.addArrangedSubview(rowView)
        }
    }

    // MARK: 分类符号板(问题1)
    /// 左侧竖排分类标签(最近/中文/英文/括号/数学/序号/货币/箭头)+ 右侧滚动符号网格 + 底部返回/删除。
    /// 数据=SymbolData(与安卓一致,脚本验证);最近使用持久化于 App Group 偏好,语音模式共用。
    private var symBoardCategory = SymbolData.recentID

    /// 进入分类符号板时重置为「最近」,不记忆上次(含语音入口)选中的分类。
    func onEnterSymBoard() { symBoardCategory = SymbolData.recentID }

    private func buildSymbolBoard() {
        let cn = controller.isChineseMode()
        let uiLang = cn ? "zh" : "en"
        let recents = controller.recentSymbols()
        if symBoardCategory == SymbolData.recentID && recents.isEmpty { symBoardCategory = "zh" }

        let body = UIStackView()
        body.axis = .horizontal
        body.alignment = .fill
        body.spacing = 4

        // 左侧分类栏
        let catStack = UIStackView()
        catStack.axis = .vertical
        catStack.spacing = 4
        let catIds = [SymbolData.recentID] + SymbolData.categories.map { $0.id }
        for id in catIds {
            let active = id == symBoardCategory
            let b = UIButton(type: .system)
            b.setTitle(SymbolData.label(id, lang: uiLang), for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            b.setTitleColor(active ? .white : LobsterWaterPalette.accentDeep, for: .normal)
            b.backgroundColor = active ? LobsterWaterPalette.accent : LobsterWaterPalette.button
            b.layer.cornerRadius = 8
            if !active {
                b.layer.borderWidth = 1
                b.layer.borderColor = LobsterWaterPalette.border.cgColor
            }
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            b.addAction(UIAction { [weak self] _ in
                self?.symBoardCategory = id
                self?.rebuildKeyboard()
            }, for: .touchUpInside)
            catStack.addArrangedSubview(b)
        }
        let catScroll = UIScrollView()
        catScroll.showsVerticalScrollIndicator = false
        catStack.translatesAutoresizingMaskIntoConstraints = false
        catScroll.addSubview(catStack)
        NSLayoutConstraint.activate([
            catStack.topAnchor.constraint(equalTo: catScroll.topAnchor),
            catStack.bottomAnchor.constraint(equalTo: catScroll.bottomAnchor),
            catStack.leadingAnchor.constraint(equalTo: catScroll.leadingAnchor),
            catStack.trailingAnchor.constraint(equalTo: catScroll.trailingAnchor),
            catStack.widthAnchor.constraint(equalTo: catScroll.widthAnchor),
        ])
        catScroll.widthAnchor.constraint(equalToConstant: 62).isActive = true
        body.addArrangedSubview(catScroll)

        // 右侧符号网格
        let items = symBoardCategory == SymbolData.recentID
            ? recents
            : (SymbolData.categories.first { $0.id == symBoardCategory }?.items ?? [])
        let cols = 7
        let gridStack = UIStackView()
        gridStack.axis = .vertical
        gridStack.spacing = 4
        var i = 0
        while i < items.count {
            let rowItems = Array(items[i..<min(i + cols, items.count)])
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 4
            for s in rowItems {
                let b = UIButton(type: .system)
                b.setTitle(s, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 18, weight: .regular)
                b.setTitleColor(LobsterWaterPalette.text, for: .normal)
                b.heightAnchor.constraint(equalToConstant: 38).isActive = true
                b.applyKeycapStyle(corner: .rounded(8))
                b.addAction(UIAction { [weak self] _ in self?.controller.selectSymbol(s) }, for: .touchUpInside)
                row.addArrangedSubview(b)
            }
            // 尾行补齐,保证格子等宽
            if rowItems.count < cols {
                for _ in rowItems.count..<cols { row.addArrangedSubview(UIView()) }
            }
            gridStack.addArrangedSubview(row)
            i += cols
        }
        let gridScroll = UIScrollView()
        gridScroll.showsVerticalScrollIndicator = true
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.addSubview(gridStack)
        NSLayoutConstraint.activate([
            gridStack.topAnchor.constraint(equalTo: gridScroll.topAnchor),
            gridStack.bottomAnchor.constraint(equalTo: gridScroll.bottomAnchor),
            gridStack.leadingAnchor.constraint(equalTo: gridScroll.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: gridScroll.trailingAnchor),
            gridStack.widthAnchor.constraint(equalTo: gridScroll.widthAnchor),
        ])
        body.addArrangedSubview(gridScroll)
        keyboardArea.addArrangedSubview(body)

        // 底部返回/删除
        let footer = UIStackView()
        footer.axis = .horizontal
        footer.spacing = 6
        let back = UIButton(type: .system)
        back.setTitle(MobileStrings.back(), for: .normal)
        back.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        back.setTitleColor(LobsterWaterPalette.accentDeep, for: .normal)
        back.applyKeycapStyle(corner: .rounded(10))
        back.addAction(UIAction { [weak self] _ in
            self?.controller.handleKey(TypingKeySpec(type: .alpha))
        }, for: .touchUpInside)
        let del = UIButton(type: .system)
        del.setImage(UIImage(systemName: "delete.left"), for: .normal)
        del.tintColor = LobsterWaterPalette.text
        del.applyKeycapStyle(corner: .rounded(10))
        del.addAction(UIAction { [weak self] _ in
            self?.controller.handleKey(TypingKeySpec(type: .delete))
        }, for: .touchUpInside)
        footer.addArrangedSubview(back)
        footer.addArrangedSubview(UIView())
        footer.addArrangedSubview(del)
        back.widthAnchor.constraint(equalToConstant: 90).isActive = true
        del.widthAnchor.constraint(equalToConstant: 90).isActive = true
        footer.heightAnchor.constraint(equalToConstant: 40).isActive = true
        keyboardArea.addArrangedSubview(footer)
        // body 吃满剩余高度(keyboardArea 是 fillEqually 的纵向 stack,改为按内容分配)
        keyboardArea.distribution = .fill
    }

    func renderCandidates(composingDisplay: String, candidates: [PinyinCandidate], layoutLabel: String, numbered: Bool) {
        candidateBar.render(composingDisplay: composingDisplay, candidates: candidates, layoutLabel: layoutLabel, numbered: numbered)
    }

    func renderPinyinOptions(_ options: [String]) { /* 已改用左侧竖排 renderPinyinSelector */ }

    private var pinyinSelector: UIScrollView?
    private var pinyinSelectorStack: UIStackView?

    private func setLeftColumnHidden(_ hidden: Bool) {
        for case let row as KeyRowView in keyboardArea.arrangedSubviews { row.setFirstKeyHidden(hidden) }
    }

    /// 左侧竖排拼音选择器:覆盖键区最左一列(输入态,搜狗式)。每项固定高度,超出可上下滑动(无滚动条)。
    func renderPinyinSelector(_ options: [String], _ active: String) {
        if options.isEmpty { pinyinSelector?.isHidden = true; setLeftColumnHidden(false); return }
        layoutIfNeeded()
        guard let firstRow = keyboardArea.arrangedSubviews.first as? KeyRowView,
              let firstKey = firstRow.firstKeyView, firstKey.bounds.width > 0 else {
            pinyinSelector?.isHidden = true; setLeftColumnHidden(false); return
        }
        let keyFrame = firstKey.convert(firstKey.bounds, to: self)
        let areaFrame = keyboardArea.convert(keyboardArea.bounds, to: self)
        let sv: UIScrollView = pinyinSelector ?? {
            let s = UIScrollView(); s.showsVerticalScrollIndicator = false
            s.backgroundColor = .clear // 透出面板渐变,被覆盖列已用 alpha 隐藏
            let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 2
            s.addSubview(stack); pinyinSelectorStack = stack; pinyinSelector = s
            addSubview(s)
            return s
        }()
        sv.isHidden = false
        sv.frame = CGRect(x: keyFrame.minX, y: areaFrame.minY, width: keyFrame.width, height: areaFrame.height)
        setLeftColumnHidden(true)
        guard let stack = pinyinSelectorStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for opt in options { stack.addArrangedSubview(selectorCell(opt, opt == active)) }
        let h = CGFloat(options.count) * 44
        stack.frame = CGRect(x: 0, y: 0, width: keyFrame.width, height: h)
        sv.contentSize = CGSize(width: keyFrame.width, height: h)
    }

    private func selectorCell(_ text: String, _ active: Bool) -> UIView {
        let b = UIButton(type: .system)
        b.setTitle(text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: text.count > 3 ? 11 : 13, weight: .semibold)
        b.setTitleColor(active ? .white : LobsterWaterPalette.accentDeep, for: .normal)
        // 激活态 accent 白字;未激活玻璃填充 + 柔描边
        b.backgroundColor = active ? LobsterWaterPalette.accent : LobsterWaterPalette.button
        b.layer.cornerRadius = KeyboardMetrics.keyCornerRadius
        if !active {
            b.layer.borderWidth = 1
            b.layer.borderColor = LobsterWaterPalette.accentSoft.withAlphaComponent(0.6).cgColor
        }
        b.heightAnchor.constraint(equalToConstant: 42).isActive = true
        b.addAction(UIAction { [weak self] _ in self?.controller.selectT9Pinyin(text) }, for: .touchUpInside)
        SapphirePressFeedback.install(on: b)
        return b
    }

    func invalidateKeys() {
        func walk(_ view: UIView) {
            if let key = view as? KeyView { key.applyAppearance() }
            view.subviews.forEach(walk)
        }
        keyboardArea.arrangedSubviews.forEach(walk)
    }

    // MARK: KeyViewDelegate
    func keyShiftActive() -> Bool { controller.isShiftActive() }
    func keyCapsLock() -> Bool { controller.isCapsLock() }
    func keyMicActive() -> Bool { false }
    func keyChineseMode() -> Bool { controller.isChineseMode() }
    func keyTapped(_ spec: TypingKeySpec) { controller.handleKey(spec) }
    func keyLongPress(_ spec: TypingKeySpec) { controller.handleLongPress(spec) }
    func keyDeletePressDown() { controller.onDeletePressDown() }
    func keyDeletePressUp() { controller.onDeletePressUp() }

    func keyShowBubble(_ view: KeyView, text: String) {
        let f = view.convert(view.bounds, to: self)
        let w: CGFloat = 46, h: CGFloat = 52
        var x = f.midX - w / 2
        x = max(0, min(x, bounds.width - w))
        let y = max(0, f.minY - h - 2)
        bubble.frame = CGRect(x: x, y: y, width: w, height: h)
        bubble.text = text
        bubble.isHidden = false
    }

    func keyHideBubble() { bubble.isHidden = true }

    // MARK: CandidateBarDelegate
    func candidateSelected(_ candidate: PinyinCandidate) { controller.selectCandidate(candidate) }
    func returnToVoiceTapped() { controller.returnToVoice() }
    func toggleLayoutTapped() { controller.toggleLayout() }
    func micRecordStart() { micCoordinator.onRecordStart() }
    func micRecordEnd() { micCoordinator.onRecordEnd() }
    func micRecordCancel() { micCoordinator.onRecordEnd() }
    func returnVoiceText() -> String { controller.returnVoiceText() }
    func layoutSwitchText() -> String { controller.layoutSwitchText() }
    func expandCandidatesTapped() { candidateBar.nextCandidatePage() }
    func pinyinOptionSelected(_ pinyin: String) { controller.selectT9Pinyin(pinyin) }
}

private final class DummyCandidateDelegate: CandidateBarDelegate {
    static let shared = DummyCandidateDelegate()
    func candidateSelected(_ candidate: PinyinCandidate) {}
    func returnToVoiceTapped() {}
    func toggleLayoutTapped() {}
    func micRecordStart() {}
    func micRecordEnd() {}
    func micRecordCancel() {}
    func returnVoiceText() -> String { "" }
    func layoutSwitchText() -> String { "" }
    func expandCandidatesTapped() {}
    func pinyinOptionSelected(_ pinyin: String) {}
}
