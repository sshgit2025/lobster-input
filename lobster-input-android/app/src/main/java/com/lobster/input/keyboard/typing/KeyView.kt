package com.lobster.input.keyboard.typing

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.view.MotionEvent
import android.view.View
import com.lobster.input.keyboard.typing.accessibility.TypingAccessibilityLabels
import com.lobster.input.ui.theme.LobsterKeyboardMetrics
import com.lobster.input.ui.theme.LobsterWaterColors

/**
 * 自绘键帽(视图层,单一职责:渲染一个键 + 触摸反馈)。
 * 不持有键盘状态,通过 [Delegate] 查询 shift/mic 等并回调按键事件。
 */
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class KeyView(
    context: Context,
    val spec: KeySpec,
    private val delegate: Delegate
) : View(context) {

    interface Delegate {
        fun isShiftActive(): Boolean
        fun isCapsLock(): Boolean
        fun isMicActive(): Boolean
        fun isChineseMode(): Boolean
        fun onKeyTap(spec: KeySpec)
        fun onKeyLongPress(spec: KeySpec)
        fun onKeyShowBubble(view: KeyView, text: String)
        fun onKeyHideBubble()
        fun onDeletePressDown()
        fun onDeletePressUp()
        /** 空格横向滑动移光标:steps 为带符号的步数(负=左,正=右)。 */
        fun onSpaceSlide(steps: Int) {}
    }

    private val density = context.resources.displayMetrics.density
    private fun dp(v: Float) = v * density

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = LobsterWaterColors.KEY_SHADOW }
    private val highlight = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = dp(1.2f); color = LobsterWaterColors.ENTER_HIGHLIGHT
    }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = dp(1f) }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val subPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; color = LobsterWaterColors.TEXT_MUTED }
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = dp(2f); strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val rect = RectF()
    private var pressed = false

    private val longHandler = Handler(Looper.getMainLooper())
    private var longFired = false
    private val longRunnable = Runnable {
        longFired = true
        delegate.onKeyHideBubble()
        delegate.onKeyLongPress(spec)
    }

    init {
        isClickable = true
        TypingAccessibilityLabels.applyKeyLabel(this, spec, context, delegate.isShiftActive(), delegate.isCapsLock())
        when (spec.type) {
            KeyType.DELETE -> installDeleteTouch()
            KeyType.SPACE -> installSpaceTouch()
            else -> installTouch()
        }
    }

    /** 空格键:横向滑动移光标,未滑动则正常上屏空格。 */
    private fun installSpaceTouch() {
        val stepPx = dp(12f)
        var startX = 0f
        var accum = 0f
        var slid = false
        setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { pressed = true; invalidate(); startX = e.x; accum = 0f; slid = false; true }
                MotionEvent.ACTION_MOVE -> {
                    accum += e.x - startX; startX = e.x
                    var steps = 0
                    while (accum >= stepPx) { steps++; accum -= stepPx }
                    while (accum <= -stepPx) { steps--; accum += stepPx }
                    if (steps != 0) { slid = true; delegate.onSpaceSlide(steps) }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    pressed = false; invalidate()
                    if (!slid) delegate.onKeyTap(spec)
                    true
                }
                MotionEvent.ACTION_CANCEL -> { pressed = false; invalidate(); true }
                else -> false
            }
        }
    }

    private fun installTouch() {
        setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    pressed = true; invalidate(); longFired = false
                    if (spec.type == KeyType.LETTER) delegate.onKeyShowBubble(this, displayChar())
                    if (spec.longValue != null) longHandler.postDelayed(longRunnable, 300L)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    pressed = false; invalidate(); delegate.onKeyHideBubble()
                    longHandler.removeCallbacks(longRunnable)
                    if (!longFired && e.x >= -dp(10f) && e.x <= width + dp(10f) && e.y >= -dp(14f) && e.y <= height + dp(14f)) {
                        delegate.onKeyTap(spec)
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    pressed = false; invalidate(); delegate.onKeyHideBubble()
                    longHandler.removeCallbacks(longRunnable)
                    true
                }
                else -> false
            }
        }
    }

    private fun installDeleteTouch() {
        setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { pressed = true; invalidate(); delegate.onDeletePressDown(); true }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { pressed = false; invalidate(); delegate.onDeletePressUp(); true }
                else -> false
            }
        }
    }

    private fun displayChar(): String {
        val shifted = delegate.isShiftActive() || delegate.isCapsLock()
        // 韩语双辅音等 shift 变体键:shift 态显示变体(ㅂ→ㅃ)
        if (spec.type == KeyType.LETTER && shifted && spec.shiftValue != null) return spec.shiftValue
        // 拉丁/西里尔:非中文模式 shift 态大写
        return if (spec.type == KeyType.LETTER && !delegate.isChineseMode() && shifted)
            spec.main.uppercase() else spec.main
    }

    // 键帽纵向渐变 shader:仅在尺寸变化时重建,避免每帧新建对象
    private var normalShader: LinearGradient? = null
    private var pressShader: LinearGradient? = null

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w <= 0 || h <= 0) return
        // SYM_CANDS(9 宫格 1 键 @#)与字母键同款键帽:它位于 T9 键区内,视觉须与 2-9 键一致
        val isFunc = spec.type != KeyType.LETTER && spec.type != KeyType.T9 && spec.type != KeyType.SYM_CHAR && spec.type != KeyType.SYM_CANDS
        val enter = spec.type == KeyType.ENTER
        val hf = h.toFloat()
        normalShader = when {
            enter -> LinearGradient(0f, 0f, 0f, hf, LobsterWaterColors.ENTER_TOP, LobsterWaterColors.ENTER_BOTTOM, Shader.TileMode.CLAMP)
            isFunc -> LinearGradient(0f, 0f, 0f, hf, LobsterWaterColors.FUNC_TOP, LobsterWaterColors.FUNC_BOTTOM, Shader.TileMode.CLAMP)
            else -> LinearGradient(0f, 0f, 0f, hf, LobsterWaterColors.KEY_TOP, LobsterWaterColors.KEY_BOTTOM, Shader.TileMode.CLAMP)
        }
        pressShader = when {
            enter -> normalShader
            isFunc -> LinearGradient(0f, 0f, 0f, hf, LobsterWaterColors.FUNC_PRESS_TOP, LobsterWaterColors.FUNC_PRESS_BOTTOM, Shader.TileMode.CLAMP)
            else -> LinearGradient(0f, 0f, 0f, hf, LobsterWaterColors.KEY_PRESS_TOP, LobsterWaterColors.KEY_PRESS_BOTTOM, Shader.TileMode.CLAMP)
        }
    }

    override fun onDraw(canvas: Canvas) {
        val r = dp(LobsterKeyboardMetrics.KEY_CORNER_DP.toFloat())
        val enter = spec.type == KeyType.ENTER
        // 3D 键帽:先画向下偏移的底缘投影,再画键帽;按压时投影收窄 + 键帽整体下沉 1dp(按下沉效果)
        val sink = if (pressed) dp(1f) else 0f
        val shadowOffset = if (pressed) dp(0.5f) else dp(1.5f)
        rect.set(0f, sink, width.toFloat(), height - dp(1.5f) + sink)
        shadow.color = if (enter) LobsterWaterColors.ENTER_SHADOW else LobsterWaterColors.KEY_SHADOW
        canvas.drawRoundRect(rect.left, rect.top + shadowOffset, rect.right, rect.bottom + shadowOffset, r, r, shadow)
        fill.shader = if (pressed) pressShader else normalShader
        canvas.drawRoundRect(rect, r, r, fill)
        fill.shader = null
        if (enter) {
            // 回车键:键帽内上半部高光描边,营造玻璃反光
            val inset = dp(1f)
            canvas.save()
            canvas.clipRect(rect.left, rect.top, rect.right, rect.centerY())
            canvas.drawRoundRect(rect.left + inset, rect.top + inset, rect.right - inset, rect.bottom - inset, r - inset, r - inset, highlight)
            canvas.restore()
        } else {
            stroke.color = LobsterWaterColors.BORDER
            canvas.drawRoundRect(rect, r, r, stroke)
        }

        val cx = width / 2f; val cy = rect.centerY()
        when (spec.type) {
            KeyType.DELETE -> drawBackspace(canvas, cx, cy)
            KeyType.ENTER -> drawEnter(canvas, cx, cy)
            KeyType.SHIFT -> drawShift(canvas, cx, cy)
            KeyType.MODE_CYCLE -> drawModeCycle(canvas, cx, cy)
            KeyType.LETTER -> {
                textPaint.color = LobsterWaterColors.TEXT_MAIN
                textPaint.typeface = Typeface.DEFAULT
                textPaint.textSize = dp(19f)
                canvas.drawText(displayChar(), cx, cy + dp(7f), textPaint)
            }
            KeyType.T9 -> {
                textPaint.color = LobsterWaterColors.TEXT_MAIN
                textPaint.typeface = Typeface.DEFAULT_BOLD
                textPaint.textSize = dp(15f)
                canvas.drawText(spec.main, cx, cy + dp(2f), textPaint)
                spec.sub?.let { subPaint.textSize = dp(9f); canvas.drawText(it, cx, cy + dp(14f), subPaint) }
            }
            else -> {
                textPaint.color = if (enter) LobsterWaterColors.TEXT_ON_ACCENT else LobsterWaterColors.TEXT_MAIN
                textPaint.typeface = when (spec.type) {
                    KeyType.LANG, KeyType.NUM, KeyType.SYMBOL, KeyType.ALPHA, KeyType.SYM_PAGE, KeyType.LAYOUT -> Typeface.DEFAULT_BOLD
                    else -> Typeface.DEFAULT
                }
                val hasSub = spec.sub != null
                textPaint.textSize = if (spec.main.length > 1) dp(14f) else dp(17f)
                // 分词键(数字1)等带 sub 的键:主字上移 + 右上角小数字,对齐九宫格字母键(2-9)
                canvas.drawText(spec.main, cx, cy + (if (hasSub) dp(2f) else dp(5f)), textPaint)
                spec.sub?.let { subPaint.textSize = dp(9f); canvas.drawText(it, cx, cy + dp(14f), subPaint) }
            }
        }
    }

    private fun drawBackspace(c: Canvas, cx: Float, cy: Float) {
        glyph.style = Paint.Style.STROKE
        glyph.color = if (pressed) LobsterWaterColors.ACCENT_DEEP else LobsterWaterColors.TEXT_MAIN
        val w = dp(11f); val h = dp(8f)
        val p = Path().apply {
            moveTo(cx - w, cy); lineTo(cx - w + dp(5f), cy - h); lineTo(cx + w, cy - h)
            lineTo(cx + w, cy + h); lineTo(cx - w + dp(5f), cy + h); close()
        }
        c.drawPath(p, glyph)
        c.drawLine(cx - dp(1f), cy - dp(4f), cx + dp(6f), cy + dp(4f), glyph)
        c.drawLine(cx + dp(6f), cy - dp(4f), cx - dp(1f), cy + dp(4f), glyph)
    }

    private fun drawEnter(c: Canvas, cx: Float, cy: Float) {
        glyph.style = Paint.Style.STROKE; glyph.color = LobsterWaterColors.TEXT_ON_ACCENT
        val p = Path().apply {
            moveTo(cx + dp(8f), cy - dp(7f)); lineTo(cx + dp(8f), cy + dp(2f)); lineTo(cx - dp(8f), cy + dp(2f))
        }
        c.drawPath(p, glyph)
        c.drawLine(cx - dp(8f), cy + dp(2f), cx - dp(3f), cy - dp(3f), glyph)
        c.drawLine(cx - dp(8f), cy + dp(2f), cx - dp(3f), cy + dp(7f), glyph)
    }

    private fun drawShift(c: Canvas, cx: Float, cy: Float) {
        val active = delegate.isShiftActive() || delegate.isCapsLock()
        glyph.style = if (active) Paint.Style.FILL_AND_STROKE else Paint.Style.STROKE
        glyph.color = if (active) LobsterWaterColors.ACCENT else LobsterWaterColors.TEXT_MAIN
        val p = Path().apply {
            moveTo(cx, cy - dp(9f)); lineTo(cx + dp(8f), cy - dp(1f)); lineTo(cx + dp(4f), cy - dp(1f))
            lineTo(cx + dp(4f), cy + dp(6f)); lineTo(cx - dp(4f), cy + dp(6f)); lineTo(cx - dp(4f), cy - dp(1f))
            lineTo(cx - dp(8f), cy - dp(1f)); close()
        }
        c.drawPath(p, glyph)
        if (delegate.isCapsLock()) c.drawLine(cx - dp(4f), cy + dp(9f), cx + dp(4f), cy + dp(9f), glyph)
        glyph.style = Paint.Style.STROKE
    }

    /**
     * 模式轮换键图标:双弧循环箭头(⟳ 键盘轮换语义,非地球——避免与 iOS 系统地球键歧义)
     * + 下方下一模式短标签(spec.sub,如 "26键"/"EN"/"РУ"),用户可预期下一站。
     */
    private fun drawModeCycle(c: Canvas, cx: Float, cy: Float) {
        glyph.style = Paint.Style.STROKE
        glyph.color = if (pressed) LobsterWaterColors.ACCENT_DEEP else LobsterWaterColors.TEXT_MAIN
        val hasSub = !spec.sub.isNullOrEmpty()
        val iconCy = if (hasSub) cy - dp(4f) else cy
        val r = dp(7f)
        val arc = RectF(cx - r, iconCy - r, cx + r, iconCy + r)
        // 两段开口弧(各 120°)构成循环
        c.drawArc(arc, -80f, 120f, false, glyph)
        c.drawArc(arc, 100f, 120f, false, glyph)
        // 弧端箭头(小三角,FILL)
        glyph.style = Paint.Style.FILL
        fun arrow(angleDeg: Float, clockwise: Boolean) {
            val rad = Math.toRadians(angleDeg.toDouble())
            val ax = cx + r * Math.cos(rad).toFloat()
            val ay = iconCy + r * Math.sin(rad).toFloat()
            // 箭头指向弧线切线方向
            val tRad = rad + (if (clockwise) Math.PI / 2 else -Math.PI / 2)
            val dxv = Math.cos(tRad).toFloat(); val dyv = Math.sin(tRad).toFloat()
            val s = dp(3.4f)
            val p = Path().apply {
                moveTo(ax + dxv * s, ay + dyv * s)
                lineTo(ax - dyv * s * 0.85f, ay + dxv * s * 0.85f)
                lineTo(ax + dyv * s * 0.85f, ay - dxv * s * 0.85f)
                close()
            }
            c.drawPath(p, glyph)
        }
        arrow(40f, clockwise = true)
        arrow(220f, clockwise = true)
        glyph.style = Paint.Style.STROKE
        // 下一模式短标签
        if (hasSub) {
            subPaint.textSize = dp(9f)
            c.drawText(spec.sub!!, cx, cy + dp(14f), subPaint)
        }
    }

    private fun drawMic(c: Canvas, cx: Float, cy: Float, on: Boolean) {
        glyph.style = Paint.Style.STROKE
        glyph.color = if (on) LobsterWaterColors.TEXT_ON_ACCENT else LobsterWaterColors.ACCENT_DEEP
        val bodyW = dp(6f)
        c.drawRoundRect(cx - bodyW, cy - dp(9f), cx + bodyW, cy + dp(1f), bodyW, bodyW, glyph)
        val arc = RectF(cx - dp(9f), cy - dp(6f), cx + dp(9f), cy + dp(6f))
        c.drawArc(arc, 20f, 140f, false, glyph)
        c.drawLine(cx, cy + dp(6f), cx, cy + dp(10f), glyph)
        c.drawLine(cx - dp(5f), cy + dp(10f), cx + dp(5f), cy + dp(10f), glyph)
    }
}
