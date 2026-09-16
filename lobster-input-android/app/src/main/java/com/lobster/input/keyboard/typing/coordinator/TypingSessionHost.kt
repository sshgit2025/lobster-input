package com.lobster.input.keyboard.typing.coordinator

import android.content.Context
import com.lobster.input.core.locale.MobileLanguage
import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.keyboard.KeyboardRealtimeMic
import com.lobster.input.keyboard.pinyin.PinyinLoadState
import com.lobster.input.keyboard.typing.InputLang
import com.lobster.input.keyboard.typing.KbStr
import com.lobster.input.keyboard.typing.TypingKeyboardHost
import com.lobster.input.keyboard.typing.composing.ComposingTextBridge
import com.lobster.input.keyboard.typing.composing.TypingUndoManager
import com.lobster.input.keyboard.typing.editor.EditorActionModel
import com.lobster.input.keyboard.typing.editor.EditorInfoResolver

/**
 * [TypingKeyboardHost] 实现:上屏、组合预览、Enter 动作、撤销、本地化。
 */
class TypingSessionHost(
    private val context: Context,
    private val ime: TypingImeContext,
    private val preferences: TypingPreferences,
    private val composingBridge: ComposingTextBridge,
    private val undoManager: TypingUndoManager,
    private var editorAction: EditorActionModel = EditorActionModel.DEFAULT,
    private var statusCallback: ((String?) -> Unit)? = null,
    private var inputBlockedCallback: ((Boolean) -> Unit)? = null
) : TypingKeyboardHost {

    fun refreshEditorAction() {
        editorAction = EditorInfoResolver.resolve(context, ime.editorInfo())
    }

    fun setStatusCallback(callback: (String?) -> Unit) {
        statusCallback = callback
    }

    fun setInputBlockedCallback(callback: (Boolean) -> Unit) {
        inputBlockedCallback = callback
    }

    override fun onCommit(text: String) {
        composingBridge.clear()
        ime.inputConnection()?.commitText(text, 1)
        undoManager.record(text)
    }

    // 韩语组字预览:组合中音节直接写目标框(setComposingText,业界标准的光标下划线预览)
    override fun onComposingText(text: String) {
        ime.inputConnection()?.setComposingText(text, 1)
    }

    override fun onFinishComposing() {
        ime.inputConnection()?.finishComposingText()
    }

    override fun onCommitPair(opening: String, closing: String) {
        composingBridge.clear()
        val ic = ime.inputConnection()
        if (ic == null) { undoManager.record(opening); return }
        ic.beginBatchEdit()
        ic.commitText(opening + closing, 1)
        val pos = ic.getTextBeforeCursor(Int.MAX_VALUE, 0)?.length ?: (opening.length + closing.length)
        ic.setSelection(pos - closing.length, pos - closing.length)
        ic.endBatchEdit()
        // 撤销时按整体回退;记录两字符长度
        undoManager.record(opening + closing)
    }

    override fun hasTextAfterCursor(): Boolean =
        ime.inputConnection()?.getTextAfterCursor(1, 0)?.isNotEmpty() == true

    override fun textBeforeCursor(maxChars: Int): String =
        ime.inputConnection()?.getTextBeforeCursor(maxChars, 0)?.toString() ?: ""

    override fun onMoveCursor(dx: Int) {
        val ic = ime.inputConnection() ?: return
        if (dx == 0) return
        val pos = ic.getTextBeforeCursor(Int.MAX_VALUE, 0)?.length ?: return
        val after = ic.getTextAfterCursor(Int.MAX_VALUE, 0)?.length ?: 0
        val target = (pos + dx).coerceIn(0, pos + after)
        ic.setSelection(target, target)
    }

    override fun onDeleteBeforeCursor() {
        val ic = ime.inputConnection() ?: return
        val selected = ic.getSelectedText(0)
        if (!selected.isNullOrEmpty()) ic.commitText("", 1) else ic.deleteSurroundingText(1, 0)
    }

    override fun onEnter() {
        composingBridge.clear()
        val ic = ime.inputConnection() ?: return
        when (editorAction.action) {
            EditorActionModel.EditorInfoAction.SEARCH -> {
                ic.performEditorAction(android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH)
            }
            EditorActionModel.EditorInfoAction.SEND -> {
                ic.performEditorAction(android.view.inputmethod.EditorInfo.IME_ACTION_SEND)
            }
            EditorActionModel.EditorInfoAction.GO -> {
                ic.performEditorAction(android.view.inputmethod.EditorInfo.IME_ACTION_GO)
            }
            EditorActionModel.EditorInfoAction.DONE -> {
                ic.performEditorAction(android.view.inputmethod.EditorInfo.IME_ACTION_DONE)
            }
            EditorActionModel.EditorInfoAction.NEXT -> {
                ic.performEditorAction(android.view.inputmethod.EditorInfo.IME_ACTION_NEXT)
            }
            EditorActionModel.EditorInfoAction.PREVIOUS -> {
                ic.performEditorAction(android.view.inputmethod.EditorInfo.IME_ACTION_PREVIOUS)
            }
            EditorActionModel.EditorInfoAction.NEWLINE -> {
                if (!ic.commitText("\n", 1)) {
                    val t = System.currentTimeMillis()
                    ic.sendKeyEvent(android.view.KeyEvent(t, t, android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ENTER, 0))
                    ic.sendKeyEvent(android.view.KeyEvent(t, t, android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_ENTER, 0))
                }
            }
        }
    }

    override fun onReturnToVoice() = ime.requestExitTypingMode()

    override fun onKeyboardMicStart() { /* 由 KeyboardMicCoordinator 处理 */ }

    override fun onKeyboardMicStop() { /* 由 KeyboardMicCoordinator 处理 */ }

    override fun isChineseModeDefault(): Boolean = preferences.chineseMode

    override fun persistChineseMode(chinese: Boolean) {
        preferences.chineseMode = chinese
    }

    override fun inputLangDefault(): InputLang = InputLang.fromCode(preferences.inputLang)

    override fun persistInputLang(lang: InputLang) {
        preferences.inputLang = lang.code
        // 中英偏好联动(向后兼容旧逻辑读取点);俄/韩不动 chineseMode
        if (lang == InputLang.ZH || lang == InputLang.EN) preferences.chineseMode = lang == InputLang.ZH
    }

    /** App 界面语言 → 语言组(中英组含粤语/繁体)与组默认输入语种。 */
    private fun appLangGroup(): Pair<String, InputLang> = when (MobileStrings.currentLanguage(context)) {
        MobileLanguage.RU -> "ru" to InputLang.RU
        MobileLanguage.KO -> "ko" to InputLang.KO
        MobileLanguage.EN -> "zhen" to InputLang.EN
        else -> "zhen" to InputLang.ZH // zh / zh-Hant / yue 均属中文
    }

    override fun groupDefaultLang(): InputLang = appLangGroup().second

    override fun consumeLangGroupChange(): Boolean {
        val (group, def) = appLangGroup()
        val last = preferences.langGroup
        preferences.langGroup = group
        // 首次(无记录):中英组不算切换;俄/韩界面首启也要落到对应语种键盘
        if (last == null && group != "zhen") {
            preferences.inputLang = def.code
            return true
        }
        // 组内互切(中英互换界面语言)不清暂存
        if (last == null || last == group) return false
        // 跨组切换:清空暂存、恢复初始化——输入语种重置为新组默认
        // (zh/繁/粤界面→中文,en界面→英文,ru→俄语,ko→韩语),中英偏好同步对齐
        preferences.inputLang = def.code
        if (def == InputLang.ZH || def == InputLang.EN) preferences.chineseMode = def == InputLang.ZH
        return true
    }

    override fun isNineGridDefault(): Boolean = preferences.nineGrid

    override fun persistNineGrid(nine: Boolean) {
        preferences.nineGrid = nine
    }

    override fun onKeyFeedback() = ime.performKeyHaptic()

    override fun localize(key: KbStr): String = when (key) {
        KbStr.RETURN_VOICE -> MobileStrings.returnVoice(context)
        KbStr.SPACE -> MobileStrings.spaceKey(context)
        KbStr.CH -> MobileStrings.imeChineseLabel(context)
        KbStr.EN -> MobileStrings.imeEnglishLabel(context)
        KbStr.NINEGRID -> MobileStrings.nineGridLabel(context)
        KbStr.QWERTY -> MobileStrings.qwertyLabel(context)
        KbStr.SYMBOL -> MobileStrings.symbolKeyLabel(context)
        KbStr.SWITCH_QWERTY -> MobileStrings.switchQwertyLabel(context)
        KbStr.PINYIN -> MobileStrings.pinyinKeyLabel(context)
        KbStr.ABC -> MobileStrings.abcKeyLabel(context)
        KbStr.SYLLABLE -> MobileStrings.syllableSepKey(context)
        KbStr.UNDO -> MobileStrings.undo(context)
    }

    override fun enterKeyLabel(): String = editorAction.label

    override fun isPasswordField(): Boolean = editorAction.isPassword

    override fun isNumericField(): Boolean = editorAction.isNumeric

    override fun isEnglishField(): Boolean = editorAction.isEnglish

    override fun isMicAvailable(): Boolean = ime.isLoggedIn()

    fun canRememberTypingMode(): Boolean = preferences.rememberTypingMode

    fun lastModeKeyboard(): Boolean = preferences.lastModeKeyboard
    fun setLastModeKeyboard(value: Boolean) { preferences.lastModeKeyboard = value }

    fun fuzzySettings() = preferences.fuzzySettings()

    override fun recordRecentEmoji(emoji: String) = preferences.recordRecentEmoji(emoji)

    override fun recentEmojis(): List<String> = preferences.recentEmojis()

    override fun recordRecentSymbol(symbol: String) = preferences.recordRecentSymbol(symbol)

    override fun recentSymbols(): List<String> = preferences.recentSymbols()

    private val clipboardStore = ClipboardStore(context)

    // 密码框不读剪贴板(隐私)
    override fun clipboardHistory(): List<String> =
        if (isPasswordField()) emptyList() else clipboardStore.snapshotAndGet()

    override fun quickPhrases(): List<String> =
        if (isPasswordField()) emptyList() else clipboardStore.quickPhrases()

    override fun removeClipboardItem(item: String) = clipboardStore.removeHistory(item)

    override fun clearClipboard() = clipboardStore.clearHistory()

    fun updateComposingPreview(text: String) = composingBridge.update(text)

    fun clearComposingPreview() = composingBridge.clear()

    fun showStatus(message: String?) = statusCallback?.invoke(message)

    fun setInputBlocked(blocked: Boolean) = inputBlockedCallback?.invoke(blocked)

    override fun canUndo(): Boolean = undoManager.canUndo()

    override fun undoLastCommit() {
        val last = undoManager.pop() ?: return
        val ic = ime.inputConnection() ?: return
        ic.deleteSurroundingText(last.length, 0)
        // 不再弹"已撤销"状态提示:它会让候选栏多出一行、顶高输入面板,体验差
    }

    fun notifyEngineState(state: PinyinLoadState, detail: String?) {
        val msg = when (state) {
            PinyinLoadState.LOADING -> MobileStrings.pinyinDictLoading(context)
            PinyinLoadState.FAILED -> detail ?: MobileStrings.pinyinDictFailed(context)
            PinyinLoadState.READY -> null
            PinyinLoadState.IDLE -> null
        }
        showStatus(msg)
        setInputBlocked(state == PinyinLoadState.LOADING || state == PinyinLoadState.FAILED)
    }
}
