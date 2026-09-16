package com.lobster.input.keyboard.typing

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import com.lobster.input.ui.theme.LobsterWaterColors
import kotlin.math.sin

/**
 * 音波波形动画(录音态)。竖条高度由实时音量驱动并逐帧插值,叠加正弦相位使动画自然不僵硬。
 * 临近录音上限时染警示色。
 */
@SuppressLint("ViewConstructor")
class WaveformView(context: Context) : View(context) {

    private val density = context.resources.displayMetrics.density
    private fun dp(v: Float) = v * density

    private val barCount = 9
    private val current = FloatArray(barCount)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var level = 0f
    private var warning = false
    private var tick = 0f
    private var animating = false

    fun setLevel(l: Float) { level = l.coerceIn(0f, 1f) }
    fun setWarning(w: Boolean) { warning = w }

    fun start() {
        if (animating) return
        animating = true
        postInvalidateOnAnimation()
    }

    fun stop() {
        animating = false
        level = 0f
        for (i in current.indices) current[i] = 0f
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        if (w <= 0 || h <= 0) return
        val barW = dp(2.6f)
        val gap = dp(3.2f)
        val totalW = barCount * barW + (barCount - 1) * gap
        var x = (w - totalW) / 2f
        val midY = h / 2f
        val maxBar = h * 0.78f
        paint.color = if (warning) LobsterWaterColors.ERROR else LobsterWaterColors.ACCENT

        for (i in 0 until barCount) {
            // 目标高度:音量 × 每根不同相位的正弦,边缘略低,中间略高
            val phase = tick + i * 0.7f
            val shape = 0.45f + 0.55f * ((sin(phase.toDouble()).toFloat() + 1f) / 2f)
            val edge = 1f - kotlin.math.abs(i - (barCount - 1) / 2f) / barCount * 0.5f
            val target = (dp(3f) + level * maxBar * shape * edge).coerceAtMost(maxBar)
            current[i] += (target - current[i]) * 0.28f
            val bh = current[i].coerceAtLeast(dp(3f))
            canvas.drawRoundRect(x, midY - bh / 2f, x + barW, midY + bh / 2f, barW / 2f, barW / 2f, paint)
            x += barW + gap
        }
        if (animating) {
            tick += 0.32f
            postInvalidateOnAnimation()
        }
    }
}
