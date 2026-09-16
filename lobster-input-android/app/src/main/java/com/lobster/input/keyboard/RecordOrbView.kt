package com.lobster.input.keyboard

import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.view.Choreographer
import android.view.View
import com.lobster.input.ui.theme.LobsterWaterColors
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * 蓝宝石玻璃涟漪录音钮（仅 UI，色值全部收敛引用 LobsterWaterColors）。
 * 默认态与录音态共用同一套扩散算法；录音时仅略增发射频率，音量不挤压涟漪到中心。
 */
class RecordOrbView(context: Context) : View(context) {

    private data class Ripple(
        var radius: Float,
        var phase1: Float,
        var phase2: Float,
        var amplitude: Float,
        var life: Float,
        var speed: Float,
        var waves1: Int,
        var waves2: Int
    )

    private enum class Mode { IDLE, RECORDING, PROCESSING }

    private object Water {
        const val BG_TOP = LobsterWaterColors.ORB_TOP
        const val BG_BOTTOM = LobsterWaterColors.ORB_BOTTOM
        const val RIM = LobsterWaterColors.ORB_RIM
        const val RIPPLE_DEEP = LobsterWaterColors.ACCENT_DEEP
        const val RIPPLE_MID = LobsterWaterColors.ACCENT_BRIGHT
        const val RIPPLE_LIGHT = LobsterWaterColors.ACCENT_SOFT
        const val MIC = LobsterWaterColors.ACCENT_DEEP
        const val MIC_HI = LobsterWaterColors.ORB_MIC_HI
        const val MAX_WOBBLE_PX = 2f
        const val FLOW_PHASE_STEP = 0.022f
        const val RIPPLE_PHASE_STEP = 0.018f
        const val REF_ORB_RADIUS_PX = 29f
        const val FRAME_INTERVAL_NS = 33_333_333L
        const val LIFE_DECAY_PER_SEC = 0.21f
        const val EXPAND = 0.28f
        const val IDLE_VISUAL_ENERGY = 0.16f
        const val MAX_RIPPLES = 3
    }

    private var mode = Mode.IDLE
    private var loggedIn = true
    private var energy = 0f
    private var smoothedEnergy = 0f
    private var flowPhase = 0f
    private var processingPhase = 0
    private var lastSpawnNs = 0L
    private var lastProcessingNs = 0L
    private var lastFrameNs = 0L
    private var orbRadiusPx = Water.REF_ORB_RADIUS_PX
    private val ripples = mutableListOf<Ripple>()

    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val shimmerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val ripplePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private val frame = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (width <= 0 || height <= 0) {
                Choreographer.getInstance().postFrameCallback(this)
                return
            }
            if (lastFrameNs != 0L && frameTimeNanos - lastFrameNs < Water.FRAME_INTERVAL_NS) {
                Choreographer.getInstance().postFrameCallback(this)
                return
            }
            val dt = if (lastFrameNs == 0L) {
                1f / 30f
            } else {
                ((frameTimeNanos - lastFrameNs) / 1_000_000_000f).coerceIn(1f / 120f, 0.05f)
            }
            lastFrameNs = frameTimeNanos
            val frameScale = dt * 30f

            flowPhase += Water.FLOW_PHASE_STEP * frameScale
            if (mode == Mode.RECORDING) {
                smoothedEnergy += (energy.coerceIn(0f, 1f) - smoothedEnergy) * (0.06f * frameScale)
            } else {
                smoothedEnergy = 0f
            }

            when (mode) {
                Mode.RECORDING -> {
                    val intervalMs = (2400 - 500 * smoothedEnergy).toLong().coerceIn(1800L, 2400L)
                    if (ripples.size < Water.MAX_RIPPLES &&
                        (lastSpawnNs == 0L || frameTimeNanos - lastSpawnNs >= intervalMs * 1_000_000L)
                    ) {
                        spawnIdleStyleRipple()
                        lastSpawnNs = frameTimeNanos
                    }
                }
                Mode.IDLE -> {
                    if (lastSpawnNs == 0L || frameTimeNanos - lastSpawnNs > 3_200_000_000L) {
                        spawnIdleStyleRipple()
                        lastSpawnNs = frameTimeNanos
                    }
                }
                Mode.PROCESSING -> {
                    if (lastProcessingNs == 0L || frameTimeNanos - lastProcessingNs > 400_000_000L) {
                        processingPhase = (processingPhase + 1) % 3
                        lastProcessingNs = frameTimeNanos
                    }
                    if (lastSpawnNs == 0L || frameTimeNanos - lastSpawnNs > 850_000_000L) {
                        spawnIdleStyleRipple()
                        lastSpawnNs = frameTimeNanos
                    }
                }
            }

            val maxR = orbRadiusPx * 0.80f
            val it = ripples.iterator()
            while (it.hasNext()) {
                val r = it.next()
                r.radius += r.speed * Water.EXPAND * frameScale
                r.phase1 += Water.RIPPLE_PHASE_STEP * frameScale
                r.phase2 -= Water.RIPPLE_PHASE_STEP * 0.6f * frameScale
                r.life -= Water.LIFE_DECAY_PER_SEC * dt
                if (r.life <= 0f || r.radius >= maxR) it.remove()
            }
            invalidate()
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        orbRadiusPx = min(w, h) * 0.46f
    }

    private fun sizeScale(): Float = (orbRadiusPx / Water.REF_ORB_RADIUS_PX).coerceIn(0.9f, 3.2f)

    fun setOrbState(recording: Boolean, processing: Boolean, loggedIn: Boolean, level: Float) {
        val newMode = when {
            processing -> Mode.PROCESSING
            recording -> Mode.RECORDING
            else -> Mode.IDLE
        }
        if (newMode != mode) {
            ripples.clear()
            lastSpawnNs = 0L
        }
        this.loggedIn = loggedIn
        energy = level.coerceIn(0f, 1f)
        mode = newMode
        alpha = if (loggedIn && mode != Mode.PROCESSING) 1f else if (mode == Mode.PROCESSING) 0.9f else 0.48f
        isEnabled = loggedIn && mode != Mode.PROCESSING
        if (mode == Mode.IDLE) {
            energy = 0f
            smoothedEnergy = 0f
        }
        startAnim()
        invalidate()
    }

    /**
     * 录音过程中高频更新声浪能量。仅改 energy,由内部 Choreographer 帧循环消费,
     * 避免每个音频帧都触发整个键盘面板的全量刷新(那会造成无谓的文案重算/重绘)。
     */
    fun updateLevel(level: Float) {
        energy = level.coerceIn(0f, 1f)
    }

    override fun setPressed(pressed: Boolean) {
        super.setPressed(pressed)
        if (pressed && ripples.size < Water.MAX_RIPPLES) spawnIdleStyleRipple()
        animate().cancel()
        animate().scaleX(if (pressed) 1.07f else 1f).scaleY(if (pressed) 1.07f else 1f).setDuration(180).start()
    }

    /** 与默认态相同的单圈涟漪，不随音量改变波峰/振幅/速度 */
    private fun spawnIdleStyleRipple() {
        val scale = sizeScale()
        val ec = Water.IDLE_VISUAL_ENERGY
        val wobbleCap = Water.MAX_WOBBLE_PX * min(scale, 1.8f)
        val wobble = minOf(wobbleCap, (0.85f + ec * 0.65f) * min(scale, 1.35f))
        ripples.add(
            Ripple(
                radius = orbRadiusPx * 0.11f,
                phase1 = flowPhase,
                phase2 = flowPhase * 0.5f,
                amplitude = wobble,
                life = 1f,
                speed = (0.30f + ec * 0.14f) * scale,
                waves1 = 3,
                waves2 = 2
            )
        )
    }

    private fun startAnim() {
        stopAnim()
        lastSpawnNs = 0L
        lastFrameNs = 0L
        Choreographer.getInstance().postFrameCallback(frame)
    }

    private fun stopAnim() {
        Choreographer.getInstance().removeFrameCallback(frame)
        ripples.clear()
        lastFrameNs = 0L
    }

    override fun onDetachedFromWindow() {
        stopAnim()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = orbRadiusPx
        val pill = RectF(cx - r, cy - r * 0.88f, cx + r, cy + r * 0.88f)

        drawBackground(canvas, pill)
        drawShimmer(canvas, pill)
        for (ripple in ripples) drawRipple(canvas, cx, cy, ripple)
        drawMic(canvas, cx, cy)
    }

    private fun drawBackground(canvas: Canvas, pill: RectF) {
        bgPaint.shader = LinearGradient(
            pill.left, pill.top, pill.left, pill.bottom,
            intArrayOf(Water.BG_TOP, Water.BG_BOTTOM),
            floatArrayOf(0f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawRoundRect(pill, pill.height() / 2f, pill.height() / 2f, bgPaint)
        bgPaint.shader = null
        rimPaint.color = Water.RIM
        rimPaint.strokeWidth = if (mode == Mode.RECORDING) 1.6f else 1.1f
        canvas.drawRoundRect(pill, pill.height() / 2f, pill.height() / 2f, rimPaint)
    }

    private fun drawShimmer(canvas: Canvas, pill: RectF) {
        val path = Path()
        val y = pill.top + pill.height() * 0.38f
        val amp = 0.55f
        val steps = 24
        for (i in 0..steps) {
            val t = i / steps.toFloat()
            val x = pill.left + 6f + t * (pill.width() - 12f)
            val py = y + amp * sin(t * Math.PI.toFloat() * 3.2f + flowPhase)
            if (i == 0) path.moveTo(x, py) else path.lineTo(x, py)
        }
        shimmerPaint.color = Water.RIPPLE_LIGHT and 0x00FFFFFF or
            (((0.35f + if (mode == Mode.RECORDING) 0.08f else 0f) * 255).toInt().coerceIn(0, 255) shl 24)
        shimmerPaint.strokeWidth = 1f
        canvas.drawPath(path, shimmerPaint)
    }

    private fun drawRipple(canvas: Canvas, cx: Float, cy: Float, ripple: Ripple) {
        val path = irregularRing(
            cx, cy, ripple.radius,
            ripple.amplitude * ripple.life,
            ripple.waves1, ripple.waves2,
            ripple.phase1, ripple.phase2
        )
        val a = ripple.life * if (mode == Mode.RECORDING) 0.68f else 0.5f
        ripplePaint.color = Water.RIPPLE_DEEP and 0x00FFFFFF or ((a * 0.35f * 255).toInt() shl 24)
        ripplePaint.strokeWidth = 1.6f
        canvas.drawPath(path, ripplePaint)
        ripplePaint.color = Water.RIPPLE_MID and 0x00FFFFFF or ((a * 0.55f * 255).toInt() shl 24)
        ripplePaint.strokeWidth = 1f
        canvas.drawPath(path, ripplePaint)
        ripplePaint.color = Water.RIPPLE_LIGHT and 0x00FFFFFF or ((a * 0.4f * 255).toInt() shl 24)
        ripplePaint.strokeWidth = 0.6f
        canvas.drawPath(path, ripplePaint)
    }

    private fun irregularRing(
        cx: Float, cy: Float, radius: Float, amp: Float,
        waves1: Int, waves2: Int, phase1: Float, phase2: Float
    ): Path {
        val path = Path()
        val n = 56
        for (i in 0..n) {
            val t = i / n.toFloat() * (Math.PI * 2).toFloat()
            val wobble = amp * sin(waves1 * t + phase1) + amp * 0.15f * sin(waves2 * t + phase2)
            val rr = maxOf(2f, radius + wobble)
            val x = cx + cos(t) * rr
            val y = cy + sin(t) * rr
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        return path
    }

    private fun drawMic(canvas: Canvas, cx: Float, cy: Float) {
        if (!loggedIn) {
            iconPaint.color = Water.MIC
            iconPaint.textSize = 26f
            iconPaint.style = Paint.Style.FILL
            canvas.drawText("!", cx - 6f, cy + 10f, iconPaint)
            return
        }
        if (mode == Mode.PROCESSING) {
            iconPaint.style = Paint.Style.FILL
            val gap = 9f
            repeat(3) { i ->
                val on = i == processingPhase
                iconPaint.color = if (on) Water.RIPPLE_DEEP else LobsterWaterColors.ORB_DOT_DIM
                canvas.drawCircle(cx - gap + i * gap, cy, if (on) 4.5f else 3.2f, iconPaint)
            }
            return
        }
        iconPaint.style = Paint.Style.FILL
        iconPaint.color = Water.MIC_HI
        canvas.drawRoundRect(cx - 5.5f, cy - 10f, cx + 5.5f, cy + 2.5f, 5.5f, 5.5f, iconPaint)
        if (mode == Mode.RECORDING) {
            iconPaint.color = LobsterWaterColors.ACCENT_DEEP
            canvas.drawRoundRect(cx - 3.5f, cy - 7.5f, cx + 3.5f, cy - 0.5f, 1.4f, 1.4f, iconPaint)
        }
        iconPaint.style = Paint.Style.STROKE
        iconPaint.strokeWidth = 2f
        iconPaint.color = Water.MIC
        canvas.drawLine(cx, cy + 2.5f, cx, cy + 8f, iconPaint)
        canvas.drawLine(cx - 6.5f, cy + 8f, cx + 6.5f, cy + 8f, iconPaint)
    }
}
