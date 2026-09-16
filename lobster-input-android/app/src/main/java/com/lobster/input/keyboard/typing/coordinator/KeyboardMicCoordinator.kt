package com.lobster.input.keyboard.typing.coordinator

import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.keyboard.KeyboardRealtimeMic
import com.lobster.input.keyboard.typing.TypingKeyboardView

/**
 * 键盘内流式麦克风协调器:登录/积分/权限校验、错误提示、与按键互斥。
 */
class KeyboardMicCoordinator(
    private val ime: TypingImeContext,
    private val sessionHost: TypingSessionHost,
    private val keyboardMic: KeyboardRealtimeMic
) {
    var typingView: TypingKeyboardView? = null

    fun isActive(): Boolean = ime.isMicRecording()

    fun onRecordStart() {
        val ctx = ime.androidContext()
        if (ime.isMicRecording()) return
        if (!ime.isLoggedIn()) {
            typingView?.stopMicRecordingUI()
            sessionHost.showStatus(MobileStrings.loginRequired(ctx))
            ime.requestExitTypingMode()
            return
        }
        if (!ime.hasRecordPermission()) {
            typingView?.stopMicRecordingUI()
            sessionHost.showStatus(MobileStrings.micPermission(ctx))
            return
        }
        ime.ensureInputAvailable {
            if (ime.isCreditsBlocked()) {
                typingView?.stopMicRecordingUI()
                sessionHost.showStatus(MobileStrings.creditsExhausted(ctx))
                return@ensureInputAvailable
            }
            val auth = ime.authHeader()
            if (auth == null) {
                typingView?.stopMicRecordingUI()
                sessionHost.showStatus(MobileStrings.loginRequired(ctx))
                return@ensureInputAvailable
            }
            sessionHost.clearComposingPreview()
            // 不再整盘阻塞按键:录音中按任意键即结束识别(由 TypingKeyboardView 拦截)
            keyboardMic.start(auth)
        }
    }

    fun onRecordEnd() {
        keyboardMic.stop()
    }

    fun onMicError(message: String) {
        typingView?.stopMicRecordingUI()
        val text = message.ifBlank { MobileStrings.keyboardMicFailed(ime.androidContext()) }
        sessionHost.showStatus(text)
    }

    fun onMicActiveChanged(active: Boolean) {
        if (!active) typingView?.stopMicRecordingUI()
    }
}
