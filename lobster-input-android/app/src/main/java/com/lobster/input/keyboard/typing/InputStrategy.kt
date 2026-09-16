package com.lobster.input.keyboard.typing

import com.lobster.input.keyboard.pinyin.Candidate
import com.lobster.input.keyboard.pinyin.PinyinEngine

/**
 * 输入策略(策略模式)。把"按字母键如何变成文本/候选"的差异封装到各策略中,
 * 让 [KeyboardController] 无需对中/英 × 26/9 做散落的 if/else。
 */
interface InputStrategy {
    /** 字母键:26 键传字母,9 宫格传数字字符串,韩语传 jamo。 */
    fun onAlpha(value: String)
    /** 基于当前组合串产出候选(英文/俄语/韩语策略返回空)。 */
    fun candidates(): List<Candidate>
    /** 候选栏组合显示(英文/俄语/韩语策略返回空串)。 */
    fun composingDisplay(): String
    /** 切换到本策略时复位内部状态。 */
    fun reset() {}
    /** 删除键:返回 true 表示已在策略内部消化(韩语组字逐 jamo 拆解),false 走默认删除。 */
    fun onDelete(): Boolean = false
    /** 输入中断点(空格/回车/标点/切页/切语言):定稿策略内部组合态(韩语当前音节)。 */
    fun flush() {}
}

/** 策略运行上下文(由 Controller 实现),供策略读写组合串、上屏、刷新。 */
interface StrategyContext {
    val composing: StringBuilder
    val engine: PinyinEngine
    val shiftActive: Boolean
    fun commit(text: String)
    fun deleteBeforeCursor()
    fun refreshCandidates()
    fun consumeShift()
    /** 组合预览写入目标框(韩语组字音节,setComposingText 通道;拼音不走此通道)。 */
    fun composingText(text: String)
    /** 定稿目标框中的组合预览(finishComposingText)。 */
    fun finishComposing()
}

/** 中文 · 26 键全拼。 */
class ChineseQwertyStrategy(private val ctx: StrategyContext) : InputStrategy {
    override fun onAlpha(value: String) {
        ctx.composing.append(value.lowercase()); ctx.refreshCandidates()
    }
    override fun candidates() = ctx.engine.candidates(ctx.composing.toString())
    override fun composingDisplay() =
        if (ctx.composing.isEmpty()) "" else ctx.engine.displaySegmented(ctx.composing.toString())
}

/** 中文 · 9 宫格 T9。候选从最优拼音切分生成(与显示拼音一一对应)。 */
class ChineseT9Strategy(private val ctx: StrategyContext) : InputStrategy {
    override fun onAlpha(value: String) {
        ctx.composing.append(value); ctx.refreshCandidates()
    }
    override fun candidates() = ctx.engine.candidatesForT9(ctx.composing.toString())
    override fun composingDisplay() = ""
}

/** 英文 · 26 键直接上屏。 */
class EnglishQwertyStrategy(private val ctx: StrategyContext) : InputStrategy {
    override fun onAlpha(value: String) {
        val out = if (ctx.shiftActive) value.uppercase() else value.lowercase()
        ctx.commit(out); ctx.consumeShift()
    }
    override fun candidates() = emptyList<Candidate>()
    override fun composingDisplay() = ""
}

/** 俄语 · ЙЦУКЕН 直接上屏(西里尔字母大小写随 shift;ё 由 е 长按提供,布局层配置)。 */
class RussianStrategy(private val ctx: StrategyContext) : InputStrategy {
    override fun onAlpha(value: String) {
        val out = if (ctx.shiftActive) value.uppercase() else value.lowercase()
        ctx.commit(out); ctx.consumeShift()
    }
    override fun candidates() = emptyList<Candidate>()
    override fun composingDisplay() = ""
}

/**
 * 韩语 · 2-set(두벌식)组字上屏。jamo 经 [HangulComposer] 组字:
 * 定稿部分 commit,组合中音节走 setComposingText 预览(业界标准,光标下带下划线);
 * 删除键优先在组合内逐 jamo 拆解;空格/回车/标点/切页先 flush 定稿。
 */
class KoreanStrategy(private val ctx: StrategyContext) : InputStrategy {
    private val composer = HangulComposer()

    override fun onAlpha(value: String) {
        val jamo = value.firstOrNull() ?: return
        val committed = composer.feed(jamo)
        // commitText 会替换当前组合预览区并定稿(标准 IC 语义),无需先 finishComposing
        if (committed.isNotEmpty()) ctx.commit(committed)
        syncPreview()
        ctx.consumeShift()
    }

    override fun onDelete(): Boolean {
        if (composer.isEmpty()) return false
        composer.backspace()
        syncPreview()
        return true
    }

    override fun flush() {
        if (composer.isEmpty()) return
        // 组合预览已显示当前音节,finishComposingText 直接把它定稿进文档
        composer.reset()
        ctx.finishComposing()
    }

    override fun reset() { composer.reset() }
    override fun candidates() = emptyList<Candidate>()
    override fun composingDisplay() = ""

    private fun syncPreview() {
        val cur = composer.current()
        if (cur.isEmpty()) { ctx.composingText(""); ctx.finishComposing() } else ctx.composingText(cur)
    }
}

// 英文 T9 多击策略已废弃:英文一律 26 键(对齐搜狗/Gboard,九宫格中文切英文直接变 26 键英文)。
