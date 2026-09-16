package com.lobster.input.keyboard.typing.accessibility

import android.content.Context
import android.view.View
import android.view.accessibility.AccessibilityEvent
import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.keyboard.pinyin.Candidate
import com.lobster.input.keyboard.typing.KeySpec
import com.lobster.input.keyboard.typing.KeyType

/** 键盘无障碍标签与状态播报(集中管理,避免散落)。 */
object TypingAccessibilityLabels {

    fun applyKeyLabel(view: View, spec: KeySpec, context: Context, shiftActive: Boolean, capsLock: Boolean) {
        view.contentDescription = when (spec.type) {
            KeyType.LETTER -> {
                val ch = if (shiftActive || capsLock) spec.main.uppercase() else spec.main
                MobileStrings.a11yKeyLetter(context, ch)
            }
            KeyType.T9 -> MobileStrings.a11yKeyT9(context, spec.main, spec.sub ?: "")
            KeyType.DELETE -> MobileStrings.a11yKeyDelete(context)
            KeyType.SPACE -> MobileStrings.a11yKeySpace(context)
            KeyType.ENTER -> MobileStrings.a11yKeyEnter(context)
            KeyType.SHIFT -> if (capsLock) MobileStrings.a11yKeyCapsLock(context)
            else if (shiftActive) MobileStrings.a11yKeyShiftOn(context)
            else MobileStrings.a11yKeyShift(context)
            KeyType.LANG -> MobileStrings.a11yKeyLang(context)
            KeyType.LAYOUT -> MobileStrings.a11yKeyLayout(context)
            KeyType.SYMBOL, KeyType.NUM -> MobileStrings.a11yKeySymbols(context)
            KeyType.ALPHA -> MobileStrings.a11yKeyAlpha(context)
            KeyType.SYM_PAGE -> MobileStrings.a11yKeySymPage(context)
            KeyType.SYM_CHAR -> MobileStrings.a11yKeyChar(context, spec.main)
            // 模式轮换键:读出下一模式(spec.sub);符号板入口读布局键通用描述
            KeyType.MODE_CYCLE -> MobileStrings.a11yKeyLayout(context) + (spec.sub?.let { " $it" } ?: "")
            KeyType.SYM_BOARD -> MobileStrings.a11yKeySymbols(context)
            // 9 宫格 1 键(@#):高频符号候选入口,读作符号键
            KeyType.SYM_CANDS -> MobileStrings.a11yKeySymbols(context)
            else -> spec.main
        }
    }

    fun announceCandidate(view: View, candidate: Candidate, index: Int) {
        view.contentDescription = "${index + 1}. ${candidate.word}"
    }

    fun announceStatus(view: View, message: String) {
        view.announceForAccessibility(message)
        view.sendAccessibilityEvent(AccessibilityEvent.TYPE_ANNOUNCEMENT)
    }
}
