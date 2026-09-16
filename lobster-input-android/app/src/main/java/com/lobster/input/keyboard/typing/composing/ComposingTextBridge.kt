package com.lobster.input.keyboard.typing.composing

import android.view.inputmethod.InputConnection

/**
 * 拼音组合串的目标框同步(桥)。
 *
 * 搜狗式设计:**拼音只在键盘候选区显示,绝不写入目标输入框**——
 * 否则打字时拼音字母会插进用户输入框,选词又追加(如「237449测试」)。
 * 键盘麦克风的实时 ASR 预览走独立的 setComposingText 路径(不经过本桥)。
 */
class ComposingTextBridge {

    fun bind(
        connectionProvider: () -> InputConnection?,
        micActiveProvider: () -> Boolean
    ) { /* 不再需要:拼音不进目标框 */ }

    fun update(composingDisplay: String) { /* no-op:拼音只在候选区显示 */ }

    fun clear() { /* no-op */ }
}
