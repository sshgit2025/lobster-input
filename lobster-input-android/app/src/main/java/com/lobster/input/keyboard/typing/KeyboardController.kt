package com.lobster.input.keyboard.typing

import android.os.Handler
import android.os.Looper
import com.lobster.input.keyboard.pinyin.Candidate
import com.lobster.input.keyboard.pinyin.PinyinEngine
import com.lobster.input.keyboard.pinyin.PinyinLoadState
import com.lobster.input.keyboard.typing.composing.ComposingTextBridge

/**
 * 键盘输入状态机(控制层)。组合、候选、模式切换、Enter/Space 语义、撤销、组合预览。
 */
class KeyboardController(
    private val host: TypingKeyboardHost,
    override val engine: PinyinEngine,
    private val composingBridge: ComposingTextBridge? = null
) : StrategyContext {

    override val composing = StringBuilder()
    // 输入语种(中/英/俄/韩)。中英为核心语种;俄韩为扩展语种(独立布局,LANG 环 + 工具页直达)。
    private var inputLang: InputLang = host.inputLangDefault()
    private val chineseMode get() = inputLang == InputLang.ZH
    private var nineGrid = host.isNineGridDefault()
    private var shiftOn = false
    private var capsLock = false
    private var symbolPage = false
    private var numberPage = false
    private var emojiPage = false
    private var clipPage = false
    private var toolsPage = false
    private var symBoardPage = false
    private var symbolPageIndex = 0
    private var strategy: InputStrategy = pickStrategy()
    private var lastWord: String? = null
    /**
     * 候选栏标点联想 v2(2026-07-23,test_punct_suggestion.py 模型):
     * 同一 lastWord 点选过标点后不再重复推荐——仅在取不到光标前文本时(host.textBeforeCursor
     * 返回空)的兜底抑制;取得到上文时以文本实时判定为唯一事实源(退格删标点自然恢复)。
     */
    private var punctConsumedFor: String? = null
    private var renderer: KeyboardRenderer? = null
    private var inputBlocked = false
    /**
     * 9 宫格拼音选择器锁定的音节栈(问题2:锁定即消耗,LIFO 回退)。
     * 过滤模型:composing 保留全部数字不消耗,候选按锁定读音前缀过滤;
     * 选择器只展示未锁定剩余段的选项——全部锁定后选择器消失;
     * 选词按消耗从栈头对齐扣减(剩余锁定保持,选词后选择器不再弹出);
     * 回退键先 LIFO 撤销栈顶锁定,栈空才删数字(对齐搜狗音节点选交互)。
     */
    private val t9LockedSyllables = ArrayList<String>()
    private val t9LockedPinyin get() = t9LockedSyllables.joinToString("")

    /**
     * 9 宫格 1 键(@#)符号候选态:候选栏展示 SymbolData.key1Symbols 固定高频符号
     * (对齐豆包;test_key1_symbols.py 模型验证)。点选符号后保持(可连点);
     * 任何其它按键(字母/删除/空格/回车/切页)即退出,恢复常规候选逻辑。
     */
    private var symCandidateMode = false

    /**
     * 组词会话(问题4:用户自造词):同一拼音串被用户**分多次选词**消耗完时,
     * 把「整串拼音 + 组合出的词」学进用户词典(耗子尾汁类,下次直接出整词)。
     * 会话在 composing 从空到非空时开始;删除/丢弃/切模式即中止(防学到脏数据)。
     */
    private val sessionWords = StringBuilder()
    private val sessionPinyin = StringBuilder()
    private var sessionPicks = 0
    private var sessionValid = true

    private fun sessionReset() {
        sessionWords.setLength(0); sessionPinyin.setLength(0); sessionPicks = 0; sessionValid = true
    }

    private fun sessionRecordPick(c: Candidate, consumedPinyin: String) {
        if (!sessionValid) return
        if (consumedPinyin.isEmpty() || c.word.isEmpty()) { sessionValid = false; return }
        sessionWords.append(c.word)
        sessionPinyin.append(consumedPinyin)
        sessionPicks++
    }

    private fun sessionMaybeLearn() {
        // 【用户选择记忆,对齐 RIME encode_commit_history】≥1 次选词拼完整串即编码上屏历史:
        // 单次点选整句拼出的候选(什么鬼)也必须学(learnPhrase 自带护栏:2-8 字/可切分/
        // 词库已有整词跳过),否则下次同串默认仍是机器整句(什么会)。
        if (sessionValid && sessionPicks >= 1 && !isPasswordField()) {
            engine.learnPhrase(sessionPinyin.toString(), sessionWords.toString())
        }
        sessionReset()
    }

    /** 组合区击键:composing 为空时开始新组词会话。 */
    private fun onComposingKeystroke() {
        if (composing.isEmpty()) sessionReset()
    }

    /**
     * 问题3:多输入框连续填充的模式保持(对齐 Gboard 会话内布局粘性)。
     * 用户**手动**切到数字键盘页后置位;同一键盘会话内切换输入框(验证码逐格跳转)时 reset()
     * 会恢复数字页,而不是回到拼音初始态。用户手动切回字母页/切布局/键盘收起(会话结束)时清除。
     */
    private var stickyNumberPage = false

    /**
     * 英文框自动切换(邮箱/URI/密码,对齐 Gboard/搜狗):进入时自动切英文,只在会话内生效,
     * 不写用户偏好;离开英文框(下一次 reset 非英文框)恢复用户原偏好。
     */
    private var autoEnglishOverride = false

    private val deleteHandler = Handler(Looper.getMainLooper())
    private var deleteRepeating = false
    private val deleteRunnable = object : Runnable {
        override fun run() { if (!deleteRepeating) return; doDelete(); deleteHandler.postDelayed(this, 48L) }
    }

    fun bind(renderer: KeyboardRenderer) { this.renderer = renderer }

    fun setInputBlocked(blocked: Boolean) {
        inputBlocked = blocked
        renderer?.setInputBlocked(blocked)
    }

    // 非中文一律 26 键式布局(对齐搜狗/Gboard 默认:九宫格中文切英/俄/韩直接变对应 26 键式布局,
    // T9 多击输入已过时);nineGrid 偏好只作用于中文,切回中文仍是九宫格。
    private fun pickStrategy(): InputStrategy = when {
        inputLang == InputLang.RU -> RussianStrategy(this)
        inputLang == InputLang.KO -> KoreanStrategy(this)
        chineseMode && nineGrid -> ChineseT9Strategy(this)
        chineseMode -> ChineseQwertyStrategy(this)
        else -> EnglishQwertyStrategy(this)
    }

    override val shiftActive get() = shiftOn || capsLock
    override fun commit(text: String) = host.onCommit(text)
    override fun deleteBeforeCursor() = host.onDeleteBeforeCursor()
    override fun composingText(text: String) = host.onComposingText(text)
    override fun finishComposing() = host.onFinishComposing()

    fun isPasswordField() = host.isPasswordField()
    fun isMicAvailable() = host.isMicAvailable()

    /**
     * 拼音选择器竖排选项(左侧):当前编辑段(锁定前缀之后的剩余数字)的可选读音。
     * 如 9267426 锁定 "wan" 后,剩余 "7426" → [shan, sha, ...] 供细化;无输入则空。
     */
    fun t9PinyinOptions(): List<String> {
        if (!t9Active || composing.isEmpty()) return emptyList()
        val remain = if (t9LockedPinyin.length < composing.length) composing.substring(t9LockedPinyin.length) else ""
        if (remain.isEmpty()) {
            // 【常驻可改选,2026-07-11 对齐搜狗/百度】全部锁定后选择器不再消失:
            // 显示**末段**的可选读音(该段起点到串尾的 t9LeadingOptions),当前锁定项保底在列,
            // 点其它项即改选(selectT9Pinyin 替换末段)。composing 为空(选词消耗完)仍隐藏。
            // 方案经 test_t9_selector_persist.py 模型验证。
            val last = t9LockedSyllables.lastOrNull() ?: return emptyList()
            val segStart = t9LockedPinyin.length - last.length
            val opts = engine.t9LeadingOptions(composing.substring(segStart), maxSeg = 6, limit = 12).toMutableList()
            if (last !in opts) opts.add(0, last)
            return opts
        }
        // maxSeg=6 覆盖 4-6 字母长音节;limit=12(选择器可滑动)+ 引擎整段音节全保留(修 qiao 被截断);
        // 再保证高亮项(首候选读音)始终在列可点(本地脚本花式验证)
        val opts = engine.t9LeadingOptions(remain, maxSeg = 6, limit = 12).toMutableList()
        val active = t9ActiveOption()
        if (active.isNotEmpty() && active !in opts) opts.add(0, active)
        return opts
    }

    /**
     * 当前编辑段应高亮的读音 = #1 候选在锁定前缀之后的首音节。
     * 用字对齐切分取音节(话那么多钱@huanameduoqian 锁定 hua 后高亮 na,而不是贪心切出 name/nam);
     * 对不齐(生僻字)回退贪心;无候选读音回退剩余段最优首音节。
     */
    fun t9ActiveOption(): String {
        // 全锁定态:高亮用户点选的末段(常驻可改选,与 t9PinyinOptions 的末段选项对应)
        if (composing.isNotEmpty() && t9LockedPinyin.length >= composing.length) {
            return t9LockedSyllables.lastOrNull() ?: ""
        }
        val top = currentCandidates().firstOrNull()
        val py = top?.pinyin
        if (top != null && !py.isNullOrEmpty() && py.length > t9LockedPinyin.length) {
            engine.alignWordPinyin(top.word, py)?.let { aligned ->
                var acc = 0
                for (syl in aligned) {
                    if (acc == t9LockedPinyin.length) return syl
                    acc += syl.length
                    if (acc > t9LockedPinyin.length) break // 锁定边界与对齐不一致:回退贪心
                }
            }
            val rest = py.substring(t9LockedPinyin.length)
            for (L in minOf(6, rest.length) downTo 1) if (engine.isSyllable(rest.substring(0, L))) return rest.substring(0, L)
        }
        val remain = if (t9LockedPinyin.length < composing.length) composing.substring(t9LockedPinyin.length) else ""
        return if (remain.isEmpty()) "" else engine.t9FirstSyllable(remain)
    }

    /**
     * 用户点选拼音选择器某读音:压入锁定栈(不消耗数字),候选按读音前缀收窄。
     * 全锁定态(2026-07-11 常驻可改选)= 改选末段:pop 末段再压新项;放不下则恢复原样(防御)。
     */
    fun selectT9Pinyin(syl: String) {
        val clean = syl.replace("'", "")
        if (clean.isEmpty()) return
        if (t9LockedPinyin.length + clean.length <= composing.length) {
            t9LockedSyllables.add(clean)
        } else if (t9LockedSyllables.isNotEmpty() && t9LockedPinyin.length >= composing.length) {
            val last = t9LockedSyllables.removeAt(t9LockedSyllables.size - 1)
            if (t9LockedPinyin.length + clean.length <= composing.length) t9LockedSyllables.add(clean)
            else t9LockedSyllables.add(last)
        }
        host.onKeyFeedback()
        refreshCandidates()
    }

    /**
     * 选词消耗锁定栈:从栈头按消耗的拼音位数对齐扣减(T9 一字母一数字)。
     * 剩余锁定保持 → 选词后选择器不再重弹(问题2核心);消耗跨音节边界时整体清空(安全回退)。
     */
    private fun t9ConsumeLocked(consumed: Int) {
        var left = consumed
        while (left > 0 && t9LockedSyllables.isNotEmpty()) {
            val head = t9LockedSyllables[0]
            if (left >= head.length) { left -= head.length; t9LockedSyllables.removeAt(0) }
            else { t9LockedSyllables.clear(); return }
        }
    }

    private val t9Active get() = nineGrid && chineseMode && !symbolPage && !numberPage && !emojiPage && !clipPage && !symBoardPage

    /** 当前有效候选来源(带拼音选择器锁定音节栈过滤:数字空间检索+锁定边界裁决)。 */
    private fun currentCandidates(): List<Candidate> =
        if (t9Active) engine.candidatesForT9Filtered(composing.toString(), t9LockedPinyin, lockedSylls = t9LockedSyllables)
        else strategy.candidates()

    override fun refreshCandidates() {
        when {
            // 9 宫格:组合区显示识别拼音(跟随过滤后#1),候选=过滤候选,左侧竖排=拼音选择器
            t9Active && composing.isNotEmpty() -> {
                // 核心(候选+识别拼音)必须先渲染且不可被装饰性选择器拖垮
                val display = engine.t9DisplayFiltered(composing.toString(), t9LockedPinyin, t9LockedSyllables)
                composingBridge?.update(display)
                renderer?.renderCandidates(display, injectEmoji(currentCandidates()), layoutSwitchText())
                // 拼音选择器为装饰增强:任何异常都隔离,绝不阻塞核心打字
                runCatching { renderer?.renderPinyinSelector(t9PinyinOptions(), t9ActiveOption()) }
            }
            composing.isNotEmpty() -> {
                renderer?.renderPinyinSelector(emptyList(), "")
                val display = strategy.composingDisplay()
                composingBridge?.update(if (chineseMode) display else "")
                renderer?.renderCandidates(display, injectEmoji(strategy.candidates()), layoutSwitchText())
            }
            // 1 键符号候选态(组合区为空时展示;对齐豆包)
            symCandidateMode -> {
                renderer?.renderPinyinSelector(emptyList(), "")
                composingBridge?.update("")
                val symbols = SymbolData.key1Symbols.map { Candidate(it, 0, 0, isSymbol = true) }
                renderer?.renderCandidates("", symbols, layoutSwitchText())
            }
            // 密码框:不展示句子联想(隐私),避免泄露上文用词
            chineseMode && lastWord != null && !isPasswordField() -> {
                renderer?.renderPinyinSelector(emptyList(), "")
                composingBridge?.update("")
                // 标点联想 v2(头部注入,仅中文):取得到上文以文本判定为唯一事实源;
                // 取不到上文走词法规则 + punctConsumedFor 兜底防重复
                val bt = host.textBeforeCursor(64)
                val puncts = if (bt.isNotEmpty()) {
                    PunctuationSuggestion.suggestions(lastWord, bt).map { Candidate(it, 0, 0, isPunct = true) }
                } else if (punctConsumedFor != lastWord) {
                    PunctuationSuggestion.suggestions(lastWord, "").map { Candidate(it, 0, 0, isPunct = true) }
                } else emptyList()
                val emojis = EmojiData.associations(lastWord!!).map { Candidate(it, 0, 0, isEmoji = true) }
                renderer?.renderCandidates("", puncts + emojis + engine.associations(lastWord!!), layoutSwitchText())
            }
            else -> {
                renderer?.renderPinyinSelector(emptyList(), "")
                composingBridge?.update("")
                renderer?.renderCandidates("", emptyList(), layoutSwitchText())
            }
        }
    }

    /** 打字时把 emoji 混进候选(业界做法):命中首选词的 emoji 映射就插到首选词之后。 */
    private fun injectEmoji(cands: List<Candidate>): List<Candidate> {
        if (cands.isEmpty() || isPasswordField()) return cands
        val emojis = EmojiData.associations(cands[0].word)
        if (emojis.isEmpty()) return cands
        return listOf(cands[0]) + emojis.map { Candidate(it, 0, 0, isEmoji = true) } + cands.drop(1)
    }

    override fun consumeShift() {
        if (shiftOn && !capsLock) { shiftOn = false; renderer?.rebuildKeyboard() }
    }

    // 非中文强制 26 键式布局(T9 多击已废弃);nineGrid 偏好保留,切回中文自动还原九宫格
    fun layoutState() = KeyboardLayoutFactory.LayoutState(chineseMode, chineseMode && nineGrid, symbolPage, numberPage, symbolPageIndex, inputLang, nextModeLabel())
    fun isEmojiPage() = emojiPage
    fun isToolsPage() = toolsPage
    fun recentEmojis() = host.recentEmojis()

    /** 齿轮:打开/关闭工具子页(不加高面板,替换键区)。 */
    fun openTools() {
        discardComposing(); lastWord = null
        toolsPage = true; emojiPage = false; clipPage = false; symbolPage = false; numberPage = false; symBoardPage = false
        renderer?.rebuildKeyboard(); refreshCandidates()
    }

    fun isSymBoardPage() = symBoardPage
    fun recentSymbols() = host.recentSymbols()

    /** 分类符号板选中:智能配对上屏 + 记入最近使用(键盘/语音共用存储)。 */
    fun selectSymbol(symbol: String) {
        host.onKeyFeedback()
        val closing = SmartPunctuation.closingFor(symbol)
        if (closing != null) host.onCommitPair(symbol, closing) else host.onCommit(symbol)
        host.recordRecentSymbol(symbol)
        // 【符号板单击回跳】对齐搜狗"更多符号"面板:点选即回到进入前的输入布局
        if (symBoardPage) {
            symBoardPage = false
            renderer?.rebuildKeyboard()
        }
        refreshCandidates()
    }

    /** 工具子页里的动作:切布局 / emoji / 剪贴板 / 俄语 / 韩语键盘;完成后关闭工具页。 */
    fun runTool(tool: String) {
        toolsPage = false
        when (tool) {
            "layout" -> toggleLayout()
            "emoji" -> { emojiPage = true; renderer?.rebuildKeyboard(); refreshCandidates() }
            "clip" -> { if (!isPasswordField()) { clipPage = true } ; renderer?.rebuildKeyboard(); refreshCandidates() }
            // 已在该语种 → 回语言组默认键盘(中英组回中/英,俄韩语境回对应语种)
            "lang_ru" -> setLanguage(if (inputLang == InputLang.RU) host.groupDefaultLang() else InputLang.RU)
            "lang_ko" -> setLanguage(if (inputLang == InputLang.KO) host.groupDefaultLang() else InputLang.KO)
            else -> { renderer?.rebuildKeyboard(); refreshCandidates() }
        }
    }
    fun isClipPage() = clipPage
    fun clipboardHistory() = host.clipboardHistory()
    fun quickPhrases() = host.quickPhrases()
    fun removeClipboardItem(item: String) = host.removeClipboardItem(item)
    fun clearClipboard() = host.clearClipboard()

    /** 选中剪贴板/快捷短语:上屏(不写词典)。 */
    fun selectClip(text: String) {
        host.onKeyFeedback()
        host.onCommit(text)
    }

    /** 选中 emoji:上屏 + 记录最近(不写拼音用户词典)。 */
    fun selectEmoji(emoji: String) {
        host.onKeyFeedback()
        host.onCommit(emoji)
        host.recordRecentEmoji(emoji)
    }
    fun isShiftActive() = shiftOn
    fun isCapsLock() = capsLock
    fun isChineseMode() = chineseMode
    fun currentLang() = inputLang
    fun returnVoiceText() = host.localize(KbStr.RETURN_VOICE)
    // 布局切换(26↔九宫格)仅对中文有意义;英/俄/韩隐藏该按钮(返回空串)
    fun layoutSwitchText() = when {
        !chineseMode -> ""
        nineGrid -> host.localize(KbStr.QWERTY)
        else -> host.localize(KbStr.NINEGRID)
    }
    fun enterKeyLabel() = host.enterKeyLabel()
    fun canUndo() = host.canUndo()

    fun handleKey(spec: KeySpec) {
        if (inputBlocked) return
        host.onKeyFeedback()
        // 1 键符号候选态:除再次点 1 键外,任何按键都先退出(点选候选不走此入口,可连点)
        if (spec.type != KeyType.SYM_CANDS) symCandidateMode = false
        when (spec.type) {
            // shiftValue:韩语双辅音/复合元音(ㅂ→ㅃ);拉丁/西里尔大小写由策略内部处理
            KeyType.LETTER -> { onComposingKeystroke(); strategy.onAlpha(if (shiftActive && spec.shiftValue != null) spec.shiftValue else spec.main) }
            KeyType.T9 -> { onComposingKeystroke(); strategy.onAlpha(spec.value ?: return) } // 新数字进待定段,锁定段保持
            KeyType.DELETE -> doDelete()
            KeyType.SPACE -> onSpace()
            KeyType.ENTER -> onEnter()
            KeyType.SHIFT -> onShift()
            KeyType.LANG -> toggleLanguage()
            KeyType.LAYOUT -> toggleLayout()
            // 模式轮换键(全布局常驻):中文九宫格→中文26键→英文→俄语→韩语 循环
            KeyType.MODE_CYCLE -> cycleMode()
            // 分类符号板(最近/中文/英文/括号/数学/序号/货币/箭头)
            KeyType.SYM_BOARD -> { discardComposing(); lastWord = null; symBoardPage = true; symbolPage = false; numberPage = false; emojiPage = false; clipPage = false; renderer?.onEnterSymBoard(); renderer?.rebuildKeyboard(); refreshCandidates() }
            // 手动进数字页 → 会话内粘性(问题3:验证码逐格填充,焦点跳转后仍保持数字键盘)
            KeyType.NUM -> { discardComposing(); lastWord = null; numberPage = true; stickyNumberPage = true; symbolPage = false; symBoardPage = false; renderer?.rebuildKeyboard(); refreshCandidates() }
            KeyType.SYMBOL -> { discardComposing(); lastWord = null; symbolPage = true; numberPage = false; symBoardPage = false; symbolPageIndex = 0; renderer?.rebuildKeyboard(); refreshCandidates() }
            // 手动回字母页 → 解除数字页粘性
            KeyType.ALPHA -> { symbolPage = false; numberPage = false; stickyNumberPage = false; emojiPage = false; clipPage = false; toolsPage = false; symBoardPage = false; renderer?.rebuildKeyboard(); refreshCandidates() }
            KeyType.EMOJI -> { discardComposing(); lastWord = null; emojiPage = true; clipPage = false; symbolPage = false; numberPage = false; symBoardPage = false; renderer?.rebuildKeyboard(); refreshCandidates() }
            KeyType.CLIP -> { if (!isPasswordField()) { discardComposing(); lastWord = null; clipPage = true; emojiPage = false; symbolPage = false; numberPage = false; symBoardPage = false; renderer?.rebuildKeyboard(); refreshCandidates() } }
            KeyType.SYM_PAGE -> { symbolPageIndex = if (symbolPageIndex == 0) 1 else 0; renderer?.rebuildKeyboard() }
            // 9 宫格 1 键(@#):候选栏出固定高频符号候选(对齐豆包;test_key1_symbols.py 模型)
            KeyType.SYM_CANDS -> {
                discardComposing()
                symCandidateMode = true
                refreshCandidates()
            }
            KeyType.SYM_CHAR -> {
                discardComposing()
                val ch = spec.value ?: spec.main
                val closing = SmartPunctuation.closingFor(ch)
                if (closing != null) host.onCommitPair(ch, closing) else host.onCommit(ch)
                // 标点不清空 lastWord:保留句子联想上下文(修联想断链)
                // (v2:标点联想抑制改由 host.textBeforeCursor 实时判定,本分支零改动)
                // 【符号页单击回跳】对齐搜狗/百度/豆包:符号页点一个符号上屏即回到进入前的
                // 输入布局(inputLang/nineGrid 从未被符号页改动,清页即还原);数字例外——
                // 首行 1-0 常用于连续输入年份/金额,回跳会反复弹跳(test_symbol_autoreturn.py 模型)。
                if (symbolPage && !(ch.length == 1 && ch[0].isDigit())) {
                    symbolPage = false; symbolPageIndex = 0
                    renderer?.rebuildKeyboard()
                }
                refreshCandidates()
            }
            KeyType.SYLLABLE -> {
                // 仅 26 键中文的分词键('分隔音节);9 宫格已改用标点键,不再走此分支
                if (nineGrid) { if (composing.isNotEmpty()) currentCandidates().firstOrNull()?.let { selectCandidate(it) } }
                else if (chineseMode) { composing.append('\''); refreshCandidates() }
            }
            KeyType.UNDO -> host.undoLastCommit()
            KeyType.GAP -> {}
        }
    }

    fun handleLongPress(spec: KeySpec) {
        if (inputBlocked) return
        // 长按语种轮换已取消(不可发现):语种/布局切换统一走 MODE_CYCLE 常驻轮换键 + 工具页磁贴
        val v = spec.longValue ?: return
        host.onKeyFeedback()
        discardComposing(); lastWord = null
        // 长按字母(俄语 е→ё)跟随 shift 大小写;数字/符号不受影响
        val out = if (shiftActive && v.length == 1 && v[0].isLetter()) v.uppercase() else v
        host.onCommit(out)
        consumeShift()
        refreshCandidates()
    }

    fun selectCandidate(c: Candidate) {
        if (c.isPunct) {
            // 标点联想候选:直接上屏(不配对)、不学习、保 lastWord(联想链不断)、
            // 同一 lastWord 不再重复推荐标点(词语联想继续)。
            host.onCommit(c.word)
            punctConsumedFor = lastWord
            refreshCandidates()
            return
        }
        if (c.isSymbol) {
            // 1 键符号候选:括号/书名号成套插入(光标后无文字才成套,有文字只插前半;
            // 后半直接上屏);不写词典、不改 lastWord(联想链不断);列表保持可连点。
            val closing = SmartPunctuation.closingFor(c.word)
            if (closing != null && !host.hasTextAfterCursor()) host.onCommitPair(c.word, closing)
            else host.onCommit(c.word)
            refreshCandidates()
            return
        }
        if (c.isEmoji) {
            host.onCommit(c.word)
            host.recordRecentEmoji(c.word)
            // 选 emoji = 放弃当前拼音串(emoji 是该词候选的替代);不改 lastWord(联想链不断)
            composing.setLength(0)
            sessionReset()
            refreshCandidates()
            return
        }
        host.onCommit(c.word)
        // 密码框:不写用户词典/不调频(隐私合规)
        if (!isPasswordField()) engine.learnSequence(lastWord, c.word)
        lastWord = c.word
        // 逐词消耗:消耗该候选的 matchedLen(T9 里拼音长度==数字位数),保留剩余继续打下一词。
        // 如 237449 选「测试」(消耗23744)→ 剩「9」继续打「仪」;残留只是暂留,用户可删。
        val consumedLen = minOf(c.matchedLen, composing.length)
        // 锁定栈从头对齐扣减:已锁定的剩余音节保持锁定,选词后选择器不再重弹(问题2)
        t9ConsumeLocked(consumedLen)
        // 组词会话:记录本次消耗的拼音段(T9 用候选实际读音,26 键用输入字母)
        val consumedPinyin = if (t9Active) {
            if (c.pinyin.isNotEmpty() && c.pinyin.length == consumedLen) c.pinyin else ""
        } else composing.substring(0, consumedLen).filter { it != '\'' }
        sessionRecordPick(c, consumedPinyin)
        val remain = if (c.matchedLen >= composing.length) "" else composing.substring(c.matchedLen)
        composing.setLength(0); composing.append(remain)
        if (composing.isEmpty()) sessionMaybeLearn()
        refreshCandidates()
    }

    /** 空格滑动移光标:仅在无 composing 时移动文档光标。 */
    fun moveCursor(steps: Int) {
        if (inputBlocked || composing.isNotEmpty()) return
        lastWord = null
        host.onMoveCursor(steps)
    }

    /** 长按候选删词:加入黑名单,候选不再出现(emoji/密码框不处理)。 */
    fun forgetCandidate(c: Candidate) {
        if (c.isEmoji || isPasswordField() || c.word.isEmpty()) return
        engine.forget(c.word)
        refreshCandidates()
    }

    fun returnToVoice() = host.onReturnToVoice()
    fun onMicRecordStart() = host.onKeyboardMicStart()
    fun onMicRecordEnd() = host.onKeyboardMicStop()

    fun toggleLayout() {
        discardComposing(); nineGrid = !nineGrid
        host.persistNineGrid(nineGrid)
        composing.setLength(0); symbolPage = false; numberPage = false; stickyNumberPage = false; emojiPage = false; clipPage = false; toolsPage = false; symBoardPage = false; lastWord = null
        strategy = pickStrategy(); strategy.reset()
        renderer?.rebuildKeyboard(); refreshCandidates()
    }

    fun onDeletePressDown() {
        if (inputBlocked) return
        host.onKeyFeedback(); doDelete()
        deleteRepeating = true
        deleteHandler.postDelayed(deleteRunnable, 380L)
    }

    fun onDeletePressUp() {
        deleteRepeating = false; deleteHandler.removeCallbacks(deleteRunnable)
    }

    private fun doDelete() {
        symCandidateMode = false // 长按连删直呼此处,不经 handleKey
        // 韩语组字态:逐 jamo 拆解(닭→달→다→ㄷ),拆完再走文档删除
        if (strategy.onDelete()) return
        // 9 宫格:回退键先 LIFO 撤销上一个点选的音节(问题2:连续回退逐个重选,与脚本验证模型一致);
        // 锁定栈空才删数字
        if (t9Active && composing.isNotEmpty()) {
            if (t9LockedSyllables.isNotEmpty()) {
                t9LockedSyllables.removeAt(t9LockedSyllables.size - 1)
                refreshCandidates(); return
            }
            composing.setLength(composing.length - 1)
            refreshCandidates(); return
        }
        if (composing.isNotEmpty()) { composing.setLength(composing.length - 1); refreshCandidates() }
        else { lastWord = null; sessionReset(); host.onDeleteBeforeCursor(); refreshCandidates() }
    }

    private fun onSpace() {
        if (composing.isNotEmpty()) {
            currentCandidates().firstOrNull()?.let { selectCandidate(it); return }
        }
        strategy.flush() // 韩语:先定稿组合中音节再上屏空格
        // 空格不清空 lastWord:保留句子联想上下文
        host.onCommit(" ")
        refreshCandidates()
    }

    private fun onEnter() {
        if (composing.isNotEmpty()) {
            currentCandidates().firstOrNull()?.let { selectCandidate(it); return }
        }
        strategy.flush()
        lastWord = null
        host.onEnter()
        refreshCandidates()
    }

    private fun onShift() {
        when { capsLock -> { capsLock = false; shiftOn = false }; shiftOn -> capsLock = true; else -> shiftOn = true }
        renderer?.rebuildKeyboard()
    }

    /**
     * LANG 键轮换序列:中英为核心恒在;App 界面语言为俄/韩时对应语种加入环首(该语境下是主输入语言);
     * 用户从工具页临时进入俄/韩键盘时,该语种也入环(可一键轮回中英)。
     * 中英组用户看到的仍是纯 中↔EN 两态,与旧行为完全一致。
     */
    private fun langRing(): List<InputLang> {
        val ring = ArrayList<InputLang>(4)
        val groupDef = host.groupDefaultLang()
        if (groupDef == InputLang.RU || groupDef == InputLang.KO) ring.add(groupDef)
        if ((inputLang == InputLang.RU || inputLang == InputLang.KO) && inputLang !in ring) ring.add(inputLang)
        ring.add(InputLang.ZH); ring.add(InputLang.EN)
        return ring
    }

    private fun toggleLanguage() {
        val ring = langRing()
        val next = ring[(ring.indexOf(inputLang) + 1) % ring.size]
        setLanguage(next)
    }

    /**
     * 模式轮换键:**只循环语言**(中文九宫格 → 英文 → 俄语 → 韩语 → 中文),中文永远沿用记住的布局。
     * 2026-07 修复:旧环把 [中九,中26,英,俄,韩] 串一起,中九→英要经过中26 并 persistNineGrid(false),
     * 之后 LANG 切回中文就停在中26(反人类)。语言与布局解耦(对齐搜狗/Gboard):
     * 语言切换绝不改中文布局偏好;九宫格↔26键由独立布局键/工具页切换(见 toggleLayout)。
     */
    private fun modeRing(): List<InputLang> = listOf(
        InputLang.ZH, InputLang.EN, InputLang.RU, InputLang.KO
    )

    fun cycleMode() {
        val ring = modeRing()
        val idx = ring.indexOf(inputLang).let { if (it < 0) 0 else it }
        val next = ring[(idx + 1) % ring.size]
        discardComposing()
        inputLang = next
        // 语言/布局正交:切语言绝不动 nineGrid(切回中文自动用记住的九宫格/26键偏好)。
        autoEnglishOverride = false
        host.persistInputLang(next)
        composing.setLength(0); symbolPage = false; numberPage = false; emojiPage = false; clipPage = false; toolsPage = false; symBoardPage = false; lastWord = null
        strategy = pickStrategy(); strategy.reset()
        renderer?.rebuildKeyboard(); refreshCandidates()
    }

    /** 轮换键下一模式短标签(画在图标下方,预告下一站语言,用户可预期)。 */
    fun nextModeLabel(): String {
        val ring = modeRing()
        val idx = ring.indexOf(inputLang).let { if (it < 0) 0 else it }
        return ring[(idx + 1) % ring.size].keyLabel
    }

    /** 切换输入语种(LANG 环 / 工具页直达共用):手动选择写回偏好,解除自动接管。 */
    fun setLanguage(lang: InputLang) {
        discardComposing()
        inputLang = lang
        // 用户手动切语种:解除英文框自动切换接管,且写回用户偏好(与业界一致,手动选择优先)
        autoEnglishOverride = false
        host.persistInputLang(lang)
        composing.setLength(0); symbolPage = false; numberPage = false; emojiPage = false; clipPage = false; toolsPage = false; symBoardPage = false; lastWord = null
        strategy = pickStrategy(); strategy.reset()
        renderer?.rebuildKeyboard(); refreshCandidates()
    }

    /** 切换模式时丢弃拼音组合串(不上屏);韩语组合音节例外——已在目标框可见,定稿保留(业界一致)。 */
    private fun discardComposing() {
        strategy.flush()
        t9LockedSyllables.clear(); toolsPage = false
        // 1 键符号候选态一并退出(openTools 等不经 handleKey 的入口);
        // SYM_CANDS 键自身在 discard 之后才置位,不受影响
        symCandidateMode = false
        sessionReset()
        if (composing.isNotEmpty()) {
            composing.setLength(0)
            composingBridge?.clear()
        }
    }

    /**
     * 输入框切换/键盘拉起时的状态复位(问题3:模式保持的核心决策点,对齐 Gboard/搜狗)。
     *  - 数字/电话框:自动进数字键盘页(输入框类型感知,优先级最高)。
     *  - 会话内粘性:用户上个框手动切了数字页(验证码场景),焦点跳到下一格继续保持。
     *  - 邮箱/URI/密码框:自动切英文模式(仅会话内,不写用户偏好);离开后恢复用户偏好。
     *  - 其余状态(composing/符号页/工具页)一律清理,不残留。
     */
    fun reset() {
        t9LockedSyllables.clear()
        symCandidateMode = false
        sessionReset()
        strategy.flush()
        composing.setLength(0); strategy.reset()
        symbolPage = false; numberPage = false; emojiPage = false; clipPage = false; toolsPage = false; symBoardPage = false; symbolPageIndex = 0; lastWord = null
        composingBridge?.clear()
        // App 界面语言跨组切换(中英组↔俄↔韩):清空全部模式暂存,回到新语言组默认键盘。
        // 组内互切(中英界面语言互换)不触发,粘性与语种状态一直生效。
        if (host.consumeLangGroupChange()) {
            stickyNumberPage = false
            autoEnglishOverride = false
            inputLang = host.inputLangDefault()
            strategy = pickStrategy(); strategy.reset()
        }
        if (host.isNumericField() || stickyNumberPage) numberPage = true
        // 英文框自动切英文;离开英文框时恢复用户偏好(autoEnglishOverride 标记"当前英文态是自动切的")
        if (host.isEnglishField()) {
            if (inputLang != InputLang.EN) { inputLang = InputLang.EN; autoEnglishOverride = true; strategy = pickStrategy() }
        } else if (autoEnglishOverride) {
            autoEnglishOverride = false
            val prefer = host.inputLangDefault()
            if (inputLang != prefer) { inputLang = prefer; strategy = pickStrategy() }
        }
        renderer?.rebuildKeyboard(); refreshCandidates()
    }

    /** 键盘会话结束(键盘收起):清除会话级粘性,下次拉起回归输入框类型感知 + 用户偏好。 */
    fun onSessionEnd() {
        strategy.flush()
        stickyNumberPage = false
        if (autoEnglishOverride) {
            autoEnglishOverride = false
            val prefer = host.inputLangDefault()
            if (inputLang != prefer) { inputLang = prefer; strategy = pickStrategy() }
        }
    }

    fun onEngineLoadState(state: PinyinLoadState, detail: String?) {
        val blocked = state == PinyinLoadState.LOADING || state == PinyinLoadState.FAILED
        setInputBlocked(blocked || inputBlocked)
        renderer?.renderEngineState(state, detail)
    }
}
