package com.lobster.input.keyboard.typing

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.ui.theme.LobsterWaterColors

/** 麦克风按钮:按住录音,滑出取消,外环倒计时。 */
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class MicButtonView(
    context: Context,
    private val onRecordStart: () -> Unit,
    private val onRecordEnd: () -> Unit,
    private val onCancel: () -> Unit = onRecordEnd
) : View(context) {

    private val density = context.resources.displayMetrics.density
    private fun dp(v: Float) = v * density

    private val icon = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private val fillP = Paint(Paint.ANTI_ALIAS_FLAG)
    private val oval = RectF()

    private var recording = false
    private var progress = 1f
    private var warning = false
    private var micEnabled = true

    init {
        contentDescription = MobileStrings.a11yKeyMic(context)
        // 单击切换:未录音→开始实时识别;录音中→结束识别(按任意键也会结束,由容器拦截)
        setOnClickListener {
            if (!micEnabled) return@setOnClickListener
            performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            if (recording) {
                recording = false; invalidate(); onRecordEnd()
            } else {
                recording = true; progress = 1f; warning = false; invalidate(); onRecordStart()
            }
        }
    }

    /** 登录失效时置灰禁用(键盘仍可打字,仅麦克风不可用)。 */
    fun setEnabledState(enabled: Boolean) {
        if (micEnabled == enabled) return
        micEnabled = enabled
        if (!enabled && recording) { recording = false; onRecordEnd() }
        invalidate()
    }

    fun resetRecording() { if (recording) { recording = false; invalidate() } }

    fun setProgress(remaining: Float) { progress = remaining.coerceIn(0f, 1f); invalidate() }
    fun setWarning(w: Boolean) { if (warning != w) { warning = w; invalidate() } }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f; val cy = height / 2f
        if (!micEnabled) {
            // 置灰禁用态:只画灰色麦克风轮廓
            icon.color = LobsterWaterColors.TEXT_MUTED
            drawMicBody(canvas, cx, cy, fill = false)
            drawMicStand(canvas, cx, cy)
            return
        }
        val accent = if (warning) LobsterWaterColors.ERROR else LobsterWaterColors.ACCENT
        if (recording) {
            val r = minOf(width, height) / 2f - dp(2f)
            oval.set(cx - r, cy - r, cx + r, cy + r)
            ring.strokeWidth = dp(2.2f)
            ring.color = LobsterWaterColors.BORDER
            canvas.drawArc(oval, 0f, 360f, false, ring)
            ring.color = accent
            canvas.drawArc(oval, -90f, -progress * 360f, false, ring)
            fillP.color = accent
            drawMicBody(canvas, cx, cy, fill = true)
            icon.color = LobsterWaterColors.TEXT_ON_ACCENT
            drawMicStand(canvas, cx, cy)
        } else {
            icon.color = LobsterWaterColors.ACCENT_DEEP
            drawMicBody(canvas, cx, cy, fill = false)
            drawMicStand(canvas, cx, cy)
        }
    }

    private fun drawMicBody(c: Canvas, cx: Float, cy: Float, fill: Boolean) {
        val bw = dp(3.4f)
        val top = cy - dp(8.5f); val bot = cy - dp(0.5f)
        if (fill) c.drawRoundRect(cx - bw, top, cx + bw, bot, bw, bw, fillP)
        else { icon.strokeWidth = dp(1.7f); c.drawRoundRect(cx - bw, top, cx + bw, bot, bw, bw, icon) }
    }

    private fun drawMicStand(c: Canvas, cx: Float, cy: Float) {
        icon.strokeWidth = dp(1.7f)
        val arc = RectF(cx - dp(6.5f), cy - dp(5.5f), cx + dp(6.5f), cy + dp(4.5f))
        c.drawArc(arc, 20f, 140f, false, icon)
        c.drawLine(cx, cy + dp(4.5f), cx, dp(8f) + cy, icon)
        c.drawLine(cx - dp(4f), cy + dp(8f), cx + dp(4f), cy + dp(8f), icon)
    }
}
