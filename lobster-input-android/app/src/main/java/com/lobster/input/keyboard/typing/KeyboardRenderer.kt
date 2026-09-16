package com.lobster.input.keyboard.typing

import com.lobster.input.keyboard.pinyin.Candidate
import com.lobster.input.keyboard.pinyin.PinyinLoadState

/** 键盘视图渲染回调(由 [TypingKeyboardView] 实现)。 */
interface KeyboardRenderer {
    fun rebuildKeyboard()
    fun renderCandidates(composingDisplay: String, candidates: List<Candidate>, layoutLabel: String)
    /** 左侧竖排拼音选择器:options=当前编辑段可选读音,active=应高亮项(跟随首候选)。空则隐藏。 */
    fun renderPinyinSelector(options: List<String>, active: String) {}
    fun invalidateKeys()
    /** 进入分类符号板时回调:重置分类选中为「最近」,不记忆上次入口的选择。 */
    fun onEnterSymBoard() {}
    fun setInputBlocked(blocked: Boolean) {}
    fun renderEngineState(state: PinyinLoadState, detail: String?) {}
}
