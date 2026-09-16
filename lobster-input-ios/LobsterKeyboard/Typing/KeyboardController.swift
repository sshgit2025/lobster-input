import Foundation

/// 键盘视图渲染回调(由 TypingKeyboardView 实现)。
protocol KeyboardRenderer: AnyObject {
    func rebuildKeyboard()
    func renderCandidates(composingDisplay: String, candidates: [PinyinCandidate], layoutLabel: String, numbered: Bool)
    func renderPinyinOptions(_ options: [String])
    /// 左侧竖排拼音选择器:options=当前编辑段可选读音,active=应高亮项。空则隐藏。
    func renderPinyinSelector(_ options: [String], _ active: String)
    func invalidateKeys()
    /// 进入分类符号板时回调:重置分类选中为「最近」,不记忆上次入口的选择。
    func onEnterSymBoard()
}

extension KeyboardRenderer {
    func onEnterSymBoard() {}
}

/// 键盘输入状态机(控制层)。组合、候选、模式/布局/符号页/数字页切换、长按出数字、句子联想。
final class KeyboardController: StrategyContext {

    var composing = ""
    let engine: PinyinEngine
    var shiftActive: Bool { shiftOn || capsLock }

    private unowned let host: TypingSessionHosting
    private weak var renderer: KeyboardRenderer?

    // 输入语种(中/英/俄/韩)。中英为核心语种;俄韩为扩展语种(独立布局,长按 LANG 轮换)。
    private var inputLang: InputLang
    private var chineseMode: Bool { inputLang == .zh }
    private var nineGrid: Bool
    private var shiftOn = false
    private var capsLock = false
    private var symbolPage = false
    private var numberPage = false
    private var symBoardPage = false
    private var symbolPageIndex = 0
    private var strategy: TypingInputStrategy!
    private var inputBlocked = false

    private var lastWord: String?
    /// 候选栏标点联想 v2(2026-07-23,test_punct_suggestion.py 模型):
    /// 同一 lastWord 点选过标点后不再重复推荐——仅在取不到光标前文本时的兜底抑制;
    /// 取得到上文时以文本实时判定为唯一事实源(退格删标点自然恢复)。
    private var punctConsumedFor: String?
    private var deleteTimer: Timer?
    /// 拼音选择器锁定的音节栈(问题2:锁定即消耗,LIFO 回退)。
    /// 选择器只展示未锁定剩余段的选项——全部锁定后选择器消失;
    /// 选词按消耗从栈头对齐扣减(剩余锁定保持,选词后选择器不再弹出);
    /// 回退键先 LIFO 撤销栈顶锁定,栈空才删数字(对齐搜狗音节点选交互)。
    private var t9LockedSyllables: [String] = []
    private var t9LockedPinyin: String { t9LockedSyllables.joined() }

    /// 9 宫格 1 键(@#)符号候选态:候选栏展示 SymbolData.key1Symbols 固定高频符号
    /// (对齐豆包;test_key1_symbols.py 模型验证)。点选符号后保持(可连点);
    /// 任何其它按键(字母/删除/空格/回车/切页)即退出,恢复常规候选逻辑。
    private var symCandidateMode = false

    /// 组词会话(问题4:用户自造词):同一拼音串被用户**分多次选词**消耗完时,
    /// 把「整串拼音 + 组合出的词」学进用户词典(耗子尾汁类,下次直接出整词)。
    /// 会话在 composing 从空到非空时开始;删除/丢弃/切模式即中止(防学到脏数据)。
    private var sessionWords = ""
    private var sessionPinyin = ""
    private var sessionPicks = 0
    private var sessionValid = true

    /// 问题3:多输入框连续填充的模式保持(对齐 Gboard 会话内布局粘性)。
    /// 用户**手动**切到数字键盘页后置位;同一键盘会话内切换输入框(验证码逐格跳转)时 reset()
    /// 会恢复数字页,而不是回到拼音初始态。用户手动切回字母页/切布局/键盘收起(会话结束)时清除。
    private var stickyNumberPage = false

    /// 英文框自动切换(邮箱/URI/密码,对齐 Gboard/搜狗):进入时自动切英文,只在会话内生效,
    /// 不写用户偏好;离开英文框(下一次 reset 非英文框)恢复用户原偏好。
    private var autoEnglishOverride = false

    private var t9Active: Bool { nineGrid && chineseMode && !symbolPage && !numberPage && !symBoardPage }

    private func sessionReset() {
        sessionWords = ""; sessionPinyin = ""; sessionPicks = 0; sessionValid = true
    }

    private func sessionRecordPick(_ c: PinyinCandidate, _ consumedPinyin: String) {
        if !sessionValid { return }
        if consumedPinyin.isEmpty || c.word.isEmpty { sessionValid = false; return }
        sessionWords += c.word
        sessionPinyin += consumedPinyin
        sessionPicks += 1
    }

    private func sessionMaybeLearn() {
        // 【用户选择记忆,对齐 RIME encode_commit_history】≥1 次选词拼完整串即编码上屏历史:
        // 单次点选整句拼出的候选(什么鬼)也必须学(learnPhrase 自带护栏:2-8 字/可切分/
        // 词库已有整词跳过),否则下次同串默认仍是机器整句(什么会)。
        if sessionValid && sessionPicks >= 1 && !host.isPasswordField() {
            engine.learnPhrase(sessionPinyin, sessionWords)
        }
        sessionReset()
    }

    /// 组合区击键:composing 为空时开始新组词会话。
    private func onComposingKeystroke() {
        if composing.isEmpty { sessionReset() }
    }

    /// 拼音选择器竖排选项:剩余段可选读音;maxSeg=6 覆盖长音节;保证高亮项(首候选读音)在列。
    func t9PinyinOptions() -> [String] {
        guard t9Active, !composing.isEmpty else { return [] }
        let remain = t9LockedPinyin.count < composing.count ? String(Array(composing)[t9LockedPinyin.count...]) : ""
        if remain.isEmpty {
            // 【常驻可改选,2026-07-11 对齐搜狗/百度】全部锁定后选择器不再消失:
            // 显示末段的可选读音(当前锁定项保底在列),点其它项即改选(selectT9Pinyin 替换末段)。
            // 方案经 test_t9_selector_persist.py 模型验证。
            guard let last = t9LockedSyllables.last else { return [] }
            let segStart = t9LockedPinyin.count - last.count
            var opts = engine.t9LeadingOptions(String(Array(composing)[segStart...]), maxSeg: 6, limit: 12)
            if !opts.contains(last) { opts.insert(last, at: 0) }
            return opts
        }
        var opts = engine.t9LeadingOptions(remain, maxSeg: 6, limit: 12)
        let active = t9ActiveOption()
        if !active.isEmpty && !opts.contains(active) { opts.insert(active, at: 0) }
        return opts
    }

    /// 当前编辑段应高亮的读音 = #1 候选在锁定前缀之后的首音节。
    /// 用字对齐切分取音节(话那么多钱@huanameduoqian 锁定 hua 后高亮 na,而不是贪心切出 nam);
    /// 对不齐(生僻字)回退贪心;无候选读音回退剩余段最优首音节。
    func t9ActiveOption() -> String {
        // 全锁定态:高亮用户点选的末段(常驻可改选,与 t9PinyinOptions 的末段选项对应)
        if !composing.isEmpty && t9LockedPinyin.count >= composing.count {
            return t9LockedSyllables.last ?? ""
        }
        if let top = currentCandidates().first, !top.pinyin.isEmpty, top.pinyin.count > t9LockedPinyin.count {
            if let aligned = engine.alignWordPinyin(top.word, top.pinyin) {
                var acc = 0
                for syl in aligned {
                    if acc == t9LockedPinyin.count { return syl }
                    acc += syl.count
                    if acc > t9LockedPinyin.count { break } // 锁定边界与对齐不一致:回退贪心
                }
            }
            let restStr = String(Array(top.pinyin)[t9LockedPinyin.count...])
            var L = min(6, restStr.count)
            while L >= 1 { let s = String(Array(restStr)[0..<L]); if engine.isSyllable(s) { return s }; L -= 1 }
        }
        let remain = t9LockedPinyin.count < composing.count ? String(Array(composing)[t9LockedPinyin.count...]) : ""
        return remain.isEmpty ? "" : engine.t9FirstSyllable(remain)
    }

    /// 点选拼音选择器某读音:压入锁定栈(不消耗数字),候选按读音前缀收窄。
    /// 全锁定态(2026-07-11 常驻可改选)= 改选末段:pop 末段再压新项;放不下则恢复原样(防御)。
    func selectT9Pinyin(_ syl: String) {
        let clean = syl.replacingOccurrences(of: "'", with: "")
        guard !clean.isEmpty else { return }
        if t9LockedPinyin.count + clean.count <= composing.count {
            t9LockedSyllables.append(clean)
        } else if let last = t9LockedSyllables.last, t9LockedPinyin.count >= composing.count {
            t9LockedSyllables.removeLast()
            if t9LockedPinyin.count + clean.count <= composing.count { t9LockedSyllables.append(clean) }
            else { t9LockedSyllables.append(last) }
        }
        host.onKeyFeedback()
        refreshCandidates()
    }

    /// 选词消耗锁定栈:从栈头按消耗的拼音位数对齐扣减(T9 一字母一数字)。
    /// 剩余锁定保持 → 选词后选择器不再重弹(问题2核心);消耗跨音节边界时整体清空(安全回退)。
    private func t9ConsumeLocked(_ consumed: Int) {
        var left = consumed
        while left > 0, let head = t9LockedSyllables.first {
            if left >= head.count { left -= head.count; t9LockedSyllables.removeFirst() }
            else { t9LockedSyllables.removeAll(); return }
        }
    }

    /// 当前有效候选来源(带拼音选择器锁定音节栈过滤:数字空间检索+锁定边界裁决)。
    private func currentCandidates() -> [PinyinCandidate] {
        t9Active ? engine.candidatesForT9Filtered(composing, t9LockedPinyin, lockedSylls: t9LockedSyllables) : strategy.candidates()
    }

    init(host: TypingSessionHosting, engine: PinyinEngine) {
        self.host = host
        self.engine = engine
        self.inputLang = host.inputLangDefault()
        self.nineGrid = host.isNineGridDefault()
        self.strategy = pickStrategy()
    }

    deinit {
        // 连删 Timer 由 runloop 持有,控制器销毁时必须显式停掉,
        // 否则键盘 VC 销毁后定时器仍会开火(真机闪退根因之一)。
        deleteTimer?.invalidate()
    }

    func bind(_ renderer: KeyboardRenderer) { self.renderer = renderer }

    func setInputBlocked(_ blocked: Bool) {
        inputBlocked = blocked
    }

    // 非中文一律 26 键式布局(对齐搜狗/Gboard 默认:九宫格中文切英/俄/韩直接变对应 26 键式布局,
    // T9 多击输入已过时);nineGrid 偏好只作用于中文,切回中文仍是九宫格。
    private func pickStrategy() -> TypingInputStrategy {
        if inputLang == .ru { return RussianStrategy(self) }
        if inputLang == .ko { return KoreanStrategy(self) }
        if chineseMode && nineGrid { return ChineseT9Strategy(self) }
        if chineseMode { return ChineseQwertyStrategy(self) }
        return EnglishQwertyStrategy(self)
    }

    func commit(_ text: String) { host.onCommit(text) }
    func deleteBeforeCursor() { host.onDeleteBeforeCursor() }
    func composingText(_ text: String) { host.onComposingText(text) }
    func finishComposing() { host.onFinishComposing() }

    func refreshCandidates() {
        // 9 宫格:识别拼音跟随过滤后#1,候选=过滤候选,左侧竖排=拼音选择器
        if t9Active && !composing.isEmpty {
            let disp = engine.t9DisplayFiltered(composing, t9LockedPinyin, lockedSylls: t9LockedSyllables)
            host.updateComposingPreview(disp)
            renderer?.renderCandidates(composingDisplay: disp, candidates: injectEmoji(currentCandidates()), layoutLabel: layoutSwitchText(), numbered: false)
            renderer?.renderPinyinSelector(t9PinyinOptions(), t9ActiveOption())
            return
        }
        renderer?.renderPinyinSelector([], "")
        let display = strategy.composingDisplay()
        host.updateComposingPreview(display)
        let numbered = chineseMode && nineGrid && !symbolPage && !numberPage
        if !composing.isEmpty {
            renderer?.renderCandidates(
                composingDisplay: display,
                candidates: injectEmoji(strategy.candidates()),
                layoutLabel: layoutSwitchText(),
                numbered: numbered
            )
        } else if symCandidateMode {
            // 1 键符号候选态(组合区为空时展示;对齐豆包)
            let symbols = SymbolData.key1Symbols.map { PinyinCandidate(word: $0, matchedLen: 0, score: 0, isSymbol: true) }
            renderer?.renderCandidates(
                composingDisplay: "",
                candidates: symbols,
                layoutLabel: layoutSwitchText(),
                numbered: false
            )
        } else if chineseMode, let prev = lastWord, !host.isPasswordField() {
            // 密码框不展示句子联想(隐私)
            // 标点联想 v2(头部注入,仅中文):取得到上文以文本判定为唯一事实源;
            // 取不到上文走词法规则 + punctConsumedFor 兜底防重复
            let bt = host.textBeforeCursor(64)
            let puncts: [PinyinCandidate]
            if !bt.isEmpty {
                puncts = PunctuationSuggestion.suggestions(prev, beforeText: bt).map {
                    PinyinCandidate(word: $0, matchedLen: 0, score: 0, isPunct: true)
                }
            } else if punctConsumedFor != prev {
                puncts = PunctuationSuggestion.suggestions(prev, beforeText: "").map {
                    PinyinCandidate(word: $0, matchedLen: 0, score: 0, isPunct: true)
                }
            } else {
                puncts = []
            }
            let emojis = EmojiData.associations(prev).map { PinyinCandidate(word: $0, matchedLen: 0, score: 0, isEmoji: true) }
            renderer?.renderCandidates(
                composingDisplay: "",
                candidates: puncts + emojis + engine.associations(prev),
                layoutLabel: layoutSwitchText(),
                numbered: false
            )
        } else {
            renderer?.renderCandidates(
                composingDisplay: "",
                candidates: [],
                layoutLabel: layoutSwitchText(),
                numbered: false
            )
        }
    }

    func consumeShift() {
        if shiftOn && !capsLock { shiftOn = false; renderer?.rebuildKeyboard() }
    }

    /// 打字时把 emoji 混进候选:命中首选词的 emoji 映射就插到首选词之后。
    private func injectEmoji(_ cands: [PinyinCandidate]) -> [PinyinCandidate] {
        guard let first = cands.first, !host.isPasswordField() else { return cands }
        let emojis = EmojiData.associations(first.word)
        if emojis.isEmpty { return cands }
        let emojiCands = emojis.map { PinyinCandidate(word: $0, matchedLen: 0, score: 0, isEmoji: true) }
        return [first] + emojiCands + cands.dropFirst()
    }

    // 非中文强制 26 键式布局(T9 多击已废弃);nineGrid 偏好保留,切回中文自动还原九宫格
    func layoutState() -> KeyboardLayoutFactory.LayoutState {
        KeyboardLayoutFactory.LayoutState(
            chineseMode: chineseMode,
            nineGrid: chineseMode && nineGrid,
            symbolPage: symbolPage,
            numberPage: numberPage,
            symbolPageIndex: symbolPageIndex,
            enterLabel: host.enterKeyLabel(),
            canUndo: host.canUndo(),
            lang: inputLang,
            nextModeLabel: nextModeLabel()
        )
    }

    func isShiftActive() -> Bool { shiftOn }
    func isCapsLock() -> Bool { capsLock }
    func isChineseMode() -> Bool { chineseMode }
    func currentLang() -> InputLang { inputLang }
    func returnVoiceText() -> String { host.localize(.returnVoice) }
    // 候选栏右上角布局切换按钮已下线(问题3:切换统一由键区常驻模式轮换键承担,返回空串=隐藏)
    func layoutSwitchText() -> String { "" }

    func handleKey(_ spec: TypingKeySpec) {
        guard !inputBlocked else { return }
        host.onKeyFeedback()
        // 1 键符号候选态:除再次点 1 键外,任何按键都先退出(点选候选不走此入口,可连点)
        if spec.type != .symCands { symCandidateMode = false }
        switch spec.type {
        // shiftValue:韩语双辅音/复合元音(ㅂ→ㅃ);拉丁/西里尔大小写由策略内部处理
        case .letter:
            onComposingKeystroke()
            strategy.onAlpha(shiftActive && spec.shiftValue != nil ? spec.shiftValue! : spec.main)
        case .t9: if let v = spec.value { onComposingKeystroke(); strategy.onAlpha(v) }
        case .delete: doDelete()
        case .space: onSpace()
        case .enter: onEnter()
        case .shift: onShift()
        case .lang: toggleLanguage()
        case .layout: toggleLayout()
        // 模式轮换键(全布局常驻):中文九宫格→中文26键→英文→俄语→韩语 循环
        case .modeCycle: cycleMode()
        // 分类符号板(最近/中文/英文/括号/数学/序号/货币/箭头)
        case .symBoard:
            discardComposing(); lastWord = nil; symBoardPage = true; symbolPage = false; numberPage = false
            renderer?.onEnterSymBoard(); renderer?.rebuildKeyboard(); refreshCandidates()
        case .num:
            // 手动进数字页 → 会话内粘性(问题3:验证码逐格填充,焦点跳转后仍保持数字键盘)
            discardComposing(); lastWord = nil; numberPage = true; stickyNumberPage = true; symbolPage = false; symBoardPage = false
            renderer?.rebuildKeyboard(); refreshCandidates()
        case .symbol:
            discardComposing(); lastWord = nil; symbolPage = true; numberPage = false; symBoardPage = false; symbolPageIndex = 0
            renderer?.rebuildKeyboard(); refreshCandidates()
        case .alpha:
            // 手动回字母页 → 解除数字页粘性
            symbolPage = false; numberPage = false; stickyNumberPage = false; symBoardPage = false; renderer?.rebuildKeyboard(); refreshCandidates()
        case .symPage:
            symbolPageIndex = symbolPageIndex == 0 ? 1 : 0; renderer?.rebuildKeyboard()
        // 9 宫格 1 键(@#):候选栏出固定高频符号候选(对齐豆包;test_key1_symbols.py 模型)
        case .symCands:
            discardComposing()
            symCandidateMode = true
            refreshCandidates()
        case .symChar:
            discardComposing()
            let ch = spec.value ?? spec.main
            if let closing = SmartPunctuation.closing(for: ch) { host.onCommitPair(ch, closing) }
            else { host.onCommit(ch) }
            // 标点不清空 lastWord:保留句子联想上下文
            // (v2:标点联想抑制改由 host.textBeforeCursor 实时判定,本分支零改动)
            // 【符号页单击回跳】对齐搜狗/百度/豆包:符号页点一个符号上屏即回到进入前的
            // 输入布局(inputLang/nineGrid 从未被符号页改动,清页即还原);数字例外——
            // 首行 1-0 常用于连续输入年份/金额(test_symbol_autoreturn.py 模型)。
            if symbolPage && !(ch.count == 1 && ch.first!.isNumber) {
                symbolPage = false; symbolPageIndex = 0
                renderer?.rebuildKeyboard()
            }
            refreshCandidates()
        case .syllable:
            if nineGrid {
                if (!composing.isEmpty), let first = currentCandidates().first { selectCandidate(first) }
            } else if chineseMode, !composing.isEmpty, !composing.hasSuffix("'") {
                composing += "'"
                refreshCandidates()
            }
        case .undo:
            host.undoLastCommit()
            refreshCandidates()
        case .mic, .gap: break
        }
    }

    func handleLongPress(_ spec: TypingKeySpec) {
        guard !inputBlocked else { return }
        // 长按语种轮换已取消(不可发现):语种/布局切换统一走 modeCycle 常驻轮换键
        guard let v = spec.longValue else { return }
        host.onKeyFeedback()
        discardComposing(); lastWord = nil
        // 长按字母(俄语 е→ё)跟随 shift 大小写;数字/符号不受影响
        let out = (shiftActive && v.count == 1 && v.first!.isLetter) ? v.uppercased() : v
        host.onCommit(out)
        consumeShift()
        refreshCandidates()
    }

    func selectCandidate(_ c: PinyinCandidate) {
        if c.isPunct {
            // 标点联想候选:直接上屏(不配对)、不学习、保 lastWord(联想链不断)、
            // 同一 lastWord 不再重复推荐标点(词语联想继续)。
            host.onCommit(c.word)
            punctConsumedFor = lastWord
            refreshCandidates()
            return
        }
        if c.isSymbol {
            // 1 键符号候选:括号/书名号成套插入(光标后无文字才成套,有文字只插前半;
            // 后半直接上屏);不写词典、不改 lastWord(联想链不断);列表保持可连点。
            if let closing = SmartPunctuation.closing(for: c.word), !host.hasTextAfterCursor() {
                host.onCommitPair(c.word, closing)
            } else {
                host.onCommit(c.word)
            }
            refreshCandidates()
            return
        }
        if c.isEmoji {
            host.onCommit(c.word)
            // 选 emoji = 放弃当前拼音串;不改 lastWord(联想链不断)
            composing = ""
            sessionReset()
            refreshCandidates()
            return
        }
        host.onCommit(c.word)
        // 密码框不写用户词典/不调频(隐私合规)
        if !host.isPasswordField() { engine.learnSequence(lastWord, c.word) }
        lastWord = c.word
        // 逐词消耗:消耗 matchedLen(T9 拼音长度==数字位数),保留剩余继续打下一词
        let consumedLen = min(c.matchedLen, composing.count)
        // 锁定栈从头对齐扣减:已锁定的剩余音节保持锁定,选词后选择器不再重弹(问题2)
        t9ConsumeLocked(consumedLen)
        // 组词会话:记录本次消耗的拼音段(T9 用候选实际读音,26 键用输入字母)
        let consumedPinyin: String
        if t9Active {
            consumedPinyin = (!c.pinyin.isEmpty && c.pinyin.count == consumedLen) ? c.pinyin : ""
        } else {
            consumedPinyin = String(Array(composing)[0..<consumedLen]).filter { $0 != "'" }
        }
        sessionRecordPick(c, consumedPinyin)
        if c.matchedLen >= composing.count { composing = "" }
        else { composing = String(Array(composing)[c.matchedLen...]) }
        if composing.isEmpty { sessionMaybeLearn() }
        refreshCandidates()
    }

    func returnToVoice() { host.onReturnToVoice() }
    func micRecordStart() { host.onKeyboardMicStart() }
    func micRecordEnd() { host.onKeyboardMicStop() }

    func toggleLayout() {
        discardComposing()
        nineGrid.toggle()
        host.persistNineGrid(nineGrid)
        symbolPage = false; numberPage = false; stickyNumberPage = false; lastWord = nil
        strategy = pickStrategy(); strategy.reset()
        renderer?.rebuildKeyboard(); refreshCandidates()
    }

    func onDeletePressDown() {
        guard !inputBlocked else { return }
        host.onKeyFeedback(); doDelete()
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in self?.startDeleteRepeat() }
    }

    private func startDeleteRepeat() {
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.048, repeats: true) { [weak self] _ in self?.doDelete() }
    }

    func onDeletePressUp() { deleteTimer?.invalidate(); deleteTimer = nil }

    private func doDelete() {
        symCandidateMode = false // 长按连删直呼此处,不经 handleKey
        // 韩语组字态:逐 jamo 拆解(닭→달→다→ㄷ),拆完再走文档删除
        if strategy.onDelete() { return }
        // 9 宫格:回退键先 LIFO 撤销上一个点选的音节(问题2:连续回退逐个重选);栈空才删数字
        if t9Active && !composing.isEmpty {
            if !t9LockedSyllables.isEmpty {
                t9LockedSyllables.removeLast()
                refreshCandidates(); return
            }
            composing.removeLast()
            refreshCandidates(); return
        }
        if !composing.isEmpty { composing.removeLast(); refreshCandidates() }
        else { lastWord = nil; sessionReset(); host.onDeleteBeforeCursor(); refreshCandidates() }
    }

    private func onSpace() {
        if (!composing.isEmpty), let first = currentCandidates().first { selectCandidate(first); return }
        strategy.flush() // 韩语:先定稿组合中音节再上屏空格
        // 空格不清空 lastWord:保留句子联想上下文
        host.onCommit(" ")
        refreshCandidates()
    }

    private func onEnter() {
        if !composing.isEmpty {
            if let first = currentCandidates().first { selectCandidate(first) }
            else { discardComposing() }
            return
        }
        strategy.flush()
        lastWord = nil
        host.onEnter()
        refreshCandidates()
    }

    private func onShift() {
        if capsLock { capsLock = false; shiftOn = false }
        else if shiftOn { capsLock = true }
        else { shiftOn = true }
        renderer?.rebuildKeyboard()
    }

    /// LANG 键轮换序列:中英为核心恒在;App 界面语言为俄/韩时对应语种加入环首;
    /// 用户临时进入俄/韩键盘时该语种也入环(可一键轮回中英)。中英组用户仍是纯 中↔EN 两态。
    private func langRing() -> [InputLang] {
        var ring: [InputLang] = []
        let groupDef = host.groupDefaultLang()
        if groupDef == .ru || groupDef == .ko { ring.append(groupDef) }
        if (inputLang == .ru || inputLang == .ko) && !ring.contains(inputLang) { ring.append(inputLang) }
        ring.append(.zh); ring.append(.en)
        return ring
    }

    private func toggleLanguage() {
        let ring = langRing()
        let idx = ring.firstIndex(of: inputLang) ?? -1
        setLanguage(ring[(idx + 1) % ring.count])
    }

    /// 模式轮换键:**只循环语言**(中文九宫格 → 英文 → 俄语 → 韩语 → 中文),中文永远沿用记住的布局。
    /// 2026-07 修复:旧环把 [中九,中26,英,俄,韩] 串一起,中九→英要经过中26 并 persistNineGrid(false),
    /// 之后 LANG 切回中文就停在中26(反人类)。语言与布局解耦(对齐搜狗/Gboard):
    /// 语言切换绝不改中文布局偏好;九宫格↔26键由工具页布局磁贴独立切换(见 toggleLayout)。
    private func modeRing() -> [InputLang] {
        [.zh, .en, .ru, .ko]
    }

    func cycleMode() {
        let ring = modeRing()
        let idx = ring.firstIndex(of: inputLang) ?? 0
        let next = ring[(idx + 1) % ring.count]
        discardComposing()
        inputLang = next
        // 语言/布局正交:切语言绝不动 nineGrid(切回中文自动用记住的九宫格/26键偏好)。
        autoEnglishOverride = false
        host.persistInputLang(next)
        composing = ""; symbolPage = false; numberPage = false; symBoardPage = false; lastWord = nil
        strategy = pickStrategy(); strategy.reset()
        renderer?.rebuildKeyboard(); refreshCandidates()
    }

    /// 轮换键下一模式短标签(画在图标下方,预告下一站语言,用户可预期)。
    func nextModeLabel() -> String {
        let ring = modeRing()
        let idx = ring.firstIndex(of: inputLang) ?? 0
        return ring[(idx + 1) % ring.count].keyLabel
    }

    func isSymBoardPage() -> Bool { symBoardPage }
    func recentSymbols() -> [String] { host.recentSymbols() }

    /// 分类符号板选中:智能配对上屏 + 记入最近使用(键盘/语音共用存储)。
    func selectSymbol(_ symbol: String) {
        host.onKeyFeedback()
        if let closing = SmartPunctuation.closing(for: symbol) { host.onCommitPair(symbol, closing) }
        else { host.onCommit(symbol) }
        host.recordRecentSymbol(symbol)
        // 【符号板单击回跳】对齐搜狗"更多符号"面板:点选即回到进入前的输入布局
        if symBoardPage {
            symBoardPage = false
            renderer?.rebuildKeyboard()
        }
        refreshCandidates()
    }

    /// 切换输入语种(LANG 环 / 长按轮换共用):手动选择写回偏好,解除自动接管。
    func setLanguage(_ lang: InputLang) {
        discardComposing()
        inputLang = lang
        // 用户手动切语种:解除英文框自动切换接管,且写回用户偏好(与业界一致,手动选择优先)
        autoEnglishOverride = false
        host.persistInputLang(lang)
        symbolPage = false; numberPage = false; lastWord = nil
        strategy = pickStrategy(); strategy.reset()
        renderer?.rebuildKeyboard(); refreshCandidates()
    }

    /// 切换模式时丢弃拼音组合串(不上屏);韩语组合音节例外——已在目标框可见,定稿保留(业界一致)。
    private func discardComposing() {
        strategy.flush()
        t9LockedSyllables.removeAll()
        // 1 键符号候选态一并退出(不经 handleKey 的入口);SYM_CANDS 键自身在 discard 之后才置位
        symCandidateMode = false
        sessionReset()
        guard !composing.isEmpty else { host.clearComposingPreview(); return }
        composing = ""
        host.clearComposingPreview()
        refreshCandidates()
    }

    /// 输入框切换/键盘拉起时的状态复位(问题3:模式保持的核心决策点,对齐 Gboard/搜狗)。
    ///  - 数字/电话框:自动进数字键盘页(输入框类型感知,优先级最高)。
    ///  - 会话内粘性:用户上个框手动切了数字页(验证码场景),焦点跳到下一格继续保持。
    ///  - 邮箱/URI/密码框:自动切英文模式(仅会话内,不写用户偏好);离开后恢复用户偏好。
    ///  - 其余状态(composing/符号页)一律清理,不残留。
    func reset() {
        t9LockedSyllables.removeAll()
        symCandidateMode = false
        sessionReset()
        strategy.flush()
        composing = ""
        host.clearComposingPreview()
        strategy.reset()
        symbolPage = false; numberPage = false; symBoardPage = false; symbolPageIndex = 0; lastWord = nil
        // App 界面语言跨组切换(中英组↔俄↔韩):清空全部模式暂存,回到新语言组默认键盘。
        // 组内互切(中英界面语言互换)不触发,粘性与语种状态一直生效。
        if host.consumeLangGroupChange() {
            stickyNumberPage = false
            autoEnglishOverride = false
            inputLang = host.inputLangDefault()
            strategy = pickStrategy(); strategy.reset()
        }
        if host.isNumericField() || stickyNumberPage { numberPage = true }
        // 英文框自动切英文;离开英文框时恢复用户偏好(autoEnglishOverride 标记"当前英文态是自动切的")
        if host.isEnglishField() {
            if inputLang != .en { inputLang = .en; autoEnglishOverride = true; strategy = pickStrategy() }
        } else if autoEnglishOverride {
            autoEnglishOverride = false
            let prefer = host.inputLangDefault()
            if inputLang != prefer { inputLang = prefer; strategy = pickStrategy() }
        }
        renderer?.rebuildKeyboard(); refreshCandidates()
    }

    /// 键盘会话结束(键盘收起):清除会话级粘性,下次拉起回归输入框类型感知 + 用户偏好。
    func onSessionEnd() {
        strategy.flush()
        stickyNumberPage = false
        if autoEnglishOverride {
            autoEnglishOverride = false
            let prefer = host.inputLangDefault()
            if inputLang != prefer { inputLang = prefer; strategy = pickStrategy() }
        }
    }
}
