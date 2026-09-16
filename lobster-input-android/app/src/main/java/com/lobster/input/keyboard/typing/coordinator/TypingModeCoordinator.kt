package com.lobster.input.keyboard.typing.coordinator

import com.lobster.input.keyboard.pinyin.PinyinEngine
import com.lobster.input.keyboard.typing.TypingKeyboardView
import com.lobster.input.keyboard.typing.composing.ComposingTextBridge

/**
 * 打字模式总协调器:组装 SessionHost、ComposingBridge、MicCoordinator 与 TypingKeyboardView。
 */
class TypingModeCoordinator(
    private val sessionHost: TypingSessionHost,
    private val composingBridge: ComposingTextBridge,
    private val micCoordinator: KeyboardMicCoordinator,
    val engine: PinyinEngine
) {
    var typingView: TypingKeyboardView? = null
        set(value) {
            field = value
            micCoordinator.typingView = value
        }

    var active = false
        private set

    private val loadListener = com.lobster.input.keyboard.pinyin.PinyinLoadListener { state, detail ->
        typingView?.onEngineLoadState(state, detail)
        sessionHost.notifyEngineState(state, detail)
    }

    init {
        engine.addLoadListener(loadListener)
        engine.setFuzzy(sessionHost.fuzzySettings())
    }

    fun createTypingView(context: android.content.Context): TypingKeyboardView {
        val view = TypingKeyboardView(context, sessionHost, engine, composingBridge, micCoordinator)
        typingView = view
        return view
    }

    fun enter() {
        active = true
        sessionHost.refreshEditorAction()
        engine.setFuzzy(sessionHost.fuzzySettings())
        typingView?.resetComposing()
        typingView?.refreshEnterKey()
    }

    fun exit() {
        active = false
        composingBridge.clear()
    }

    fun onStartInputView() {
        sessionHost.refreshEditorAction()
        typingView?.refreshEnterKey()
        // 每次拉起输入法都清理上次未完成的 composing/候选(失焦再聚焦不该残留);与"记住模式"无关
        typingView?.resetComposing()
    }

    /** 键盘窗口收起(会话结束):清除会话级模式粘性(数字页粘性/英文框自动切换)。 */
    fun onSessionEnd() = typingView?.onSessionEnd()

    fun resetComposing() = typingView?.resetComposing()
}

