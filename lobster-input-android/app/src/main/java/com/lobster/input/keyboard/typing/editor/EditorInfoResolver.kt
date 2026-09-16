package com.lobster.input.keyboard.typing.editor

import android.content.Context
import android.text.InputType
import android.view.inputmethod.EditorInfo
import com.lobster.input.core.locale.MobileStrings

/** 从 [EditorInfo] 解析 Enter 键标签与动作(策略模式入口)。 */
object EditorInfoResolver {

    fun resolve(context: Context, info: EditorInfo?): EditorActionModel {
        if (info == null) return EditorActionModel.DEFAULT
        val imeOptions = info.imeOptions and EditorInfo.IME_MASK_ACTION
        val inputType = info.inputType
        val typeClass = inputType and InputType.TYPE_MASK_CLASS
        val multiline = (inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE) != 0
        val isPassword = typeClass == InputType.TYPE_CLASS_TEXT &&
            (inputType and InputType.TYPE_TEXT_VARIATION_PASSWORD) != 0 ||
            typeClass == InputType.TYPE_CLASS_NUMBER &&
            (inputType and InputType.TYPE_NUMBER_VARIATION_PASSWORD) != 0
        // 数字/电话/日期时间输入框 → 自动数字键盘(对齐 Gboard/搜狗)
        val isNumeric = typeClass == InputType.TYPE_CLASS_NUMBER ||
            typeClass == InputType.TYPE_CLASS_PHONE ||
            typeClass == InputType.TYPE_CLASS_DATETIME
        // 邮箱/URI/密码/账号类文本框 → 自动英文模式(对齐 Gboard/搜狗;仅本次会话,不覆盖用户偏好)
        val textVariation = inputType and InputType.TYPE_MASK_VARIATION
        val isEnglish = typeClass == InputType.TYPE_CLASS_TEXT && (
            textVariation == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
                textVariation == InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS ||
                textVariation == InputType.TYPE_TEXT_VARIATION_URI ||
                textVariation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                textVariation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                textVariation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            )

        val action = when (imeOptions) {
            EditorInfo.IME_ACTION_SEARCH -> EditorActionModel.EditorInfoAction.SEARCH
            EditorInfo.IME_ACTION_SEND -> EditorActionModel.EditorInfoAction.SEND
            EditorInfo.IME_ACTION_GO -> EditorActionModel.EditorInfoAction.GO
            EditorInfo.IME_ACTION_DONE -> EditorActionModel.EditorInfoAction.DONE
            EditorInfo.IME_ACTION_NEXT -> EditorActionModel.EditorInfoAction.NEXT
            EditorInfo.IME_ACTION_PREVIOUS -> EditorActionModel.EditorInfoAction.PREVIOUS
            else -> if (multiline) EditorActionModel.EditorInfoAction.NEWLINE
            else EditorActionModel.EditorInfoAction.NEWLINE
        }

        val label = when (action) {
            EditorActionModel.EditorInfoAction.SEARCH -> MobileStrings.enterSearch(context)
            EditorActionModel.EditorInfoAction.SEND -> MobileStrings.enterSend(context)
            EditorActionModel.EditorInfoAction.GO -> MobileStrings.enterGo(context)
            EditorActionModel.EditorInfoAction.DONE -> MobileStrings.enterDone(context)
            EditorActionModel.EditorInfoAction.NEXT -> MobileStrings.enterNext(context)
            EditorActionModel.EditorInfoAction.PREVIOUS -> MobileStrings.enterPrevious(context)
            EditorActionModel.EditorInfoAction.NEWLINE -> MobileStrings.enterNewline(context)
        }
        return EditorActionModel(label, action, multiline, isPassword, isNumeric, isEnglish)
    }
}
