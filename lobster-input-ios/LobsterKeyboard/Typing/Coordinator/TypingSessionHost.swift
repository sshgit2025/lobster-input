import UIKit

/// [TypingKeyboardHost] 实现:上屏、组合预览、Enter 动作、撤销、本地化。
final class TypingSessionHost: TypingKeyboardHost {

    /// weak 而非 unowned:连删 Timer 等异步回调可能在键盘 VC 销毁后的间隙触达这里,
    /// unowned 会直接 abort(真机已复现闪退);weak + 优雅降级为 no-op 才安全。
    private weak var ime: TypingImeContext?
    private let preferences: TypingPreferences
    private let composingBridge: ComposingTextBridge
    private let undoManager: TypingUndoManager
    private var editorAction: EditorActionModel = .default
    private var statusCallback: ((String?) -> Void)?
    private var inputBlockedCallback: ((Bool) -> Void)?

    init(
        ime: TypingImeContext,
        preferences: TypingPreferences,
        composingBridge: ComposingTextBridge,
        undoManager: TypingUndoManager
    ) {
        self.ime = ime
        self.preferences = preferences
        self.composingBridge = composingBridge
        self.undoManager = undoManager
        composingBridge.bind(
            proxyProvider: { [weak ime] in ime?.textDocumentProxy },
            micActiveProvider: { [weak ime] in ime?.isMicRecording() ?? false }
        )
    }

    func refreshEditorAction() {
        guard let ime else { return }
        editorAction = EditorActionModel.resolve(from: ime.textDocumentProxy)
    }

    func setStatusCallback(_ callback: @escaping (String?) -> Void) {
        statusCallback = callback
    }

    func setInputBlockedCallback(_ callback: @escaping (Bool) -> Void) {
        inputBlockedCallback = callback
    }

    func onCommit(_ text: String) {
        guard let ime else { return }
        composingBridge.clear()
        ime.textDocumentProxy.insertText(text)
        undoManager.record(text)
    }

    func onCommitPair(_ opening: String, _ closing: String) {
        guard let ime else { return }
        composingBridge.clear()
        let proxy = ime.textDocumentProxy
        proxy.insertText(opening + closing)
        proxy.adjustTextPosition(byCharacterOffset: -closing.count)
        undoManager.record(opening + closing)
    }

    /// 光标后是否还有文字(1 键符号候选的成套插入判定)。
    func hasTextAfterCursor() -> Bool {
        guard let ime else { return false }
        return !(ime.textDocumentProxy.documentContextAfterInput ?? "").isEmpty
    }

    /// 光标前 ≤maxChars 字符(标点联想 v2 句内上下文;documentContextBeforeInput 为 nil 时返回空)。
    func textBeforeCursor(_ maxChars: Int) -> String {
        guard let ime else { return "" }
        let ctx = ime.textDocumentProxy.documentContextBeforeInput ?? ""
        return String(ctx.suffix(maxChars))
    }

    func onDeleteBeforeCursor() {
        guard let ime else { return }
        let proxy = ime.textDocumentProxy
        if let sel = proxy.selectedText, !sel.isEmpty {
            proxy.insertText("")
        } else {
            proxy.deleteBackward()
        }
    }

    func onEnter() {
        guard let ime else { return }
        composingBridge.clear()
        let proxy = ime.textDocumentProxy
        switch editorAction.action {
        case .search, .send, .go, .done, .next, .previous:
            proxy.insertText("\n")
        case .newline:
            proxy.insertText("\n")
        }
    }

    func onReturnToVoice() { ime?.requestExitTypingMode() }

    func onKeyboardMicStart() { /* 由 TypingMicCoordinator 处理 */ }

    func onKeyboardMicStop() { /* 由 TypingMicCoordinator 处理 */ }

    func isChineseModeDefault() -> Bool { preferences.chineseMode }

    func persistChineseMode(_ chinese: Bool) { preferences.chineseMode = chinese }

    func inputLangDefault() -> InputLang { InputLang(rawValue: preferences.inputLang) ?? .zh }

    func persistInputLang(_ lang: InputLang) {
        preferences.inputLang = lang.rawValue
        // 中英偏好联动(向后兼容旧逻辑读取点);俄/韩不动 chineseMode
        if lang == .zh || lang == .en { preferences.chineseMode = lang == .zh }
    }

    /// App 界面语言 → 语言组(中英组含粤语/繁体)与组默认输入语种。
    private func appLangGroup() -> (String, InputLang) {
        switch MobileStrings.language {
        case .ru: return ("ru", .ru)
        case .ko: return ("ko", .ko)
        case .en: return ("zhen", .en)
        default: return ("zhen", .zh) // zh / zh-Hant / yue 均属中文
        }
    }

    func groupDefaultLang() -> InputLang { appLangGroup().1 }

    func consumeLangGroupChange() -> Bool {
        let (group, def) = appLangGroup()
        let last = preferences.langGroup
        preferences.langGroup = group
        // 首次(无记录):中英组不算切换;俄/韩界面首启也要落到对应语种键盘
        if last == nil && group != "zhen" {
            preferences.inputLang = def.rawValue
            return true
        }
        // 组内互切(中英互换界面语言)不清暂存
        if last == nil || last == group { return false }
        // 跨组切换:清空暂存、恢复初始化——输入语种重置为新组默认,中英偏好同步对齐
        preferences.inputLang = def.rawValue
        if def == .zh || def == .en { preferences.chineseMode = def == .zh }
        return true
    }

    // 韩语组字预览:组合中音节写目标框 marked 区(setMarkedText,业界标准预览)
    func onComposingText(_ text: String) {
        ime?.textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.count, length: 0))
    }

    func onFinishComposing() {
        ime?.textDocumentProxy.unmarkText()
    }

    func recordRecentSymbol(_ symbol: String) { preferences.recordRecentSymbol(symbol) }

    func recentSymbols() -> [String] { preferences.recentSymbols() }

    func isNineGridDefault() -> Bool { preferences.nineGrid }

    func persistNineGrid(_ nine: Bool) { preferences.nineGrid = nine }

    func onKeyFeedback() { ime?.performKeyHaptic() }

    func localize(_ key: KbStrKey) -> String {
        switch key {
        case .returnVoice: return MobileStrings.returnVoice()
        case .space: return MobileStrings.spaceKey()
        case .ch: return MobileStrings.imeChineseLabel()
        case .en: return MobileStrings.imeEnglishLabel()
        case .ninegrid: return MobileStrings.nineGridLabel()
        case .qwerty: return MobileStrings.qwertyLabel()
        case .symbol: return MobileStrings.symbolKeyLabel()
        case .switchQwerty: return MobileStrings.switchQwertyLabel()
        case .pinyin: return MobileStrings.pinyinKeyLabel()
        case .abc: return MobileStrings.abcKeyLabel()
        case .syllable: return MobileStrings.syllableSepKey()
        case .undo: return MobileStrings.undo()
        }
    }

    func enterKeyLabel() -> String { editorAction.label }

    func isPasswordField() -> Bool { editorAction.isPassword }

    func isNumericField() -> Bool { editorAction.isNumeric }

    func isEnglishField() -> Bool { editorAction.isEnglish }

    func updateComposingPreview(_ text: String) { composingBridge.update(composingDisplay: text) }

    func clearComposingPreview() { composingBridge.clear() }

    func showStatus(_ message: String?) { statusCallback?(message) }

    func setInputBlocked(_ blocked: Bool) { inputBlockedCallback?(blocked) }

    func canUndo() -> Bool { undoManager.canUndo() }

    func undoLastCommit() {
        guard let ime, let last = undoManager.pop() else { return }
        for _ in last { ime.textDocumentProxy.deleteBackward() }
        // 不再弹"已撤销"状态提示:会让候选栏多一行、顶高输入面板
    }

    func notifyEngineState(_ state: PinyinLoadState, detail: String?) {
        let msg: String?
        switch state {
        case .loading: msg = MobileStrings.pinyinDictLoading()
        case .failed: msg = detail ?? MobileStrings.pinyinDictFailed()
        case .ready, .idle: msg = nil
        }
        showStatus(msg)
        setInputBlocked(state == .loading || state == .failed)
    }
}
