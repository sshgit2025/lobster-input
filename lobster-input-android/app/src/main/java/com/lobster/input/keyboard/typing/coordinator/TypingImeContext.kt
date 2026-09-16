package com.lobster.input.keyboard.typing.coordinator

import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.content.Context

/**
 * 打字模式所需的 IME 宿主能力(依赖倒置,避免 Typing 模块直接耦合 LobsterIME 3000 行实现)。
 */
interface TypingImeContext {
    fun androidContext(): Context
    fun inputConnection(): InputConnection?
    fun editorInfo(): EditorInfo?
    fun isLoggedIn(): Boolean
    fun authHeader(): String?
    fun isCreditsBlocked(): Boolean
    fun ensureInputAvailable(onReady: () -> Unit)
    fun showTypingMessage(message: String)
    fun performKeyHaptic()
    fun refreshKeyboardUi()
    fun onTypingModeChanged(active: Boolean)
    fun isMicRecording(): Boolean
    fun requestExitTypingMode()
    fun hasRecordPermission(): Boolean
}

enum class TypingBlockedReason {
    LOGIN_REQUIRED,
    CREDITS_EXHAUSTED,
    MIC_PERMISSION
}
