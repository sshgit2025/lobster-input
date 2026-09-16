package com.lobster.input.keyboard

import android.os.Handler
import android.os.SystemClock

/**
 * 实时识别"打字机"平滑层。
 *
 * 上游(火山 Seed-ASR)在实时输入下吐字是突发的:前沿大约每 ~390ms 跳 ~2 个字,并伴随
 * 偶发 ~1 秒停顿。直接整段替换显示就会"一顿一顿"。本组件把突发到达的 partial 目标文本,
 * 转换成稳定逐字揭示的连续流,改善"边说边出字"的流畅观感。
 *
 * 安全原则(必须遵守,勿破坏业务):
 *  - 只影响"预览显示",绝不参与最终提交;最终权威文本仍由调用方在 finished 后整段提交。
 *  - [setTarget] 每次都用"最新 target 的前缀"重绘,因此火山对已显示区域的"纠正 / 整句替换"
 *    会在下一 tick(≤TICK_MS)立即反映到屏幕,不会丢字、不会显示过期文本。
 *  - [flush] 立即把显示补齐到最新 target(停止 / 收尾时调用),保证被锁定 / 提交的是完整文本。
 *  - 揭示速率随积压自适应:积压越多揭示越快(数百毫秒内追平最新 partial),不给"边说边识别"添加可感知延迟。
 *
 * 非线程安全:所有方法必须在 [handler] 所在线程(主线程)调用。
 */
class TypewriterReveal(
    private val handler: Handler,
    private val render: (String) -> Unit
) {
    private var target: String = ""
    private var revealed: Int = 0
    private var running: Boolean = false
    private var lastRevealAt: Long = 0L

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            stepReveal()
            if (revealed >= target.length) {
                running = false
                return
            }
            handler.postDelayed(this, TICK_MS)
        }
    }

    /** 设置最新目标文本(来自 partial / completed)。已显示区域内的纠正会立即生效。 */
    fun setTarget(text: String) {
        target = text
        clampRevealedToBoundary()
        // 仅在已揭示>0 时重绘已揭示前缀(反映纠正 / 整句替换);
        // revealed==0 时不渲染空串,避免触发 clearRealtimePreview→reset 把刚设的 target 自毁。
        if (revealed > 0) render(currentPrefix())
        if (revealed < target.length && !running) {
            running = true
            lastRevealAt = SystemClock.uptimeMillis()
            handler.postDelayed(tick, TICK_MS)
        }
    }

    /** 立即补齐到最新目标并停止动画(停止 / 收尾时调用)。 */
    fun flush() {
        running = false
        handler.removeCallbacks(tick)
        revealed = target.length
        render(target)
    }

    /** 清空状态并停止动画(会话结束 / 清理时调用,显示清理由调用方负责)。 */
    fun reset() {
        running = false
        handler.removeCallbacks(tick)
        target = ""
        revealed = 0
        lastRevealAt = 0L
    }

    private fun stepReveal() {
        if (revealed >= target.length) return
        val now = SystemClock.uptimeMillis()
        var changed = false
        while (revealed < target.length) {
            val backlog = target.length - revealed
            val interval = when {
                backlog >= FAST_BACKLOG -> FAST_MS
                backlog >= MID_BACKLOG -> MID_MS
                else -> SLOW_MS
            }
            if (now - lastRevealAt < interval) break
            advanceOneGrapheme()
            lastRevealAt += interval
            changed = true
        }
        if (changed) render(currentPrefix())
    }

    /** 前进一个"字":正确跨过 UTF-16 代理对(emoji 等),不切断字符。 */
    private fun advanceOneGrapheme() {
        revealed++
        if (revealed < target.length &&
            Character.isHighSurrogate(target[revealed - 1]) &&
            Character.isLowSurrogate(target[revealed])
        ) {
            revealed++
        }
    }

    /** 目标变更后,确保 revealed 不落在代理对中间。 */
    private fun clampRevealedToBoundary() {
        if (revealed > target.length) revealed = target.length
        if (revealed in 1 until target.length && Character.isLowSurrogate(target[revealed])) {
            revealed--
        }
    }

    private fun currentPrefix(): String {
        if (revealed <= 0) return ""
        if (revealed >= target.length) return target
        return target.substring(0, revealed)
    }

    companion object {
        private const val TICK_MS = 30L
        // 积压字数阈值与对应的逐字间隔(毫秒):积压越大越快,平滑吸收上游停顿。
        private const val FAST_BACKLOG = 8
        private const val MID_BACKLOG = 4
        private const val FAST_MS = 22L
        private const val MID_MS = 55L
        private const val SLOW_MS = 120L
    }
}
