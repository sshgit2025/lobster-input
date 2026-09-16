package com.lobster.input.keyboard.typing.editor

import android.view.inputmethod.EditorInfo

/** Enter 键展示与行为模型(由 [EditorInfoResolver] 解析)。 */
data class EditorActionModel(
    val label: String,
    val action: EditorInfoAction,
    val multiline: Boolean,
    val isPassword: Boolean,
    /** 数字/电话/日期时间类输入框:键盘应自动进入数字键盘页(业界标准)。 */
    val isNumeric: Boolean = false,
    /** 邮箱/URI/密码类 ASCII 输入框:键盘应自动进入英文模式(对齐 Gboard/搜狗,不覆盖用户偏好)。 */
    val isEnglish: Boolean = false
) {
    enum class EditorInfoAction {
        NEWLINE,
        SEARCH,
        SEND,
        GO,
        DONE,
        NEXT,
        PREVIOUS
    }

    companion object {
        val DEFAULT = EditorActionModel("↵", EditorInfoAction.NEWLINE, multiline = false, isPassword = false)
    }
}
