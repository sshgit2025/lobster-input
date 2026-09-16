package com.lobster.input.keyboard.typing.composing

/**
 * 打字模式撤销栈:记录最近上屏文本,支持一键撤销(与语音模式 undo 独立)。
 */
class TypingUndoManager(private val maxDepth: Int = 32) {

    private val stack = ArrayDeque<String>()

    fun record(text: String) {
        if (text.isEmpty()) return
        stack.addLast(text)
        while (stack.size > maxDepth) stack.removeFirst()
    }

    fun canUndo(): Boolean = stack.isNotEmpty()

    fun peek(): String? = stack.lastOrNull()

    fun pop(): String? = if (stack.isEmpty()) null else stack.removeLast()
}
