package com.lobster.input.keyboard.typing

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.keyboard.pinyin.Candidate
import com.lobster.input.keyboard.pinyin.PinyinLoadState
import com.lobster.input.keyboard.typing.accessibility.TypingAccessibilityLabels
import com.lobster.input.ui.theme.LobsterKeyboardMetrics
import com.lobster.input.ui.theme.LobsterKeycap
import com.lobster.input.ui.theme.LobsterWaterColors

/**
 * 候选栏:状态条 + [返回语音][麦克风][组合/候选/波形][布局][展开][撤销]。
 */
@SuppressLint("ViewConstructor")
class CandidateBarView(
    context: Context,
    private val delegate: Delegate
) : LinearLayout(context) {

    interface Delegate {
        fun onCandidateSelected(candidate: Candidate)
        fun onCandidateLongPress(candidate: Candidate)
        fun onPinyinOptionSelected(pinyin: String)
        fun onReturnToVoice()
        fun onToggleLayout()
        fun onMicRecordStart()
        fun onMicRecordEnd()
        fun onMicCancel()
        fun onExpandCandidates()
        fun onToolsTapped()
        fun returnVoiceText(): String
        fun layoutSwitchText(): String
        fun canUndo(): Boolean
        fun onUndo()
    }

    private val density = context.resources.displayMetrics.density
    private fun dp(v: Float) = (v * density).toInt()

    private val statusBar: TextView
    private val modeButton: TextView
    private val micButton: MicButtonView
    private val scroll: HorizontalScrollView
    private val candidateRow: LinearLayout
    private val composingLabel: TextView
    private val waveform: WaveformView
    private val layoutButton: TextView
    private val expandButton: TextView
    private val undoButton: TextView

    private var allCandidates = emptyList<Candidate>()
    private var pinyinOptions = emptyList<String>()
    private val pageSize = 8
    // 2026-07 修「yi 打不出咦」:引擎输出全量渲染(有界:CAND_LIMIT+精确保底 ≤ ~350),
    // 任何 renderCap 都会破坏「锁定音节后单字全量可达」。首屏只同步渲染前 syncRenderCount 个
    // 保证按键回显不卡,其余下一帧批量补齐(用户来不及在一帧内滚过首屏)。
    private val syncRenderCount = 80
    private var renderGeneration = 0

    init {
        orientation = VERTICAL
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)

        statusBar = TextView(context).apply {
            setTextColor(LobsterWaterColors.ERROR)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            visibility = GONE
            setPadding(dp(6f), dp(2f), dp(6f), dp(2f))
        }
        addView(statusBar, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))

        val row = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, dp(LobsterKeyboardMetrics.TOOLBAR_HEIGHT_DP.toFloat()))
        }
        addView(row)

        modeButton = pill(delegate.returnVoiceText(), primary = true) { delegate.onReturnToVoice() }
        row.addView(modeButton, pillLp(dp(2f), dp(4f)))

        micButton = MicButtonView(
            context,
            onRecordStart = { setRecording(true); delegate.onMicRecordStart() },
            onRecordEnd = { setRecording(false); delegate.onMicRecordEnd() },
            onCancel = { setRecording(false); delegate.onMicCancel() }
        )
        row.addView(micButton, LayoutParams(dp(38f), dp(38f)).apply { rightMargin = dp(4f) })

        val center = FrameLayout(context).apply {
            layoutParams = LayoutParams(0, LayoutParams.MATCH_PARENT, 1f)
        }
        scroll = HorizontalScrollView(context).apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        }
        candidateRow = LinearLayout(context).apply { orientation = HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        composingLabel = TextView(context).apply {
            setTextColor(LobsterWaterColors.ACCENT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            typeface = Typeface.DEFAULT_BOLD
            includeFontPadding = false
            visibility = GONE
            layoutParams = LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { rightMargin = dp(8f) }
        }
        candidateRow.addView(composingLabel)
        scroll.addView(candidateRow)
        center.addView(scroll)

        waveform = WaveformView(context).apply {
            visibility = GONE
            layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        }
        center.addView(waveform)
        row.addView(center)

        expandButton = pill("▾") { delegate.onExpandCandidates() }.apply { visibility = GONE }
        row.addView(expandButton, pillLp(dp(2f), dp(2f)))

        undoButton = pill(MobileStrings.undo(context)) { delegate.onUndo() }.apply { visibility = GONE }
        row.addView(undoButton, pillLp(dp(2f), dp(2f)))

        // 26↔九宫格切换钮已移除:布局/语种切换统一由键区常驻「模式轮换键」承担(问题3闭环);
        // 齿轮工具页保留布局切换磁贴作为第二通道。

        // 齿轮工具入口(最右侧,同一行,不加高面板):点开工具子页(布局切换/emoji/剪贴板)
        layoutButton = pill("⚙") { delegate.onToolsTapped() }
        row.addView(layoutButton, pillLp(dp(4f), dp(2f)))
    }

    private fun lp(left: Int, right: Int) =
        LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { leftMargin = left; rightMargin = right }

    /** 胶囊按钮统一规格布局:视觉高 36dp + 底缘投影 2dp = 布局高 38dp,44dp 工具栏内垂直居中。 */
    private fun pillLp(left: Int, right: Int) =
        LayoutParams(LayoutParams.WRAP_CONTENT, dp(LobsterKeyboardMetrics.BUTTON_TOTAL_HEIGHT_DP.toFloat())).apply {
            leftMargin = left; rightMargin = right
        }

    /**
     * Sapphire Glass 3D 键帽胶囊按钮(LobsterKeycap 同源):primary=蓝宝石纵向渐变白字(模式切换专用),
     * secondary=FUNC 渐变键帽 + 1dp 描边、文字 ACCENT_DEEP;均带底缘投影 + Ripple 按压反馈。
     */
    private fun pill(text: String, primary: Boolean = false, onClick: () -> Unit) = TextView(context).apply {
        this.text = text
        setTextColor(if (primary) LobsterWaterColors.TEXT_ON_ACCENT else LobsterWaterColors.ACCENT_DEEP)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, if (primary) 13f else 12.5f)
        typeface = Typeface.DEFAULT_BOLD
        gravity = Gravity.CENTER
        includeFontPadding = false
        maxLines = 1
        setPadding(dp(12f), 0, dp(12f), 0)
        background = pillBackground(primary)
        setOnClickListener { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); onClick() }
    }

    private fun pillBackground(primary: Boolean): RippleDrawable = LobsterKeycap.background(
        density,
        LobsterKeyboardMetrics.BUTTON_CORNER_DP.toFloat(),
        if (primary) LobsterKeycap.Style.PRIMARY else LobsterKeycap.Style.SECONDARY
    )

    fun render(composingDisplay: String, candidates: List<Candidate>, layoutLabel: String, nineGrid: Boolean) {
        modeButton.text = delegate.returnVoiceText()
        undoButton.text = MobileStrings.undo(context)

        // 打字中(composing 非空)= 收起两边(返回语音/麦克风/齿轮/撤回),候选占满整行;
        // composing 一空(选词/上屏/联想/空态)立即恢复,绝不造成输入结束后功能缺失。
        // 1 键符号候选态(isSymbol)同样收起两侧:13 个符号需要整行空间,与候选词展开效果对齐
        // (emoji 联想态不收起,保持原状)。
        val typing = composingDisplay.isNotEmpty() || candidates.firstOrNull()?.isSymbol == true
        typingMode = typing
        modeButton.visibility = if (typing) GONE else VISIBLE
        micButton.visibility = if (!typing && micShown) VISIBLE else GONE
        layoutButton.visibility = if (typing) GONE else VISIBLE
        undoButton.visibility = if (!typing && delegate.canUndo()) VISIBLE else GONE

        if (typing) {
            composingLabel.visibility = VISIBLE
            composingLabel.text = composingDisplay
        } else {
            composingLabel.visibility = GONE
        }

        allCandidates = candidates
        expandButton.visibility = if (candidates.size > pageSize) VISIBLE else GONE
        renderCandidatePage()
    }

    /** 由容器在展开/收起多行面板时同步箭头方向。 */
    fun setExpandedArrow(open: Boolean) { expandButton.text = if (open) "▴" else "▾" }

    /** 更新 9 宫格拼音自选项(内联到候选行,不新增行、不改键盘高度)。 */
    fun renderPinyinOptions(options: List<String>) {
        pinyinOptions = options
        renderCandidatePage()
    }

    private fun renderCandidatePage() {
        while (candidateRow.childCount > 1) candidateRow.removeViewAt(1)
        // 拼音自选项内联在候选前(带边框,与候选区分),点选收窄;整行横滑,高度固定不变。
        for (p in pinyinOptions) {
            candidateRow.addView(TextView(context).apply {
                text = p
                setTextColor(LobsterWaterColors.ACCENT_DEEP)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                includeFontPadding = false
                setPadding(dp(9f), dp(3f), dp(9f), dp(3f))
                background = GradientDrawable().apply {
                    setColor(LobsterWaterColors.BUTTON_BG); cornerRadius = dp(13f).toFloat()
                    setStroke(dp(1f).coerceAtLeast(1), LobsterWaterColors.SECONDARY_STROKE)
                }
                setOnClickListener {
                    performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    delegate.onPinyinOptionSelected(p)
                }
            }, lp(dp(2f), dp(2f)))
        }
        // 候选词:首屏同步,剩余次帧补齐(generation 防旧任务追加到新列表)
        renderGeneration++
        val generation = renderGeneration
        val syncCount = minOf(syncRenderCount, allCandidates.size)
        for (i in 0 until syncCount) addCandidateView(allCandidates[i], i)
        if (allCandidates.size > syncCount) {
            post {
                if (generation != renderGeneration) return@post
                for (i in syncCount until allCandidates.size) addCandidateView(allCandidates[i], i)
            }
        }
        scroll.scrollTo(0, 0)
    }

    private fun addCandidateView(c: Candidate, i: Int) {
        candidateRow.addView(TextView(context).apply {
            text = c.word
            setTextColor(if (i == 0) LobsterWaterColors.ACCENT_DEEP else LobsterWaterColors.TEXT_MAIN)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            gravity = Gravity.CENTER
            includeFontPadding = false
            minWidth = dp(40f)
            setPadding(dp(10f), dp(4f), dp(10f), dp(4f))
            if (i == 0) background = GradientDrawable().apply {
                setColor(LobsterWaterColors.BADGE_ACTIVE_BG); cornerRadius = dp(8f).toFloat()
            }
            TypingAccessibilityLabels.announceCandidate(this, c, i)
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                delegate.onCandidateSelected(c)
            }
            setOnLongClickListener {
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                delegate.onCandidateLongPress(c); true
            }
        })
    }

    fun renderEngineState(state: PinyinLoadState, detail: String?) {
        val msg = when (state) {
            PinyinLoadState.LOADING -> MobileStrings.pinyinDictLoading(context)
            PinyinLoadState.FAILED -> detail ?: MobileStrings.pinyinDictFailed(context)
            else -> null
        }
        if (msg.isNullOrBlank()) {
            statusBar.visibility = GONE
        } else {
            statusBar.visibility = VISIBLE
            statusBar.text = msg
            TypingAccessibilityLabels.announceStatus(this, msg)
        }
    }

    private val statusHideRunnable = Runnable { statusBar.visibility = GONE }

    fun showStatus(message: String?) {
        removeCallbacks(statusHideRunnable)
        if (message.isNullOrBlank()) {
            statusBar.visibility = GONE
        } else {
            statusBar.visibility = VISIBLE
            statusBar.text = message
            postDelayed(statusHideRunnable, 3000L) // 3s 后自动消失,不再常驻
        }
    }

    fun setRecording(active: Boolean) {
        if (active) {
            scroll.visibility = GONE
            waveform.visibility = VISIBLE
            waveform.start()
        } else {
            waveform.stop()
            waveform.visibility = GONE
            scroll.visibility = VISIBLE
            micButton.resetRecording()
        }
    }

    /** 密码框隐藏键盘内麦克风(隐私:语音不进入密码框)。 */
    private var micShown = true
    private var typingMode = false

    fun setMicVisible(visible: Boolean) {
        micShown = visible
        micButton.visibility = if (visible && !typingMode) VISIBLE else GONE
    }

    /** 未登录时置灰麦克风(键盘仍可打字)。 */
    fun setMicEnabled(enabled: Boolean) = micButton.setEnabledState(enabled)

    fun updateLevel(level: Float) = waveform.setLevel(level)

    fun setRecordProgress(remaining: Float) {
        micButton.setProgress(remaining)
        val warn = remaining <= 0.16f
        micButton.setWarning(warn)
        waveform.setWarning(warn)
    }
}
