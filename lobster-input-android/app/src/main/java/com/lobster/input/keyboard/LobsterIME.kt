package com.lobster.input.keyboard

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.lobster.input.core.audio.AudioRecorder
import com.lobster.input.core.audio.RealtimeAudioStreamer
import com.lobster.input.core.history.MobileHistoryStore
import com.lobster.input.core.network.ApiConfig
import com.lobster.input.core.network.ApiService
import com.lobster.input.core.network.RealtimeAsrErrorKind
import com.lobster.input.core.network.RealtimeAsrWebSocketClient
import com.lobster.input.core.network.RealtimeResume
import com.lobster.input.keyboard.pinyin.PinyinEngine
import com.lobster.input.core.log.FileLog
import com.lobster.input.keyboard.typing.SymbolData
import com.lobster.input.keyboard.typing.TypingKeyboardView
import com.lobster.input.keyboard.typing.composing.ComposingTextBridge
import com.lobster.input.keyboard.typing.composing.TypingUndoManager
import com.lobster.input.keyboard.typing.coordinator.KeyboardMicCoordinator
import com.lobster.input.keyboard.typing.coordinator.TypingImeContext
import com.lobster.input.keyboard.typing.coordinator.TypingModeCoordinator
import com.lobster.input.keyboard.typing.coordinator.TypingPreferences
import com.lobster.input.keyboard.typing.coordinator.TypingSessionHost
import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.data.local.AuthSession
import com.lobster.input.data.model.ActionType
import com.lobster.input.data.model.AndroidQuickAction
import com.lobster.input.data.model.AndroidQuickActionRequest
import com.lobster.input.data.model.ApiErrorResponse
import com.lobster.input.data.model.AudioProcessResponse
import com.lobster.input.data.model.PersonaItem
import com.lobster.input.data.model.PersonaPrompts
import com.lobster.input.data.model.PersonaUpdateBody
import com.lobster.input.data.model.TextProcessRequest
import com.lobster.input.data.model.TextQuickActionResponse
import com.lobster.input.ui.theme.LobsterKeyboardMetrics
import com.lobster.input.ui.theme.LobsterKeycap
import com.lobster.input.ui.theme.LobsterWaterColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.TimeUnit

class LobsterIME : InputMethodService() {

    private enum class Operation {
        TRANSCRIBE,
        REWRITE
    }

    /**
     * 录音捕获模式 —— 录音控制层唯一的权威同步状态。
     * 所有手势/按钮做决策时都以它为准,不依赖 StateFlow 的异步镜像,从根本上消除状态竞态。
     *
     * - IDLE:     无录音。
     * - SYNC:     同步录音(单击麦克风、或点「指令」触发;再次单击麦克风停止并送识别)。
     *             与「实时流式 ASR」开关完全无关 ——「指令」永远走这条路径。
     * - REALTIME: 实时流式录音(长按麦克风触发;松手停止)。仅在开关开启、且空闲时由长按发起。
     */
    private enum class CaptureMode {
        IDLE,
        SYNC,
        REALTIME
    }

    private enum class BlockedReason {
        LOGIN_REQUIRED,
        CREDITS_EXHAUSTED
    }

    private lateinit var audioRecorder: AudioRecorder
    private lateinit var realtimeStreamer: RealtimeAudioStreamer
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val apiService: ApiService by lazy { createApiService() }
    private val historyStore: MobileHistoryStore by lazy { MobileHistoryStore(this) }
    private val uiHandler by lazy { Handler(Looper.getMainLooper()) }
    private val backspaceRepeatHandler by lazy { Handler(Looper.getMainLooper()) }
    private val backspaceRepeatRunnable = object : Runnable {
        override fun run() {
            if (!backspaceRepeatActive) return
            handleBackspace()
            backspaceRepeatHandler.postDelayed(this, BACKSPACE_REPEAT_INTERVAL_MS)
        }
    }

    private var captureMode: CaptureMode = CaptureMode.IDLE
    private var isProcessing = false
    private var audioLevel = 0f
    private var statusText = ""
    private var errorMessage = ""
    private var lastInsertedText = ""
    private var voiceRestoreText = ""
    private val operationTextHistory = mutableListOf<String>()
    private var recordingRemainingSec = ApiConfig.DEFAULT_MAX_DURATION_SEC
    private var pendingOperation = Operation.TRANSCRIBE
    private var pendingRewriteOriginal = ""
    private var pendingRewriteTarget = RewriteTarget.NONE
    private var fastModeEnabled = false
    private var realtimeRecognitionEnabled = false
    // 实时收尾协程(松手后上传/取最终结果)是否在进行,用于防重入与预览门控。
    private var realtimeFinishing = false
    // 麦克风长按手势当前是否按住(用于实时录音的按下/松手配对)。
    private var realtimePressActive = false

    /** 键盘是否正忙:有录音在进行,或正在等待服务端结果。统一替代此前散落的多标志组合判断。 */
    private val isBusy: Boolean
        get() = captureMode != CaptureMode.IDLE || isProcessing
    private var realtimeAudioLevel = 0f
    private var realtimeRemainingSec = ApiConfig.DEFAULT_MAX_DURATION_SEC
    private var realtimeTranscript = ""
    private var realtimeTranscriptLanguage = ""
    private var realtimePreviewLength = 0
    private var realtimePreviewComposing = false
    private var realtimeAcceptingPreview = false
    // 实时识别打字机平滑层:只平滑"预览显示",不参与最终提交(最终仍由 commitRealtimeFinalText 整段提交)。
    private val realtimeTypewriter by lazy { TypewriterReveal(uiHandler) { shown -> applyRealtimePreview(shown) } }
    private var realtimeWsClient: RealtimeAsrWebSocketClient? = null
    private var realtimeConnectJob: Job? = null
    private var realtimeConnectError: String? = null
    private val realtimeAudioBufferLock = Any()
    private val realtimePendingAudio = ArrayDeque<ByteArray>()
    private var realtimePendingAudioBytes = 0
    // 断连续传:已并入前序会话的整句前缀(新会话文本经重叠裁剪并入其后)。
    private var realtimeTranscriptPrefix = ""
    // 最近已发送音频尾巴环形缓冲:重连时回灌,补回断连瞬间已发送但未出字的音频。
    private val realtimeSentTail = ArrayDeque<ByteArray>()
    private var realtimeSentTailBytes = 0
    // 单次长按内已自动重连的次数(上限 RealtimeResume.MAX_RECONNECT_ATTEMPTS)。
    private var realtimeReconnectAttempts = 0
    private var inputViewActive = false
    private var symbolPanelVisible = false
    private var personaPanelVisible = false
    private var rightHandLayout = true
    private var blockedReason: BlockedReason? = null
    private var liveCreditsRemaining: Int? = null
    private var accountStatusLoading = false
    private var personasLoading = false
    private var personasRefreshing = false
    private var pendingPersonaActionId: String? = null
    private var backspaceRepeatActive = false
    private var backspaceLongPressTriggered = false
    private var backspaceRepeatSession = 0
    private var personaDetail: PersonaItem? = null
    private var personas: List<PersonaItem> = emptyList()
    private var voicePanel: LinearLayout? = null
    private var brandTextView: TextView? = null
    private var statusTextView: TextView? = null
    private var recordButton: RecordOrbView? = null
    private var undoButton: Button? = null
    private var restoreButton: Button? = null
    private var rewriteButton: Button? = null
    private var personaToggleButton: Button? = null
    private var symbolToggleButton: Button? = null
    private var fastModeButton: Button? = null
    private var contentView: LinearLayout? = null
    private var commandHintView: TextView? = null
    private var unavailablePanel: LinearLayout? = null
    private var unavailableTitleView: TextView? = null
    private var unavailableBodyView: TextView? = null
    private var switchKeyboardButton: TextView? = null
    private var openAppButton: TextView? = null
    private var voiceColumnView: View? = null
    private var actionColumnView: View? = null
    private var primaryActionRowView: LinearLayout? = null
    private var quickTopRowView: LinearLayout? = null
    private var quickBottomRowView: LinearLayout? = null
    private var handLayoutButton: Button? = null
    private var symbolPanel: LinearLayout? = null
    private var personaPanel: LinearLayout? = null

    // 打字键盘模式(协调器分层)
    private lateinit var typingCoordinator: TypingModeCoordinator
    private lateinit var typingSessionHost: TypingSessionHost
    private lateinit var micCoordinator: KeyboardMicCoordinator
    private val composingBridge = ComposingTextBridge()
    private var currentEditorInfo: EditorInfo? = null
    private var keyboardModeButton: Button? = null
    private lateinit var keyboardMic: KeyboardRealtimeMic

    companion object {
        private const val PREF_HAND_LAYOUT = "ime_right_hand_layout"
        private const val PREF_FAST_MODE = "ime_fast_mode_enabled"
        private const val BACKSPACE_REPEAT_INTERVAL_MS = 58L
        private const val REALTIME_AUDIO_BUFFER_LIMIT_BYTES = 2_500_000
        private const val KEYBOARD_PANEL_HEIGHT_DP = 286
        private const val PERSONA_PANEL_HEIGHT_DP = 266
        private const val MAX_SURROUNDING_TEXT_DELETE_CHARS = 100_000
    }

    private enum class RewriteTarget {
        NONE,
        SELECTED_TEXT,
        LAST_INSERTED
    }

    private enum class PrimaryShortcut {
        NEWLINE,
        UNDO,
        REWRITE
    }

    private enum class QuickShortcut {
        FORMAT,
        POLISH,
        CONCISE,
        CLEAR
    }

    private class InputUnavailableException(
        val reason: BlockedReason,
        message: String
    ) : IllegalStateException(message)

    override fun onCreate() {
        super.onCreate()
        FileLog.init(this)
        audioRecorder = AudioRecorder(this)
        realtimeStreamer = RealtimeAudioStreamer(this)
        keyboardMic = KeyboardRealtimeMic(realtimeStreamer, scope, keyboardMicCallbacks)
        ensureTypingStack()
        val prefs = getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
        rightHandLayout = prefs.getBoolean(PREF_HAND_LAYOUT, true)
        fastModeEnabled = prefs.getBoolean(PREF_FAST_MODE, false)
        realtimeRecognitionEnabled = prefs.getBoolean(ApiConfig.KEY_REALTIME_RECOGNITION, false)

        // 以下采集器只负责把录音器的声浪/倒计时镜像到 UI 字段并刷新界面,
        // 不参与控制决策(控制状态以 captureMode 为唯一权威)。
        scope.launch {
            audioRecorder.audioLevel.collect { level ->
                // 高频回调:只更新麦克风球能量,不做整面板刷新。
                audioLevel = level
                recordButton?.updateLevel(level)
            }
        }

        scope.launch {
            audioRecorder.remainingSeconds.collect { remaining ->
                recordingRemainingSec = remaining
                if (captureMode == CaptureMode.SYNC) {
                    refreshKeyboardUi()
                }
            }
        }

        scope.launch {
            realtimeStreamer.audioLevel.collect { level ->
                // 高频回调:只更新麦克风球能量,不做整面板刷新。
                realtimeAudioLevel = level
                recordButton?.updateLevel(level)
                if (::keyboardMic.isInitialized && keyboardMic.isActive) {
                    typingCoordinator.typingView?.updateMicLevel((level / 100f).coerceIn(0f, 1f))
                }
            }
        }

        scope.launch {
            realtimeStreamer.remainingSeconds.collect { remaining ->
                realtimeRemainingSec = remaining
                if (::keyboardMic.isInitialized && keyboardMic.isActive) {
                    val max = realtimeStreamer.maxDurationSec.coerceAtLeast(1)
                    typingCoordinator.typingView?.setMicProgress(remaining.toFloat() / max)
                }
                if (captureMode == CaptureMode.REALTIME) {
                    refreshKeyboardUi()
                }
            }
        }

        audioRecorder.onMaxDurationReached = { file ->
            if (!isProcessing) {
                processAudio(file, pendingOperation)
            } else {
                captureMode = CaptureMode.IDLE
                file.delete()
                refreshKeyboardUi()
            }
        }
    }

    override fun onCreateInputView(): View {
        panelsHiding.clear() // 视图整体重建,清空过场动画簿记
        val root = FixedHeightImeRoot(this, dp(KEYBOARD_PANEL_HEIGHT_DP)).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = panelBackground()
            minimumHeight = dp(250)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(KEYBOARD_PANEL_HEIGHT_DP)
            )
        }

        voicePanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            // 吃满面板内容高:content 行才能 weight=1 撑开,commandHint 固定在底部,整体重心居中
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.MATCH_PARENT
            )
        }
        root.addView(voicePanel)

        // 顶部工具栏:与键盘模式候选栏同规格(44dp 高,按钮 38dp 垂直居中),两模式左上按钮 Y 完全对齐
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(LobsterKeyboardMetrics.TOOLBAR_HEIGHT_DP)
            )
        }
        // 模式切换按钮(Primary 3D 键帽:蓝宝石渐变白字 + 底缘投影),点击切到打字键盘。
        keyboardModeButton = Button(this).apply {
            text = MobileStrings.keyboardModeLabel(this@LobsterIME)
            textSize = 13f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            setTextColor(LobsterWaterColors.TEXT_ON_ACCENT)
            background = keycap(style = LobsterKeycap.Style.PRIMARY)
            setAllCaps(false)
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            gravity = Gravity.CENTER
            setPadding(dp(14), 0, dp(14), 0)
            // i18n 长文案(俄语等)封顶宽 + 缩字:去滑动布局的宽度预算前提(见 test_voice_toolbar_layout.py)
            maxWidth = dp(88)
            fitPanelLabel(9, 13)
            setOnClickListener { enterKeyboardMode() }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                dp(LobsterKeyboardMetrics.BUTTON_TOTAL_HEIGHT_DP)
            ).apply { rightMargin = dp(8) }
        }
        header.addView(keyboardModeButton)
        // 弹性空白:把右侧功能键推到右边(品牌名已移除)
        header.addView(View(this), LinearLayout.LayoutParams(0, dp(1), 1f))
        // 2026-07 语音面板重排版(test_voice_toolbar_layout.py):
        // - @ 回归工具栏右侧显眼位置(微信聊天高频符号),一键可达,不必进符号面板
        // - "单手"迁至底部提示行(设置类低频开关),不再挤占麦克风语音列工具行
        // - 人设/符号图标化(🎭/🔣):解决俄语等长文案缩字不可读 + 宽度预算,
        //   本地化文案保留在 contentDescription(无障碍朗读不变)
        // 内容宽 320dp 屏 + 挖孔余量下定宽装下 → 工具栏不横向滚动
        header.addView(Button(this).apply {
            text = "@"
            textSize = 17f
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            background = keycap()
            setAllCaps(false)
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 0)
            setOnClickListener { commitTextWithHistory("@") }
            layoutParams = LinearLayout.LayoutParams(dp(40), dp(LobsterKeyboardMetrics.BUTTON_TOTAL_HEIGHT_DP)).apply { rightMargin = dp(8) }
        })
        personaToggleButton = Button(this).apply {
            text = "🎭"
            textSize = 16f
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            background = keycap()
            setAllCaps(false)
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 0)
            contentDescription = MobileStrings.persona(this@LobsterIME)
            setOnClickListener { togglePersonaPanel() }
            layoutParams = LinearLayout.LayoutParams(dp(40), dp(LobsterKeyboardMetrics.BUTTON_TOTAL_HEIGHT_DP)).apply { rightMargin = dp(8) }
        }
        header.addView(personaToggleButton)
        symbolToggleButton = Button(this).apply {
            text = "🔣"
            textSize = 16f
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            background = keycap()
            setAllCaps(false)
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 0)
            contentDescription = MobileStrings.symbols(this@LobsterIME)
            setOnClickListener { toggleSymbolPanel() }
            layoutParams = LinearLayout.LayoutParams(dp(40), dp(LobsterKeyboardMetrics.BUTTON_TOTAL_HEIGHT_DP)).apply { rightMargin = dp(8) }
        }
        header.addView(symbolToggleButton)
        header.addView(Button(this).apply {
            text = "⌫"
            textSize = 16f
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            background = keycap()
            setAllCaps(false)
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            setPadding(0, 0, 0, 0)
            setOnClickListener { handleBackspace() }
            installBackspaceRepeatTouch()
            layoutParams = LinearLayout.LayoutParams(dp(44), dp(LobsterKeyboardMetrics.BUTTON_TOTAL_HEIGHT_DP))
        })
        // 2026-07 去滑动:重设计后工具栏内容宽 ≤268dp,320dp 最小屏 + 挖孔 inset 余量下
        // 定宽装下(预算模型 test_voice_toolbar_layout.py),不再需要 HorizontalScrollView。
        // 窄屏遮挡问题由"移除重复键 + 图标化 + 单手迁移"从布局根源解决,而非滚动兜底。
        voicePanel?.addView(header)

        unavailablePanel = buildUnavailablePanel().apply {
            visibility = View.GONE
        }
        voicePanel?.addView(unavailablePanel)

        // content 行 weight=1 吃满 header 与 commandHint 之间的全部剩余高度,内部垂直居中 → 上下留白对称
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f
            ).apply {
                topMargin = dp(12)
            }
        }
        contentView = content

        val voiceColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            background = glassCard(dp(16))
            setPadding(dp(10), dp(10), dp(10), dp(10))
            layoutParams = LinearLayout.LayoutParams(dp(126), LinearLayout.LayoutParams.MATCH_PARENT).apply {
                rightMargin = dp(12)
            }
        }
        voiceColumnView = voiceColumn

        statusTextView = TextView(this).apply {
            setTextColor(LobsterWaterColors.TEXT_MUTED)
            textSize = 13f
            gravity = Gravity.CENTER
            maxLines = 2
            setIncludeFontPadding(false)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(34)
            )
        }
        voiceColumn.addView(statusTextView)

        recordButton = com.lobster.input.keyboard.RecordOrbView(this).apply {
            setOnClickListener { onMicTap() }
            setOnTouchListener { _, event ->
                // 长按手势只服务于「实时流式 ASR 的发起/结束」。
                // 仅当 实时开关开启 且 当前不是同步录音 时,由长按接管;其余情况一律放行给单击(onMicTap)。
                // 这样:① 同步模式永远是单击开始/停止;② 即便实时开关开启,「指令」发起的同步录音
                // 也能用单击可靠停止(因为此时 captureMode == SYNC,长按不接管)。
                if (!realtimeRecognitionEnabled || captureMode == CaptureMode.SYNC) {
                    return@setOnTouchListener false
                }
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        onRealtimePressDown()
                        true
                    }
                    MotionEvent.ACTION_UP,
                    MotionEvent.ACTION_CANCEL -> {
                        onRealtimeRelease()
                        true
                    }
                    else -> true
                }
            }
            layoutParams = LinearLayout.LayoutParams(dp(72), dp(72)).apply {
                topMargin = dp(8)
            }
        }
        voiceColumn.addView(recordButton)

        val voiceToolRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(32) // 30 视觉高 + 2 键帽投影预留
            ).apply {
                topMargin = dp(10)
            }
        }
        fastModeButton = Button(this).apply {
            textSize = 11f
            fitPanelLabel(7, 11)
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            setAllCaps(false)
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 0)
            background = keycap(radiusDp = 15f)
            setOnClickListener {
                toggleFastMode()
            }
            layoutParams = LinearLayout.LayoutParams(0, dp(32), 1f).apply { rightMargin = dp(6) }
        }
        voiceToolRow.addView(fastModeButton)
        restoreButton = Button(this).apply {
            text = MobileStrings.restoreVoice(this@LobsterIME)
            textSize = 11f
            fitPanelLabel(7, 11)
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            background = keycap(radiusDp = 15f)
            setAllCaps(false)
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 0)
            setOnClickListener { handleRestoreVoiceText() }
            layoutParams = LinearLayout.LayoutParams(0, dp(32), 1f)
        }
        voiceToolRow.addView(restoreButton)
        // 单手(左右手镜像)开关已迁至底部提示行,见下方 bottomBar;
        // 麦克风语音列工具行只保留「极速 / 还原」两钮,腾出宽度、俄语文案不再挤压
        voiceColumn.addView(voiceToolRow)

        val actionColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
        }
        actionColumnView = actionColumn

        val primaryRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }
        primaryActionRowView = primaryRow
        actionColumn.addView(primaryRow)

        val quickGrid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(8)
            }
        }
        val quickTop = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }
        quickTopRowView = quickTop
        quickGrid.addView(quickTop)

        val quickBottom = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(8)
            }
        }
        quickBottomRowView = quickBottom
        quickGrid.addView(quickBottom)
        actionColumn.addView(quickGrid)
        rebuildShortcutRows()
        applyHandLayout(animated = false)
        voicePanel?.addView(content)

        // 底部行:左侧「单手(左右手镜像)」低频开关 + 右侧命令提示文案。
        // 单手从麦克风语音列迁到这里,给它一个够宽、不挤压任何区域的低显著度位置。
        val bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(8)
            }
        }
        handLayoutButton = Button(this).apply {
            textSize = 11f
            fitPanelLabel(7, 11)
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            background = keycap(radiusDp = 15f)
            setAllCaps(false)
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            gravity = Gravity.CENTER
            setPadding(dp(6), 0, dp(6), 0)
            setOnClickListener { toggleHandLayout() }
            layoutParams = LinearLayout.LayoutParams(dp(56), dp(28)).apply { rightMargin = dp(10) }
        }
        bottomBar.addView(handLayoutButton)
        commandHintView = TextView(this).apply {
            text = MobileStrings.commandHint(this@LobsterIME)
            textSize = 11f
            setTextColor(LobsterWaterColors.TEXT_MUTED)
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setIncludeFontPadding(false)
            alpha = 0.72f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        bottomBar.addView(commandHintView)
        voicePanel?.addView(bottomBar)

        symbolPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            // 吃满面板内容高(与 voicePanel 一致),符号网格 weight 撑开,避免只显示半屏
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.MATCH_PARENT
            )
        }
        root.addView(symbolPanel)
        rebuildSymbolPanel()

        personaPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(PERSONA_PANEL_HEIGHT_DP)
            )
        }
        root.addView(personaPanel)
        rebuildPersonaPanel()

        ensureTypingStack()
        val typingView = typingCoordinator.createTypingView(this).apply {
            visibility = View.GONE
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }
        root.addView(typingView)

        // 挖孔/曲面屏/手势区安全区适配:消费 displayCutout 与导航栏的左右 inset,
        // 作为额外左右内边距叠加到基础 14dp 上,避免 iQOO/OriginOS 等异形屏机型
        // 把工具栏内容压到挖孔或圆角下面导致遮挡。仅横向补偿,不改面板固定高度。
        val basePadH = dp(14)
        val basePadTop = dp(10)
        val basePadBottom = dp(10)
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val cutout = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
            val bars = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
            val extraLeft = maxOf(cutout.left, bars.left)
            val extraRight = maxOf(cutout.right, bars.right)
            v.setPadding(basePadH + extraLeft, basePadTop, basePadH + extraRight, basePadBottom)
            insets
        }

        refreshKeyboardUi()
        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        inputViewActive = true
        currentEditorInfo = info
        realtimeRecognitionEnabled = getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(ApiConfig.KEY_REALTIME_RECOGNITION, false)
        clearTemporaryTextHistory()
        errorMessage = ""
        statusText = if (canRewrite()) MobileStrings.rewriteHint(this) else defaultTranscribeHint()
        rebuildSymbolPanel()
        rebuildPersonaPanel()
        // 快捷键行(换行/撤回/指令/格式化/润色/精简/清空)文案在构建时固化,
        // 每次拉起重建一遍,保证 App 内切换语言后键盘不重启也能跟上
        rebuildShortcutRows()
        ensureTypingStack()
        typingCoordinator.onStartInputView()
        // 拉起面板清空打字候选栏的残留错误提示(如上次的「Timed out…」),避免常驻不消失
        if (::typingSessionHost.isInitialized) typingSessionHost.showStatus(null)
        // 记住上次模式:拉起时恢复到用户上次手动选择的语音/键盘模式(初次默认语音)。
        // 类型感知例外(不覆盖用户模式偏好):
        //  - 数字/电话/日期框:强制键盘模式(数字键盘页),语音输数字不友好;
        //  - 邮箱/URI/密码框:强制键盘模式(英文),语音输账号密码不友好且密码有合规隐患。
        val typedField = typingSessionHost.isNumericField() || typingSessionHost.isEnglishField() ||
            typingSessionHost.isPasswordField()
        if (typedField || typingSessionHost.lastModeKeyboard()) {
            if (!typingCoordinator.active) enterKeyboardMode(persistChoice = !typedField)
        } else if (typingCoordinator.active) {
            exitKeyboardMode()
        }
        refreshKeyboardUi()
        refreshAccountStateForPanel()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        inputViewActive = false
        if (::keyboardMic.isInitialized && keyboardMic.isActive) keyboardMic.stop()
        // 结束输入即清理未完成的 composing/候选,避免下次聚焦残留
        if (::typingCoordinator.isInitialized) typingCoordinator.resetComposing()
    }

    override fun onWindowHidden() {
        super.onWindowHidden()
        // 键盘会话结束(窗口真正收起,而非框间焦点跳转):清除会话级模式粘性
        // (数字页粘性/英文框自动切换)。框间跳转只走 onStartInputView,粘性得以保持(问题3)。
        if (::typingCoordinator.isInitialized) typingCoordinator.onSessionEnd()
    }

    private fun isLoggedIn(): Boolean {
        return AuthSession.isLoggedIn(this)
    }

    private fun getAuthHeader(): String? {
        return AuthSession.authHeader(this)
    }

    private fun toggleHandLayout() {
        rightHandLayout = !rightHandLayout
        getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(PREF_HAND_LAYOUT, rightHandLayout)
            .apply()
        rebuildShortcutRows()
        applyHandLayout(animated = true)
        refreshKeyboardUi()
    }

    private fun toggleFastMode() {
        fastModeEnabled = !fastModeEnabled
        getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(PREF_FAST_MODE, fastModeEnabled)
            .apply()
        refreshKeyboardUi()
    }

    private fun applyHandLayout(animated: Boolean) {
        val content = contentView ?: return
        val voice = voiceColumnView ?: return
        val actions = actionColumnView ?: return
        val reorder = {
            content.removeView(voice)
            content.removeView(actions)
            val voiceParams = LinearLayout.LayoutParams(dp(126), LinearLayout.LayoutParams.MATCH_PARENT)
            val actionParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
            if (rightHandLayout) {
                actionParams.rightMargin = dp(12)
                content.addView(actions, actionParams)
                content.addView(voice, voiceParams)
            } else {
                voiceParams.rightMargin = dp(12)
                content.addView(voice, voiceParams)
                content.addView(actions, actionParams)
            }
        }
        if (!animated || content.childCount == 0) {
            reorder()
            content.alpha = 1f
            return
        }
        content.animate()
            .alpha(0.82f)
            .setDuration(70L)
            .setInterpolator(AccelerateDecelerateInterpolator())
            .withEndAction {
                reorder()
                content.animate()
                    .alpha(1f)
                    .setDuration(120L)
                    .setInterpolator(AccelerateDecelerateInterpolator())
                    .start()
            }
            .start()
    }

    private fun buildUnavailablePanel(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            background = glassCard(dp(16))
            setPadding(dp(14), dp(12), dp(14), dp(12))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(178)
            ).apply {
                topMargin = dp(12)
            }

            unavailableTitleView = TextView(this@LobsterIME).apply {
                setTextColor(LobsterWaterColors.TEXT_MAIN)
                textSize = 15f
                typeface = Typeface.DEFAULT_BOLD
                maxLines = 1
                gravity = Gravity.CENTER
                setIncludeFontPadding(false)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            }
            addView(unavailableTitleView)

            unavailableBodyView = TextView(this@LobsterIME).apply {
                setTextColor(LobsterWaterColors.TEXT_MUTED)
                textSize = 12f
                gravity = Gravity.CENTER
                maxLines = 3
                setIncludeFontPadding(false)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    topMargin = dp(8)
                }
            }
            addView(unavailableBodyView)

            val actionRow = LinearLayout(this@LobsterIME).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    dp(42)
                ).apply {
                    topMargin = dp(16)
                }
            }
            switchKeyboardButton = unavailableActionButton(MobileStrings.switchKeyboard(this@LobsterIME), true).apply {
                setOnClickListener { showInputMethodPicker() }
            }
            actionRow.addView(switchKeyboardButton)

            openAppButton = unavailableActionButton(MobileStrings.openApp(this@LobsterIME), false).apply {
                setOnClickListener { openMainApp() }
            }
            actionRow.addView(openAppButton)
            addView(actionRow)
        }
    }

    private fun unavailableActionButton(label: String, primary: Boolean): TextView {
        return TextView(this).apply {
            text = label
            textSize = 13f
            fitPanelLabel(8, 13)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            setIncludeFontPadding(false)
            setTextColor(if (primary) LobsterWaterColors.TEXT_ON_ACCENT else LobsterWaterColors.ACCENT_DEEP)
            background = if (primary) keycap(radiusDp = 12f, style = LobsterKeycap.Style.PRIMARY) else keycap(radiusDp = 12f)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f).apply {
                if (primary) rightMargin = dp(8)
            }
        }
    }

    private fun showInputMethodPicker() {
        (getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager)
            ?.showInputMethodPicker()
    }

    private fun openMainApp() {
        packageManager.getLaunchIntentForPackage(packageName)?.let { intent ->
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
    }

    private fun refreshAccountStateForPanel() {
        val authHeader = getAuthHeader()
        if (authHeader == null) {
            liveCreditsRemaining = null
            showUnavailable(BlockedReason.LOGIN_REQUIRED)
            return
        }
        verifyAccountState(authHeader, onReady = null, allowFallback = true)
    }

    private fun ensureInputAvailableForAction(onReady: () -> Unit) {
        val authHeader = getAuthHeader()
        if (authHeader == null) {
            liveCreditsRemaining = null
            showUnavailable(BlockedReason.LOGIN_REQUIRED)
            return
        }
        if (liveCreditsRemaining == null || liveCreditsRemaining == 0) {
            verifyAccountState(authHeader, onReady = onReady, allowFallback = liveCreditsRemaining == null)
            return
        }
        clearUnavailableState()
        onReady()
    }

    private fun verifyAccountState(authHeader: String, onReady: (() -> Unit)?, allowFallback: Boolean) {
        if (accountStatusLoading) return
        accountStatusLoading = true
        errorMessage = ""
        statusText = MobileStrings.checkingAccount(this)
        refreshKeyboardUi()

        scope.launch {
            try {
                val response = apiService.getPlanInfo(authHeader)
                if (response.isSuccessful) {
                    val remaining = response.body()?.creditsRemaining ?: 0
                    rememberLiveCredits(remaining)
                    if (remaining > 0) {
                        clearUnavailableState()
                        onReady?.invoke()
                    } else {
                        showUnavailable(BlockedReason.CREDITS_EXHAUSTED)
                    }
                    return@launch
                }
                val errorText = response.errorBody()?.string()
                val apiError = runCatching {
                    GsonBuilder().create().fromJson(errorText, ApiErrorResponse::class.java)
                }.getOrNull()
                if (response.code() == 401 || apiError?.code == "USER_BANNED") {
                    AuthSession.clearIfCurrent(this@LobsterIME, authHeader)
                    liveCreditsRemaining = null
                    showUnavailable(BlockedReason.LOGIN_REQUIRED, MobileStrings.sessionExpired(this@LobsterIME))
                    return@launch
                }
                if (apiError?.code == "CREDITS_EXHAUSTED") {
                    rememberLiveCredits(0)
                    showUnavailable(BlockedReason.CREDITS_EXHAUSTED)
                    return@launch
                }
                if (allowFallback && onReady != null) {
                    clearUnavailableState()
                    onReady.invoke()
                } else if (onReady != null) {
                    showError(apiError?.message ?: MobileStrings.accountCheckFailed(this@LobsterIME, response.code()))
                }
            } catch (e: Exception) {
                if (allowFallback && onReady != null) {
                    clearUnavailableState()
                    onReady.invoke()
                } else if (onReady != null) {
                    showError(e.message ?: MobileStrings.accountCheckFailed(this@LobsterIME))
                }
            } finally {
                accountStatusLoading = false
                refreshKeyboardUi()
            }
        }
    }

    private fun rememberLiveCredits(remaining: Int?) {
        if (remaining == null) return
        liveCreditsRemaining = remaining
        blockedReason = if (remaining <= 0) BlockedReason.CREDITS_EXHAUSTED else null
    }

    private fun showUnavailable(reason: BlockedReason, message: String? = null) {
        blockedReason = reason
        errorMessage = ""
        statusText = message ?: MobileStrings.inputUnavailableTitle(this, reason == BlockedReason.CREDITS_EXHAUSTED)
        refreshKeyboardUi()
    }

    private fun clearUnavailableState() {
        blockedReason = null
        errorMessage = ""
        statusText = if (canRewrite()) MobileStrings.rewriteHint(this) else defaultTranscribeHint()
        refreshKeyboardUi()
    }

    /** 麦克风单击:同步录音的开始/停止入口(同步模式,或停止「指令」发起的同步录音)。 */
    private fun onMicTap() {
        // 同步录音进行中(含「指令」发起):单击停止并送识别。
        if (captureMode == CaptureMode.SYNC) {
            stopRecording()
            return
        }
        // 实时模式下单击不发起同步(实时由长按触发);键盘忙时一律忽略。
        if (realtimeRecognitionEnabled || isBusy) return

        if (!checkRecordPermission()) {
            showError(MobileStrings.micPermission(this))
            return
        }

        ensureInputAvailableForAction {
            startRecording(Operation.TRANSCRIBE)
        }
    }

    /** 麦克风长按按下:发起实时流式录音(仅实时开关开启且空闲时)。 */
    private fun onRealtimePressDown() {
        if (!realtimeRecognitionEnabled || isBusy) return

        realtimePressActive = true
        if (!checkRecordPermission()) {
            realtimePressActive = false
            showError(MobileStrings.micPermission(this))
            return
        }

        ensureInputAvailableForAction {
            startRealtimeRecognition()
        }
    }

    /** 麦克风长按松手:结束实时流式录音。 */
    private fun onRealtimeRelease() {
        realtimePressActive = false
        if (captureMode == CaptureMode.REALTIME || realtimeWsClient != null) {
            stopRealtimeRecognition()
        }
    }

    private fun checkRecordPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun startRecording(operation: Operation) {
        // 麦克风交接保险:同步录音必须独占麦克风。无条件先停实时流(幂等),
        // 杜绝实时流残留的 AudioRecord 与同步 AudioRecord 同时占用麦克风导致首帧 read() 阻塞/崩溃。
        realtimeStreamer.stop()
        // 进入同步捕获(权威同步状态,立即生效)。「指令」改写录音也走这里,与实时开关无关。
        captureMode = CaptureMode.SYNC
        errorMessage = ""
        if (operation == Operation.TRANSCRIBE) {
            pendingRewriteOriginal = ""
            pendingRewriteTarget = RewriteTarget.NONE
        }
        statusText = if (operation == Operation.REWRITE) {
            MobileStrings.tapAgainRewrite(this)
        } else {
            MobileStrings.tapAgainTranscribe(this)
        }
        pendingOperation = operation
        recordingRemainingSec = audioRecorder.maxDurationSec
        refreshKeyboardUi()

        val file = audioRecorder.startRecording()
        if (file == null) {
            captureMode = CaptureMode.IDLE
            restoreRewriteIfNeeded()
            showError(MobileStrings.recordingStartFailed(this))
        }
    }

    private fun stopRecording() {
        val file = audioRecorder.stopRecording()
        if (file != null) {
            processAudio(file, pendingOperation)
        } else {
            captureMode = CaptureMode.IDLE
            restoreRewriteIfNeeded()
            refreshKeyboardUi()
        }
    }

    private fun startRealtimeRecognition() {
        if (!realtimePressActive) return
        val authHeader = getAuthHeader()
        if (authHeader == null) {
            realtimePressActive = false
            showUnavailable(BlockedReason.LOGIN_REQUIRED)
            return
        }

        val language = MobileStrings.currentLanguage(this).code
        val client = createRealtimeClient(authHeader, language)
        pendingOperation = Operation.TRANSCRIBE
        pendingRewriteOriginal = ""
        pendingRewriteTarget = RewriteTarget.NONE
        realtimeTranscript = ""
        realtimeTranscriptLanguage = ""
        realtimeTranscriptPrefix = ""
        realtimeReconnectAttempts = 0
        realtimeConnectError = null
        realtimeAcceptingPreview = client.isReady
        clearRealtimePreview()
        clearRealtimeAudioBuffer()
        clearRealtimeSentTail()
        errorMessage = ""
        realtimeWsClient = client
        realtimeRemainingSec = realtimeStreamer.maxDurationSec
        // 进入实时捕获(权威同步状态,立即生效)。
        captureMode = CaptureMode.REALTIME
        statusText = MobileStrings.releaseToSend(this)
        refreshKeyboardUi()

        val started = realtimeStreamer.start(
            onChunk = { bytes -> handleRealtimeAudioChunk(client, bytes) },
            onMaxDuration = {
                uiHandler.post {
                    realtimePressActive = false
                    stopRealtimeRecognition()
                }
            }
        )
        if (!started) {
            captureMode = CaptureMode.IDLE
            if (realtimeWsClient === client) realtimeWsClient = null
            realtimeAcceptingPreview = false
            clearRealtimeAudioBuffer()
            showError(MobileStrings.recordingStartFailed(this))
            refreshKeyboardUi()
            return
        }

        if (client.isReady) {
            flushBufferedRealtimeAudio(client)
        } else {
            startRealtimeClientConnection(client)
        }
        refreshKeyboardUi()
    }

    private fun stopRealtimeRecognition() {
        if (realtimeFinishing) return

        // 隐患2 修复:无论是否有活动 WS 会话,都先停止流式录音并释放麦克风,
        // 让 captureMode 立即回到 IDLE,避免「会话已空但流仍在跑」导致状态卡死、麦克风占用。
        realtimeAcceptingPreview = false
        realtimeStreamer.stop()
        captureMode = CaptureMode.IDLE
        // 停止录音:立即把预览补齐到完整目标,避免停在"揭示一半"的残缺文本;
        // 最终仍由 commitRealtimeFinalText 用后端权威整句替换,业务结果不受影响。
        realtimeTypewriter.flush()

        val client = realtimeWsClient
        // BUG修复:WS 中途断连(failActiveRealtimeConnection 已置空 client)时,识别预览还留在
        // 输入框里,旧逻辑直接 return——既不投递 LLM 也不清预览,导致"识别完成但没有加工"。
        // 现在只要有已识别文本,即使 WS 已断也照常投递 processRealtimeText(纯文本兜底通道)。
        if (client == null && realtimeTranscript.trim().isEmpty()) {
            FileLog.w("VoiceRT", "release: ws=null transcript=empty, nothing to process")
            realtimeTypewriter.reset()
            clearRealtimeAudioBuffer()
            clearRealtimePreview()
            refreshKeyboardUi()
            return
        }

        realtimeFinishing = true
        isProcessing = true
        errorMessage = ""
        statusText = MobileStrings.realtimeFinishing(this)
        refreshKeyboardUi()

        scope.launch {
            try {
                val transcript: String
                var sessionId: String? = null
                if (client != null) {
                    // 断连重连中/未就绪:等待就绪失败时若已有识别文本,降级为纯文本兜底而非报错丢弃
                    val clientUsable = try {
                        awaitRealtimeClientReady(client)
                        true
                    } catch (e: Exception) {
                        if (realtimeTranscript.trim().isEmpty()) throw e
                        FileLog.w("VoiceRT", "release: ws not ready (${e.message}), fallback transcript-only")
                        false
                    }
                    transcript = realtimeTranscript.trim()
                    if (clientUsable) {
                        flushBufferedRealtimeAudio(client)
                        if (client.requestFinish()) {
                            // 发生过断连重连时,服务端 final 只覆盖最后一段会话,
                            // 不传 session id,让后端直接用客户端拼接全文,避免拼接结果被覆盖。
                            sessionId = if (realtimeTranscriptPrefix.isEmpty()) client.asrSessionId else null
                        } else if (transcript.isEmpty()) {
                            throw IllegalStateException(MobileStrings.processFailed(this@LobsterIME))
                        }
                    }
                } else {
                    transcript = realtimeTranscript.trim()
                    FileLog.w("VoiceRT", "release: ws=null, fallback transcript-only len=${transcript.length}")
                }
                FileLog.i("VoiceRT", "processRealtimeText call: fastMode=$fastModeEnabled len=${transcript.length} session=$sessionId")
                val response = requestRealtimeText(
                    authHeader = getAuthHeader() ?: throw InputUnavailableException(
                        BlockedReason.LOGIN_REQUIRED,
                        MobileStrings.sessionExpired(this@LobsterIME)
                    ),
                    transcript = transcript,
                    asrSessionId = sessionId,
                    clientAsrText = transcript,
                    language = realtimeTranscriptLanguage
                )
                client?.close()
                FileLog.i("VoiceRT", "processRealtimeText ok: action=${response.actionType} resultLen=${outputText(response).length}")
                handleAudioResponse(response, Operation.TRANSCRIBE)
            } catch (e: InputUnavailableException) {
                FileLog.e("VoiceRT", "processRealtimeText unavailable: ${e.reason} ${e.message}")
                historyStore.addFailed(Operation.TRANSCRIBE.apiValue(), e.message ?: MobileStrings.processFailed(this@LobsterIME), null)
                clearRealtimePreview()
                showUnavailable(e.reason, e.message)
            } catch (e: Exception) {
                FileLog.e("VoiceRT", "processRealtimeText failed: ${e.message}")
                // 传输层异常(弱网断链/DNS/超时)不透传 OS 级英文原文
                val display = if (RealtimeAsrWebSocketClient.isNetworkError(e)) {
                    MobileStrings.networkError(this@LobsterIME)
                } else {
                    e.message ?: MobileStrings.processFailed(this@LobsterIME)
                }
                historyStore.addFailed(Operation.TRANSCRIBE.apiValue(), display, null)
                clearRealtimePreview()
                showError(display)
            } finally {
                client?.close()
                clearRealtimeAudioBuffer()
                clearRealtimeSentTail()
                realtimeWsClient = null
                realtimeFinishing = false
                realtimeAcceptingPreview = false
                isProcessing = false
                realtimeTranscript = ""
                realtimeTranscriptLanguage = ""
                realtimeTranscriptPrefix = ""
                realtimeReconnectAttempts = 0
                realtimeTypewriter.reset()
                refreshKeyboardUi()
            }
        }
    }

    private fun createRealtimeClient(authHeader: String, language: String): RealtimeAsrWebSocketClient {
        var clientRef: RealtimeAsrWebSocketClient? = null
        val client = RealtimeAsrWebSocketClient(
            authHeader = authHeader,
            language = language,
            onPartial = { text, detectedLanguage ->
                uiHandler.post {
                    val activeClient = clientRef ?: return@post
                    if (!shouldAcceptRealtimePreview(activeClient)) return@post
                    realtimeTranscriptLanguage = detectedLanguage
                    // 断连续传后新会话的文本与既有前缀做重叠裁剪拼接
                    replaceRealtimePreview(RealtimeResume.mergeWithOverlap(realtimeTranscriptPrefix, text.trim()))
                }
            },
            onCompleted = { text, detectedLanguage ->
                uiHandler.post {
                    val activeClient = clientRef ?: return@post
                    if (!shouldAcceptRealtimePreview(activeClient)) return@post
                    realtimeTranscriptLanguage = detectedLanguage
                    replaceRealtimePreview(RealtimeResume.mergeWithOverlap(realtimeTranscriptPrefix, text.trim()))
                }
            },
            onError = { kind, message ->
                uiHandler.post {
                    val activeClient = clientRef ?: return@post
                    if (realtimeWsClient === activeClient) {
                        // 链路层错误的原始文案是 OS 级英文(如 Software caused connection abort),换成本地化提示
                        val display = if (kind == RealtimeAsrErrorKind.NETWORK) {
                            MobileStrings.networkError(this@LobsterIME)
                        } else {
                            message.ifBlank { MobileStrings.processFailed(this@LobsterIME) }
                        }
                        realtimeConnectError = display
                        if (!realtimeFinishing) {
                            // 链路层断连优先静默重连续传;不可重连(次数用尽/非按住态)才走失败处理
                            if (kind == RealtimeAsrErrorKind.NETWORK && canAttemptRealtimeReconnect()) {
                                beginRealtimeReconnect(activeClient, display)
                            } else {
                                failActiveRealtimeConnection(activeClient, display)
                            }
                        }
                    }
                }
            }
        )
        clientRef = client
        return client
    }

    private fun startRealtimeClientConnection(client: RealtimeAsrWebSocketClient) {
        if (client.isReady) return
        val currentJob = realtimeConnectJob
        if (realtimeWsClient === client && currentJob?.isActive == true) return
        realtimeConnectError = null
        realtimeConnectJob = scope.launch {
            try {
                client.connect()
                if (realtimeWsClient === client) {
                    realtimeConnectError = null
                    realtimeAcceptingPreview = !realtimeFinishing && !isProcessing
                    flushBufferedRealtimeAudio(client)
                    refreshKeyboardUi()
                }
            } catch (e: Exception) {
                // 连接阶段的网络类异常(DNS/超时/断链)同样不能把原始英文文案透传给用户
                val isNetwork = RealtimeAsrWebSocketClient.isNetworkError(e)
                val message = if (isNetwork) {
                    MobileStrings.networkError(this@LobsterIME)
                } else {
                    e.message ?: MobileStrings.processFailed(this@LobsterIME)
                }
                realtimeConnectError = message
                if (realtimeWsClient === client) {
                    if (!realtimeFinishing) {
                        if (isNetwork && canAttemptRealtimeReconnect()) {
                            beginRealtimeReconnect(client, message)
                        } else {
                            failActiveRealtimeConnection(client, message)
                        }
                    }
                } else {
                    client.close()
                }
            }
        }
    }

    private suspend fun awaitRealtimeClientReady(client: RealtimeAsrWebSocketClient) {
        if (!client.isReady) {
            startRealtimeClientConnection(client)
            realtimeConnectJob?.join()
        }
        if (!client.isReady) {
            throw IllegalStateException(realtimeConnectError ?: MobileStrings.processFailed(this@LobsterIME))
        }
    }

    private fun handleRealtimeAudioChunk(client: RealtimeAsrWebSocketClient, bytes: ByteArray) {
        if (realtimeWsClient !== client) return
        if (client.isReady) {
            flushBufferedRealtimeAudio(client)
            if (client.sendAudio(bytes)) {
                recordRealtimeSentTail(bytes)
            } else {
                bufferRealtimeAudio(bytes)
            }
            return
        }
        bufferRealtimeAudio(bytes)
    }

    private fun bufferRealtimeAudio(bytes: ByteArray) {
        synchronized(realtimeAudioBufferLock) {
            while (realtimePendingAudioBytes + bytes.size > REALTIME_AUDIO_BUFFER_LIMIT_BYTES && realtimePendingAudio.isNotEmpty()) {
                realtimePendingAudioBytes -= realtimePendingAudio.removeFirst().size
            }
            if (bytes.size <= REALTIME_AUDIO_BUFFER_LIMIT_BYTES) {
                realtimePendingAudio.addLast(bytes)
                realtimePendingAudioBytes += bytes.size
            }
        }
    }

    private fun flushBufferedRealtimeAudio(client: RealtimeAsrWebSocketClient) {
        if (!client.isReady) return
        val chunks = mutableListOf<ByteArray>()
        synchronized(realtimeAudioBufferLock) {
            while (realtimePendingAudio.isNotEmpty()) {
                chunks.add(realtimePendingAudio.removeFirst())
            }
            realtimePendingAudioBytes = 0
        }
        chunks.forEachIndexed { index, chunk ->
            if (!client.sendAudio(chunk)) {
                bufferRealtimeAudio(chunk)
                for (remainingIndex in index + 1 until chunks.size) {
                    bufferRealtimeAudio(chunks[remainingIndex])
                }
                return
            }
            recordRealtimeSentTail(chunk)
        }
    }

    /** 记录最近已发送音频的尾巴(环形,上限 1.5s),供断连重连时回灌补齐接缝。 */
    private fun recordRealtimeSentTail(bytes: ByteArray) {
        synchronized(realtimeAudioBufferLock) {
            realtimeSentTail.addLast(bytes)
            realtimeSentTailBytes += bytes.size
            while (realtimeSentTailBytes > RealtimeResume.SENT_TAIL_LIMIT_BYTES && realtimeSentTail.isNotEmpty()) {
                realtimeSentTailBytes -= realtimeSentTail.removeFirst().size
            }
        }
    }

    private fun clearRealtimeSentTail() {
        synchronized(realtimeAudioBufferLock) {
            realtimeSentTail.clear()
            realtimeSentTailBytes = 0
        }
    }

    private fun canAttemptRealtimeReconnect(): Boolean {
        return realtimePressActive &&
            captureMode == CaptureMode.REALTIME &&
            realtimeReconnectAttempts < RealtimeResume.MAX_RECONNECT_ATTEMPTS
    }

    /**
     * 弱网断连的静默重连续传:冻结当前整句为前缀,把已发送音频尾巴回灌到待发队列头部,
     * 新建会话续流(录音不中断,UI 无感知);RECONNECT_WINDOW_MS 内未就绪则降级为失败处理
     * (失败处理里已有"保留已识别文本走纯文本兜底"的逻辑)。
     */
    private fun beginRealtimeReconnect(oldClient: RealtimeAsrWebSocketClient, fallbackMessage: String) {
        if (realtimeWsClient !== oldClient) return
        val authHeader = getAuthHeader()
        if (authHeader == null) {
            failActiveRealtimeConnection(oldClient, fallbackMessage)
            return
        }
        realtimeReconnectAttempts++
        FileLog.w(
            "VoiceRT",
            "ws lost, silent reconnect #$realtimeReconnectAttempts transcriptLen=${realtimeTranscript.length}"
        )
        realtimeTranscriptPrefix = realtimeTranscript
        oldClient.close()
        // 尾巴回灌到待发队列头部(尾巴在前、断连期间缓冲的音频在后,保持时间顺序)
        synchronized(realtimeAudioBufferLock) {
            while (realtimeSentTail.isNotEmpty()) {
                val chunk = realtimeSentTail.removeLast()
                realtimePendingAudio.addFirst(chunk)
                realtimePendingAudioBytes += chunk.size
            }
            realtimeSentTailBytes = 0
        }
        val newClient = createRealtimeClient(authHeader, MobileStrings.currentLanguage(this).code)
        realtimeWsClient = newClient
        // 旧连接协程可能仍在收尾,清空引用避免 startRealtimeClientConnection 的防重入守卫误判
        realtimeConnectJob = null
        startRealtimeClientConnection(newClient)
        uiHandler.postDelayed({
            if (realtimeWsClient === newClient && !newClient.isReady && !realtimeFinishing) {
                FileLog.w("VoiceRT", "silent reconnect timed out after ${RealtimeResume.RECONNECT_WINDOW_MS}ms")
                failActiveRealtimeConnection(newClient, fallbackMessage)
            }
        }, RealtimeResume.RECONNECT_WINDOW_MS)
    }

    private fun clearRealtimeAudioBuffer() {
        synchronized(realtimeAudioBufferLock) {
            realtimePendingAudio.clear()
            realtimePendingAudioBytes = 0
        }
    }

    private fun failActiveRealtimeConnection(client: RealtimeAsrWebSocketClient, message: String) {
        if (realtimeWsClient !== client) return
        FileLog.e("VoiceRT", "ws failed mid-session: $message transcriptLen=${realtimeTranscript.length}")
        realtimeStreamer.stop()
        clearRealtimeAudioBuffer()
        clearRealtimeSentTail()
        realtimeAcceptingPreview = false
        realtimeWsClient = null
        client.close()

        // 弱网断链但已有识别文本:不丢用户内容,交给既有 ws=null 纯文本兜底管线
        // (stopRealtimeRecognition 对 client==null 且 transcript 非空的分支)处理。
        if (realtimeTranscript.trim().isNotEmpty()) {
            if (realtimePressActive) {
                // 用户仍按住:保持 REALTIME 捕获态提示网络中断,松手后走兜底加工
                statusText = message
                refreshKeyboardUi()
            } else {
                stopRealtimeRecognition()
            }
            return
        }

        captureMode = CaptureMode.IDLE
        realtimeFinishing = false
        isProcessing = false
        realtimePressActive = false
        showError(message)
    }

    private fun chooseRealtimeTranscript(finalText: String, liveFallback: String): String {
        val final = finalText.trim()
        val fallback = liveFallback.trim()
        if (fallback.isBlank()) return final
        if (final.isBlank()) return fallback
        if (fallback.length > final.length && (fallback.startsWith(final) || fallback.contains(final))) {
            return fallback
        }
        return final
    }

    private fun processAudio(file: File, operation: Operation) {
        // 录音已结束(单击停止或到达最大时长),进入处理态。
        captureMode = CaptureMode.IDLE
        val authHeader = getAuthHeader()
        if (authHeader == null) {
            restoreRewriteIfNeeded()
            file.delete()
            showUnavailable(BlockedReason.LOGIN_REQUIRED)
            return
        }

        isProcessing = true
        errorMessage = ""
        statusText = MobileStrings.processing(this, operation == Operation.REWRITE)
        refreshKeyboardUi()

        scope.launch {
            try {
                val response = uploadAudio(file, authHeader, operation)
                handleAudioResponse(response, operation)
            } catch (e: InputUnavailableException) {
                historyStore.addFailed(operation.apiValue(), e.message ?: MobileStrings.processFailed(this@LobsterIME), pendingRewriteOriginal.takeIf { it.isNotBlank() })
                restoreRewriteIfNeeded()
                showUnavailable(e.reason, e.message)
            } catch (e: Exception) {
                historyStore.addFailed(operation.apiValue(), e.message ?: MobileStrings.processFailed(this@LobsterIME), pendingRewriteOriginal.takeIf { it.isNotBlank() })
                restoreRewriteIfNeeded()
                showError(e.message ?: MobileStrings.processFailed(this@LobsterIME))
            } finally {
                isProcessing = false
                refreshKeyboardUi()
                file.delete()
            }
        }
    }

    private suspend fun uploadAudio(
        file: File,
        authHeader: String,
        operation: Operation
    ): AudioProcessResponse {
        val audioBody = file.asRequestBody("audio/wav".toMediaType())
        val audioPart = MultipartBody.Part.createFormData("file", file.name, audioBody)
        val textMediaType = "text/plain".toMediaType()
        val operationBody = operation.apiValue().toRequestBody(textMediaType)
        val selectedTextBody = if (operation == Operation.REWRITE && pendingRewriteOriginal.isNotBlank()) {
            pendingRewriteOriginal.toRequestBody(textMediaType)
        } else {
            null
        }
        val clipboardHistoryBody = recentContextForServer()
            ?.toRequestBody(textMediaType)
        val fastModeBody = (operation == Operation.TRANSCRIBE && fastModeEnabled).toString().toRequestBody(textMediaType)

        val response = apiService.processAudio(
            token = authHeader,
            audio = audioPart,
            operation = operationBody,
            selectedText = selectedTextBody,
            clipboardHistory = clipboardHistoryBody,
            fastMode = fastModeBody
        )

        if (response.isSuccessful) {
            return response.body() ?: throw IllegalStateException(MobileStrings.emptyResponse(this))
        }

        val errorText = response.errorBody()?.string()
        val apiError = runCatching {
            GsonBuilder().create().fromJson(errorText, ApiErrorResponse::class.java)
        }.getOrNull()
        if (response.code() == 401 || apiError?.code == "USER_BANNED") {
            AuthSession.clearIfCurrent(this, authHeader)
            throw InputUnavailableException(BlockedReason.LOGIN_REQUIRED, MobileStrings.sessionExpired(this))
        }
        if (apiError?.code == "CREDITS_EXHAUSTED") {
            liveCreditsRemaining = 0
            throw InputUnavailableException(BlockedReason.CREDITS_EXHAUSTED, MobileStrings.creditsExhausted(this))
        }
        throw IllegalStateException(apiError?.message ?: MobileStrings.requestFailed(this, response.code()))
    }

    private suspend fun requestRealtimeText(
        authHeader: String,
        transcript: String,
        asrSessionId: String?,
        clientAsrText: String?,
        language: String?
    ): AudioProcessResponse {
        val response = apiService.processRealtimeText(
            token = authHeader,
            request = TextProcessRequest(
                operation = Operation.TRANSCRIBE.apiValue(),
                text = transcript,
                clientAsrText = clientAsrText,
                asrSessionId = asrSessionId,
                clipboardHistory = recentContextListForServer(),
                fastMode = fastModeEnabled,
                transcriptLanguage = language?.takeIf { it.isNotBlank() }
            )
        )

        if (response.isSuccessful) {
            return response.body() ?: throw IllegalStateException(MobileStrings.emptyResponse(this))
        }

        val errorText = response.errorBody()?.string()
        val apiError = runCatching {
            GsonBuilder().create().fromJson(errorText, ApiErrorResponse::class.java)
        }.getOrNull()
        if (response.code() == 401 || apiError?.code == "USER_BANNED") {
            AuthSession.clearIfCurrent(this, authHeader)
            throw InputUnavailableException(BlockedReason.LOGIN_REQUIRED, MobileStrings.sessionExpired(this))
        }
        if (apiError?.code == "CREDITS_EXHAUSTED") {
            liveCreditsRemaining = 0
            throw InputUnavailableException(BlockedReason.CREDITS_EXHAUSTED, MobileStrings.creditsExhausted(this))
        }
        throw IllegalStateException(apiError?.message ?: MobileStrings.requestFailed(this, response.code()))
    }

    private fun handleAudioResponse(response: AudioProcessResponse, operation: Operation) {
        rememberLiveCredits(response.creditsRemaining)
        val output = outputText(response).trim()
        if (output.isEmpty()) {
            val message = if (operation == Operation.REWRITE) {
                MobileStrings.emptyRewrite(this)
            } else {
                MobileStrings.emptyTranscribe(this)
            }
            historyStore.addFailed(operation.apiValue(), message, pendingRewriteOriginal.takeIf { it.isNotBlank() })
            pendingRewriteOriginal = ""
            clearRealtimePreview()
            showError(message)
            return
        }

        historyStore.addSuccess(
            operation = operation.apiValue(),
            transcript = response.transcript,
            result = output,
            actionType = response.actionType.name.lowercase(),
            selectedText = pendingRewriteOriginal.takeIf { it.isNotBlank() }
        )

        val localCommand = if (operation == Operation.TRANSCRIBE) voiceCommand(output) else null
        if (localCommand != null) {
            clearRealtimePreview()
            handleLocalVoiceCommand(localCommand)
            pendingRewriteOriginal = ""
            pendingRewriteTarget = RewriteTarget.NONE
            errorMessage = ""
            refreshKeyboardUi()
            return
        }

        when {
            operation == Operation.REWRITE && pendingRewriteTarget == RewriteTarget.LAST_INSERTED -> {
                // applyProcessedText handles replacing the last inserted text.
            }
            operation == Operation.REWRITE && pendingRewriteTarget == RewriteTarget.SELECTED_TEXT -> {
                // commitText replaces the active selection for editable fields.
            }
        }
        val target = if (operation == Operation.REWRITE) pendingRewriteTarget else RewriteTarget.NONE
        if (operation == Operation.TRANSCRIBE && realtimePreviewLength > 0) {
            commitRealtimeFinalText(output)
        } else {
            applyProcessedText(
                output = output,
                target = target,
                replacedOverride = pendingRewriteOriginal.takeIf { operation == Operation.REWRITE && it.isNotBlank() },
                cacheForRestore = true,
            )
        }
        pendingRewriteOriginal = ""
        pendingRewriteTarget = RewriteTarget.NONE
        statusText = if (operation == Operation.REWRITE) MobileStrings.rewritten(this) else MobileStrings.inserted(this)
        errorMessage = ""
        refreshKeyboardUi()
    }

    private fun handleLocalVoiceCommand(output: String): Boolean {
        return handleLocalVoiceCommand(voiceCommand(output))
    }

    private fun handleLocalVoiceCommand(command: VoiceCommand?): Boolean {
        return when (command) {
            VoiceCommand.NEWLINE -> {
                handleNewline()
                statusText = MobileStrings.inserted(this)
                true
            }
            VoiceCommand.BACKSPACE -> {
                handleBackspace()
                true
            }
            VoiceCommand.UNDO_LAST -> {
                handleUndo()
                true
            }
            null -> false
        }
    }

    private enum class VoiceCommand {
        NEWLINE,
        BACKSPACE,
        UNDO_LAST
    }

    private fun voiceCommand(output: String): VoiceCommand? {
        val compact = output
            .trim()
            .lowercase()
            .replace(Regex("[\\s\\p{Punct}，。！？、；：“”‘’（）【】《》]+"), "")
        val spoken = output.trim().lowercase()
        return when {
            compact in setOf("换行", "另起一行", "新的一行", "下一行", "newline", "newlines", "nextline", "줄바꿈", "새줄") ||
                spoken in setOf("new line", "next line", "new paragraph", "новая строка") -> VoiceCommand.NEWLINE

            compact in setOf("退格", "删除", "删一个字", "删除一个字", "backspace", "delete", "deletechar", "deletecharacter", "삭제") ||
                spoken in setOf("delete last character", "delete character", "удалить", "назад") -> VoiceCommand.BACKSPACE

            compact in setOf("撤回", "撤销", "撤回刚才", "撤销刚才", "删除刚才", "删掉刚才", "清除刚才", "清空刚才", "undo", "clear", "clearthat", "deletethat", "removethat", "취소", "지워") ||
                spoken in setOf("clear that", "delete that", "remove that", "undo that", "отменить") -> VoiceCommand.UNDO_LAST

            else -> null
        }
    }

    private fun outputText(response: AudioProcessResponse): String {
        return when (response.actionType) {
            ActionType.PASTE -> response.result
            ActionType.CLARIFY -> response.clarifyQuestion ?: response.result
            ActionType.SHOW_MARKDOWN,
            ActionType.TIP -> response.result
        }
    }

    private fun outputText(response: TextQuickActionResponse): String {
        return when (response.actionType) {
            ActionType.PASTE,
            ActionType.CLARIFY,
            ActionType.SHOW_MARKDOWN,
            ActionType.TIP -> response.result
        }
    }

    private fun handleRewrite() {
        if (isBusy) return

        if (!checkRecordPermission()) {
            showError(MobileStrings.micPermission(this))
            return
        }

        ensureInputAvailableForAction {
            val selectedText = currentSelectionText()
            when {
                selectedText.isNotBlank() -> {
                    pendingRewriteOriginal = selectedText
                    pendingRewriteTarget = RewriteTarget.SELECTED_TEXT
                }
                lastInsertedText.isNotBlank() -> {
                    pendingRewriteOriginal = lastInsertedText
                    pendingRewriteTarget = RewriteTarget.LAST_INSERTED
                }
                else -> {
                    pendingRewriteOriginal = ""
                    pendingRewriteTarget = RewriteTarget.NONE
                }
            }
            startRecording(Operation.REWRITE)
        }
    }

    private fun handleQuickAction(action: AndroidQuickAction) {
        if (isBusy) return
        ensureInputAvailableForAction {
            performQuickAction(action)
        }
    }

    private fun performQuickAction(action: AndroidQuickAction) {
        val authHeader = getAuthHeader() ?: return showUnavailable(BlockedReason.LOGIN_REQUIRED)

        val selectedText = currentSelectionText()
        val target: RewriteTarget
        val sourceText: String
        when {
            selectedText.isNotBlank() -> {
                target = RewriteTarget.SELECTED_TEXT
                sourceText = selectedText
            }
            lastInsertedText.isNotBlank() -> {
                target = RewriteTarget.LAST_INSERTED
                sourceText = lastInsertedText
            }
            else -> {
                showError(MobileStrings.noRewriteTarget(this))
                return
            }
        }

        isProcessing = true
        errorMessage = ""
        statusText = MobileStrings.quickProcessing(this)
        refreshKeyboardUi()

        scope.launch {
            try {
                val response = requestQuickAction(authHeader, action, sourceText)
                rememberLiveCredits(response.creditsRemaining)
                val output = outputText(response).trim()
                if (output.isBlank()) {
                    showError(MobileStrings.emptyRewrite(this@LobsterIME))
                    return@launch
                }
                applyProcessedText(
                    output = output,
                    target = target,
                    replacedOverride = sourceText,
                    cacheForRestore = false,
                )
                historyStore.addSuccess(
                    operation = response.operation,
                    transcript = response.transcript ?: response.inputText,
                    result = output,
                    actionType = response.actionType.name.lowercase(),
                    selectedText = sourceText
                )
                statusText = MobileStrings.rewritten(this@LobsterIME)
                errorMessage = ""
            } catch (e: InputUnavailableException) {
                historyStore.addFailed("android_quick_${action.name.lowercase()}", e.message ?: MobileStrings.processFailed(this@LobsterIME), sourceText)
                showUnavailable(e.reason, e.message)
            } catch (e: Exception) {
                historyStore.addFailed("android_quick_${action.name.lowercase()}", e.message ?: MobileStrings.processFailed(this@LobsterIME), sourceText)
                showError(e.message ?: MobileStrings.processFailed(this@LobsterIME))
            } finally {
                isProcessing = false
                refreshKeyboardUi()
            }
        }
    }

    private suspend fun requestQuickAction(
        authHeader: String,
        action: AndroidQuickAction,
        sourceText: String
    ): TextQuickActionResponse {
        val response = apiService.quickAction(
            token = authHeader,
            request = AndroidQuickActionRequest(
                action = action,
                text = sourceText,
                sourceOperation = pendingOperation.apiValue()
            )
        )
        if (response.isSuccessful) {
            return response.body() ?: throw IllegalStateException(MobileStrings.emptyResponse(this))
        }
        throw quickActionError(authHeader, response.code(), response.errorBody()?.string())
    }

    private fun quickActionError(authHeader: String, statusCode: Int, errorText: String?): IllegalStateException {
        val apiError = runCatching {
            GsonBuilder().create().fromJson(errorText, ApiErrorResponse::class.java)
        }.getOrNull()
        if (statusCode == 401 || apiError?.code == "USER_BANNED") {
            AuthSession.clearIfCurrent(this, authHeader)
            return InputUnavailableException(BlockedReason.LOGIN_REQUIRED, MobileStrings.sessionExpired(this))
        }
        if (apiError?.code == "CREDITS_EXHAUSTED") {
            liveCreditsRemaining = 0
            return InputUnavailableException(BlockedReason.CREDITS_EXHAUSTED, MobileStrings.creditsExhausted(this))
        }
        return IllegalStateException(apiError?.message ?: MobileStrings.requestFailed(this, statusCode))
    }

    private fun applyProcessedText(
        output: String,
        target: RewriteTarget,
        replacedOverride: String? = null,
        cacheForRestore: Boolean = false,
    ) {
        val replacedText = replacedOverride ?: when (target) {
            RewriteTarget.LAST_INSERTED -> lastInsertedText
            RewriteTarget.SELECTED_TEXT -> currentSelectionText()
            RewriteTarget.NONE -> ""
        }
        if (target == RewriteTarget.LAST_INSERTED && lastInsertedText.isNotBlank()) {
            deleteTextBeforeCursor(lastInsertedText)
        }
        currentInputConnection?.commitText(output, 1)
        lastInsertedText = output
        recordTextState(replacedText)
        recordTextState(output)
        if (cacheForRestore) {
            voiceRestoreText = output
        }
        pendingRewriteOriginal = ""
        pendingRewriteTarget = RewriteTarget.NONE
    }

    private fun handleBackspace() {
        val connection = currentInputConnection ?: return
        val selectedText = connection.getSelectedText(0)?.toString().orEmpty()
        if (selectedText.isNotEmpty()) {
            connection.commitText("", 1)
            if (lastInsertedText == selectedText) {
                lastInsertedText = ""
            } else if (lastInsertedText.contains(selectedText)) {
                lastInsertedText = lastInsertedText.replaceFirst(selectedText, "")
            }
        } else {
            connection.deleteSurroundingText(1, 0)
            if (lastInsertedText.isNotEmpty()) {
                lastInsertedText = lastInsertedText.dropLast(1)
            }
        }
        statusText = defaultTranscribeHint()
        refreshKeyboardUi()
    }

    private fun handleClearInputText() {
        if (isBusy) return
        val connection = currentInputConnection ?: return
        var cleared = false

        connection.beginBatchEdit()
        try {
            connection.finishComposingText()
            val extractedText = connection.getExtractedText(ExtractedTextRequest(), 0)
            val fullText = extractedText?.text?.toString().orEmpty()
            if (fullText.isNotEmpty() && connection.setSelection(0, fullText.length)) {
                cleared = connection.commitText("", 1)
            }

            if (!cleared) {
                val selectedText = connection.getSelectedText(0)?.toString().orEmpty()
                if (selectedText.isNotEmpty()) {
                    cleared = connection.commitText("", 1)
                }
            }

            if (!cleared) {
                val before = connection.getTextBeforeCursor(MAX_SURROUNDING_TEXT_DELETE_CHARS, 0)?.toString().orEmpty()
                val after = connection.getTextAfterCursor(MAX_SURROUNDING_TEXT_DELETE_CHARS, 0)?.toString().orEmpty()
                if (before.isNotEmpty() || after.isNotEmpty()) {
                    cleared = connection.deleteSurroundingText(before.length, after.length)
                }
            }
        } finally {
            connection.endBatchEdit()
        }

        operationTextHistory.clear()
        lastInsertedText = ""
        voiceRestoreText = ""
        pendingRewriteOriginal = ""
        pendingRewriteTarget = RewriteTarget.NONE
        statusText = MobileStrings.inputCleared(this)
        errorMessage = ""
        refreshKeyboardUi()
    }

    private fun handleNewline() {
        val connection = currentInputConnection ?: return
        val committed = connection.commitText("\n", 1)
        if (!committed) {
            val eventTime = System.currentTimeMillis()
            connection.sendKeyEvent(
                KeyEvent(eventTime, eventTime, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER, 0)
            )
            connection.sendKeyEvent(
                KeyEvent(eventTime, eventTime, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER, 0)
            )
        }
        lastInsertedText = "\n"
        recordTextState("\n")
        statusText = MobileStrings.inserted(this)
        errorMessage = ""
        refreshKeyboardUi()
    }

    // ==================== 打字键盘模式 ====================

    private fun ensureTypingStack() {
        if (::typingCoordinator.isInitialized) return
        val prefs = TypingPreferences(this)
        val undoManager = TypingUndoManager()
        val engine = PinyinEngine(this).also { it.loadAsync() }
        typingSessionHost = TypingSessionHost(this, typingImeContext, prefs, composingBridge, undoManager)
        composingBridge.bind({ currentInputConnection }, { keyboardMic.isActive })
        micCoordinator = KeyboardMicCoordinator(typingImeContext, typingSessionHost, keyboardMic)
        typingCoordinator = TypingModeCoordinator(typingSessionHost, composingBridge, micCoordinator, engine)
        typingSessionHost.setStatusCallback { msg -> typingCoordinator.typingView?.showStatus(msg) }
    }

    private val typingImeContext = object : TypingImeContext {
        override fun androidContext(): Context = this@LobsterIME
        override fun inputConnection(): InputConnection? = currentInputConnection
        override fun editorInfo(): EditorInfo? = currentEditorInfo
        override fun isLoggedIn(): Boolean = getAuthHeader() != null
        override fun authHeader(): String? = getAuthHeader()
        override fun isCreditsBlocked(): Boolean = blockedReason == BlockedReason.CREDITS_EXHAUSTED
        override fun ensureInputAvailable(onReady: () -> Unit) = ensureInputAvailableForAction(onReady)
        override fun showTypingMessage(message: String) {
            typingCoordinator.typingView?.showStatus(message)
        }
        override fun performKeyHaptic() {
            typingCoordinator.typingView?.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
        }
        override fun refreshKeyboardUi() = this@LobsterIME.refreshKeyboardUi()
        override fun onTypingModeChanged(active: Boolean) {}
        override fun isMicRecording(): Boolean = keyboardMic.isActive
        override fun requestExitTypingMode() = exitKeyboardMode()
        override fun hasRecordPermission(): Boolean = this@LobsterIME.checkRecordPermission()
    }

    private fun enterKeyboardMode(persistChoice: Boolean = true) {
        if (captureMode != CaptureMode.IDLE) {
            realtimeStreamer.stop()
            runCatching { audioRecorder.stopRecording() }
            captureMode = CaptureMode.IDLE
        }
        symbolPanelVisible = false
        personaPanelVisible = false
        ensureTypingStack()
        typingCoordinator.enter()
        // persistChoice=false:数字框等场景的自动切换,不覆盖用户手动选择的模式偏好
        if (persistChoice) typingSessionHost.setLastModeKeyboard(true) // 记住:用户切到键盘模式
        refreshKeyboardUi()
    }

    private fun exitKeyboardMode() {
        if (::keyboardMic.isInitialized && keyboardMic.isActive) keyboardMic.stop()
        if (::typingCoordinator.isInitialized) typingCoordinator.exit()
        if (::typingSessionHost.isInitialized) typingSessionHost.setLastModeKeyboard(false) // 记住:用户切回语音
        refreshKeyboardUi()
    }

    private val keyboardMicCallbacks = object : KeyboardRealtimeMic.Callbacks {
        override fun language(): String = MobileStrings.currentLanguage(this@LobsterIME).code
        override fun inputConnection(): InputConnection? = currentInputConnection
        override fun onActiveChanged(active: Boolean) {
            if (::micCoordinator.isInitialized) micCoordinator.onMicActiveChanged(active)
        }
        override fun onError(kind: RealtimeAsrErrorKind, message: String) {
            if (!::micCoordinator.isInitialized) return
            // 链路层错误不透传 OS 级英文原文,统一换成本地化网络提示
            val display = if (kind == RealtimeAsrErrorKind.NETWORK) {
                MobileStrings.networkError(this@LobsterIME)
            } else {
                message
            }
            micCoordinator.onMicError(display)
        }
    }

    private fun Button.installBackspaceRepeatTouch() {
        setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    view.isPressed = true
                    backspaceRepeatSession += 1
                    val session = backspaceRepeatSession
                    backspaceRepeatActive = true
                    backspaceLongPressTriggered = false
                    backspaceRepeatHandler.removeCallbacks(backspaceRepeatRunnable)
                    backspaceRepeatHandler.postDelayed({
                        if (backspaceRepeatActive && session == backspaceRepeatSession) {
                            backspaceLongPressTriggered = true
                            handleBackspace()
                            backspaceRepeatHandler.postDelayed(backspaceRepeatRunnable, BACKSPACE_REPEAT_INTERVAL_MS)
                        }
                    }, ViewConfiguration.getLongPressTimeout().toLong())
                    true
                }
                MotionEvent.ACTION_UP -> {
                    view.isPressed = false
                    stopBackspaceRepeat()
                    if (!backspaceLongPressTriggered) {
                        view.performClick()
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    view.isPressed = false
                    stopBackspaceRepeat()
                    true
                }
                else -> false
            }
        }
    }

    private fun stopBackspaceRepeat() {
        backspaceRepeatActive = false
        backspaceRepeatSession += 1
        backspaceRepeatHandler.removeCallbacks(backspaceRepeatRunnable)
    }

    private fun handleUndo() {
        if (operationTextHistory.isEmpty()) {
            statusText = defaultTranscribeHint()
            refreshKeyboardUi()
            return
        }
        val currentText = operationTextHistory.removeAt(operationTextHistory.lastIndex)
        deleteTextBeforeCursor(currentText)
        val previousText = operationTextHistory.lastOrNull().orEmpty()
        if (previousText.isNotBlank()) {
            currentInputConnection?.commitText(previousText, 1)
            lastInsertedText = previousText
        } else {
            lastInsertedText = ""
        }
        statusText = defaultTranscribeHint()
        errorMessage = ""
        refreshKeyboardUi()
    }

    private fun handleRestoreVoiceText() {
        val text = voiceRestoreText.trim()
        if (text.isBlank() || isBusy) return
        val selectedText = currentSelectionText()
        val target = when {
            selectedText.isNotBlank() -> RewriteTarget.SELECTED_TEXT
            lastInsertedText.isNotBlank() -> RewriteTarget.LAST_INSERTED
            else -> RewriteTarget.NONE
        }
        val replaced = when (target) {
            RewriteTarget.SELECTED_TEXT -> selectedText
            RewriteTarget.LAST_INSERTED -> lastInsertedText
            RewriteTarget.NONE -> ""
        }
        applyProcessedText(
            output = text,
            target = target,
            replacedOverride = replaced,
            cacheForRestore = false,
        )
        statusText = MobileStrings.restoredVoice(this)
        errorMessage = ""
        refreshKeyboardUi()
    }

    private fun deleteLastInsertedText() {
        deleteTextBeforeCursor(lastInsertedText)
        lastInsertedText = ""
    }

    private fun deleteTextBeforeCursor(text: String) {
        repeat(text.length) {
            currentInputConnection?.deleteSurroundingText(1, 0)
        }
    }

    private fun commitTextWithHistory(text: String) {
        if (text.isEmpty()) return
        currentInputConnection?.commitText(text, 1)
        lastInsertedText = text
        recordTextState(text)
        errorMessage = ""
        refreshKeyboardUi()
    }

    private fun recordTextState(text: String) {
        if (text.isBlank()) return
        if (operationTextHistory.lastOrNull() == text) return
        operationTextHistory.add(text)
        while (operationTextHistory.size > 20) {
            operationTextHistory.removeAt(0)
        }
    }

    private fun clearTemporaryTextHistory() {
        clearRealtimePreview()
        operationTextHistory.clear()
        lastInsertedText = ""
        voiceRestoreText = ""
        pendingRewriteOriginal = ""
        pendingRewriteTarget = RewriteTarget.NONE
    }

    private fun restoreRewriteIfNeeded() {
        pendingRewriteOriginal = ""
        pendingRewriteTarget = RewriteTarget.NONE
    }

    private fun canRewrite(): Boolean {
        return currentSelectionText().isNotBlank() || lastInsertedText.isNotBlank()
    }

    private fun currentSelectionText(): String {
        return currentInputConnection
            ?.getSelectedText(0)
            ?.toString()
            ?.trim()
            .orEmpty()
    }

    private fun recentContextForServer(): String? {
        val snippets = recentContextListForServer()
        return snippets.takeIf { it.isNotEmpty() }?.let { Gson().toJson(it) }
    }

    private fun recentContextListForServer(): List<String> {
        val connection = currentInputConnection ?: return emptyList()
        val snippets = buildList {
            lastInsertedText.takeIf { it.isNotBlank() }?.let { add(it) }
            surroundingText(connection).takeIf { it.isNotBlank() }?.let { add(it) }
        }.distinct().take(3)
        return snippets
    }

    private fun surroundingText(connection: InputConnection): String {
        val before = connection.getTextBeforeCursor(280, 0)?.toString().orEmpty()
        val after = connection.getTextAfterCursor(120, 0)?.toString().orEmpty()
        return "$before$after".trim()
    }

    private fun defaultTranscribeHint(): String {
        return if (realtimeRecognitionEnabled) {
            MobileStrings.holdToSpeak(this)
        } else {
            MobileStrings.tapToSpeak(this)
        }
    }

    private fun shouldAcceptRealtimePreview(client: RealtimeAsrWebSocketClient): Boolean {
        return realtimeAcceptingPreview &&
            realtimeWsClient === client &&
            !realtimeFinishing &&
            !isProcessing
    }

    private fun replaceRealtimePreview(text: String) {
        if (!realtimeAcceptingPreview) return
        val preview = text.trim()
        if (preview.isEmpty()) {
            realtimeTypewriter.reset()
            clearRealtimePreview()
            realtimeTranscript = ""
            return
        }
        // realtimeTranscript 始终保存"完整目标整句"(供 stop 时作为 clientAsrText 传给后端),
        // 与打字机当前揭示到的前缀无关,避免丢字。
        realtimeTranscript = preview
        realtimeTypewriter.setTarget(preview)
    }

    /**
     * 把打字机"已揭示前缀"渲染到 composing 预览区,并维护预览长度状态。
     * 注意:不修改 realtimeTranscript(完整目标),只负责显示。
     */
    private fun applyRealtimePreview(shown: String) {
        val connection = currentInputConnection ?: return
        if (shown.isEmpty()) {
            clearRealtimePreview()
            return
        }
        val composingApplied = connection.setComposingText(shown, 1)
        if (composingApplied) {
            realtimePreviewComposing = true
            realtimePreviewLength = shown.length
            return
        }
        if (realtimePreviewLength > 0) {
            connection.deleteSurroundingText(realtimePreviewLength, 0)
        }
        connection.commitText(shown, 1)
        realtimePreviewComposing = false
        realtimePreviewLength = shown.length
    }

    private fun clearRealtimePreview() {
        // 任何清空预览的路径都同时停掉打字机,避免遗留 ticker 在已失效的会话上继续渲染。
        realtimeTypewriter.reset()
        val connection = currentInputConnection ?: run {
            realtimePreviewLength = 0
            realtimePreviewComposing = false
            return
        }
        if (realtimePreviewLength > 0) {
            if (realtimePreviewComposing) {
                connection.setComposingText("", 1)
                connection.finishComposingText()
            } else {
                connection.deleteSurroundingText(realtimePreviewLength, 0)
            }
        }
        realtimePreviewLength = 0
        realtimePreviewComposing = false
    }

    private fun commitRealtimeFinalText(text: String) {
        val output = text.trim()
        val connection = currentInputConnection
        if (connection == null) {
            clearRealtimePreview()
            commitTextWithHistory(output)
            return
        }
        if (realtimePreviewLength > 0 && realtimePreviewComposing) {
            connection.commitText(output, 1)
        } else {
            if (realtimePreviewLength > 0) {
                connection.deleteSurroundingText(realtimePreviewLength, 0)
            }
            connection.commitText(output, 1)
        }
        realtimePreviewLength = 0
        realtimePreviewComposing = false
        realtimeTranscript = ""
        lastInsertedText = output
        recordTextState(output)
        voiceRestoreText = output
    }

    private fun currentStatusText(): String {
        return when {
            blockedReason != null -> MobileStrings.inputUnavailableTitle(this, blockedReason == BlockedReason.CREDITS_EXHAUSTED)
            !isLoggedIn() -> MobileStrings.loginRequired(this)
            accountStatusLoading -> MobileStrings.checkingAccount(this)
            isProcessing -> statusText
            captureMode == CaptureMode.REALTIME -> {
                val m = realtimeRemainingSec / 60
                val s = realtimeRemainingSec % 60
                "${statusText.ifBlank { MobileStrings.releaseToSend(this) }}\n${String.format("%02d:%02d", m, s)}"
            }
            captureMode == CaptureMode.SYNC -> {
                val m = recordingRemainingSec / 60
                val s = recordingRemainingSec % 60
                "${statusText}\n${String.format("%02d:%02d", m, s)}"
            }
            canRewrite() -> statusText.ifBlank { MobileStrings.rewriteHint(this) }
            else -> statusText.ifBlank { defaultTranscribeHint() }
        }
    }

    private fun showError(message: String) {
        errorMessage = message
        statusText = message
        refreshKeyboardUi()
    }

    private fun refreshKeyboardUi() {
        // 语音 ↔ 键盘模式切换:淡入淡出过场(仅 alpha/translationY,可见性终态与原逻辑一致)
        if (::typingCoordinator.isInitialized && typingCoordinator.active) {
            setPanelVisibility(voicePanel, false, animate = true)
            setPanelVisibility(symbolPanel, false, animate = true)
            setPanelVisibility(personaPanel, false, animate = true)
            setPanelVisibility(unavailablePanel, false, animate = true)
            setPanelVisibility(typingCoordinator.typingView, true, animate = true)
            return
        }
        setPanelVisibility(typingCoordinator.typingView, false, animate = true)
        val loggedIn = isLoggedIn()
        val isUnavailable = blockedReason != null && !isBusy
        keyboardModeButton?.text = MobileStrings.keyboardModeLabel(this)
        statusTextView?.apply {
            text = if (errorMessage.isNotBlank()) errorMessage else currentStatusText()
            setTextColor(if (errorMessage.isNotBlank()) LobsterWaterColors.ERROR else LobsterWaterColors.TEXT_MAIN)
        }
        unavailableTitleView?.text = MobileStrings.inputUnavailableTitle(this, blockedReason == BlockedReason.CREDITS_EXHAUSTED)
        unavailableBodyView?.text = MobileStrings.inputUnavailableBody(this, blockedReason == BlockedReason.CREDITS_EXHAUSTED)
        switchKeyboardButton?.text = MobileStrings.switchKeyboard(this)
        openAppButton?.text = MobileStrings.openApp(this)
        setPanelVisibility(unavailablePanel, isUnavailable)
        setPanelVisibility(contentView, !isUnavailable)
        commandHintView?.text = MobileStrings.commandHint(this)
        setPanelVisibility(commandHintView, !isUnavailable)
        recordButton?.apply {
            isEnabled = !isProcessing && !accountStatusLoading && loggedIn && blockedReason == null
            alpha = if (isEnabled) 1f else 0.55f
            setOrbState(
                recording = captureMode != CaptureMode.IDLE,
                processing = isProcessing,
                loggedIn = loggedIn && blockedReason == null,
                level = ((if (captureMode == CaptureMode.REALTIME) realtimeAudioLevel else audioLevel) / 100f).coerceIn(0f, 1f)
            )
        }
        undoButton?.apply {
            text = MobileStrings.undo(this@LobsterIME)
            isEnabled = operationTextHistory.isNotEmpty() && !isBusy
            alpha = if (isEnabled) 1f else 0.35f
        }
        restoreButton?.apply {
            text = MobileStrings.restoreVoice(this@LobsterIME)
            isEnabled = voiceRestoreText.isNotBlank() && !isBusy
            alpha = if (isEnabled) 1f else 0.35f
        }
        rewriteButton?.apply {
            text = MobileStrings.rewrite(this@LobsterIME)
            isEnabled = loggedIn && blockedReason == null && !accountStatusLoading && !isBusy
            alpha = if (isEnabled) 1f else 0.35f
        }
        setPanelVisibility(voicePanel, !symbolPanelVisible && !personaPanelVisible, animate = false)
        handLayoutButton?.text = if (rightHandLayout) MobileStrings.rightHand(this) else MobileStrings.leftHand(this)
        // 人设/符号已图标化(🎭/🔣),多语言文案只进无障碍描述(2026-07 去滑动重设计)
        personaToggleButton?.contentDescription = MobileStrings.persona(this)
        symbolToggleButton?.contentDescription = MobileStrings.symbols(this)
        fastModeButton?.apply {
            // 只显示「极速」,开关状态用高亮填充表示(开=蓝宝石强调键帽+白字,关=常态玻璃键帽)
            // 避免"极速 开/关"两段文案在窄列里挤压(俄语 Быстро ВКЛ 最长)
            text = MobileStrings.fastMode(this@LobsterIME)
            background = if (fastModeEnabled) keycap(radiusDp = 15f, style = LobsterKeycap.Style.PRIMARY) else keycap(radiusDp = 15f)
            setTextColor(if (fastModeEnabled) LobsterWaterColors.TEXT_ON_ACCENT else LobsterWaterColors.ACCENT_DEEP)
            alpha = 1f
        }
        setPanelVisibility(symbolPanel, symbolPanelVisible, animate = false)
        setPanelVisibility(personaPanel, personaPanelVisible, animate = false)
    }

    /** 正在播放淡出动画的面板(仅动画簿记,防止淡出途中被要求显示时错过接管)。 */
    private val panelsHiding = mutableSetOf<View>()

    /**
     * 面板可见性切换(纯视觉过场):淡入 200ms(DecelerateInterpolator,translationY 12dp→0)+ 淡出 140ms。
     * 动画只影响 alpha/translationY,结束后必复位 translationY=0,可见性终态与不带动画时完全一致。
     */
    private fun setPanelVisibility(view: View?, visible: Boolean, animate: Boolean = true) {
        view ?: return
        if (!animate) {
            view.animate().cancel()
            panelsHiding.remove(view)
            view.alpha = 1f
            view.translationY = 0f
            view.visibility = if (visible) View.VISIBLE else View.GONE
            return
        }
        if (visible) {
            // 已可见且不在淡出途中:保持原状(不触碰外部管理的 alpha,如提示文案的常驻透明度)
            if (view.visibility == View.VISIBLE && view !in panelsHiding) return
            view.animate().cancel()
            panelsHiding.remove(view)
            if (view.visibility != View.VISIBLE) {
                view.alpha = 0f
                view.translationY = dp(LobsterKeyboardMetrics.ANIM_ENTER_TRANSLATE_DP).toFloat()
                view.visibility = View.VISIBLE
            }
            view.animate()
                .alpha(1f)
                .translationY(0f)
                .setDuration(LobsterKeyboardMetrics.ANIM_ENTER_MS)
                .setInterpolator(DecelerateInterpolator())
                .withEndAction {
                    view.alpha = 1f
                    view.translationY = 0f
                }
                .start()
        } else {
            if (view.visibility != View.VISIBLE) return
            if (view in panelsHiding) return
            view.animate().cancel()
            panelsHiding.add(view)
            view.animate()
                .alpha(0f)
                .setDuration(LobsterKeyboardMetrics.ANIM_EXIT_MS)
                .setInterpolator(AccelerateDecelerateInterpolator())
                .withEndAction {
                    panelsHiding.remove(view)
                    view.visibility = View.GONE
                    view.alpha = 1f
                    view.translationY = 0f
                }
                .start()
        }
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun rounded(color: Int, radius: Int): GradientDrawable {
        return GradientDrawable().apply {
            setColor(color)
            cornerRadius = radius.toFloat()
        }
    }

    /** 面板根背景:纵向冰面渐变(Sapphire Glass)。 */
    private fun panelBackground(): GradientDrawable = GradientDrawable(
        GradientDrawable.Orientation.TOP_BOTTOM,
        intArrayOf(LobsterWaterColors.PANEL_BG_TOP, LobsterWaterColors.PANEL_BG_BOTTOM)
    )

    /** 玻璃卡片:白 → 极淡冰蓝纵向渐变 + BORDER 描边。 */
    private fun glassCard(radius: Int): GradientDrawable = GradientDrawable(
        GradientDrawable.Orientation.TOP_BOTTOM,
        intArrayOf(LobsterWaterColors.SURFACE_GRADIENT_TOP, LobsterWaterColors.SURFACE_GRADIENT_BOTTOM)
    ).apply {
        cornerRadius = radius.toFloat()
        setStroke(dp(1).coerceAtLeast(1), LobsterWaterColors.BORDER)
    }

    /** 按钮背景统一包一层 Ripple(纯按压反馈,不影响任何回调)。 */
    private fun withRipple(content: GradientDrawable, radius: Int, rippleColor: Int): RippleDrawable {
        val mask = GradientDrawable().apply {
            setColor(LobsterWaterColors.PANEL_SURFACE)
            cornerRadius = radius.toFloat()
        }
        return RippleDrawable(ColorStateList.valueOf(rippleColor), content, mask)
    }

    /**
     * 3D 键帽背景(LobsterKeycap 通用构造器,与打字键盘 KeyView 键帽同源):
     * 底缘投影 + 纵向渐变键帽体 + Ripple。胶囊按钮 radiusDp 传视觉高度一半,矩形按钮传 12。
     * 注意布局高度需含投影预留(如 36 视觉高 → BUTTON_TOTAL_HEIGHT_DP=38)。
     */
    private fun keycap(
        radiusDp: Float = LobsterKeyboardMetrics.BUTTON_CORNER_DP.toFloat(),
        style: LobsterKeycap.Style = LobsterKeycap.Style.SECONDARY
    ): RippleDrawable = LobsterKeycap.background(resources.displayMetrics.density, radiusDp, style)

    /** 无描边圆角按钮底 + Ripple(快捷动作按钮等)。 */
    private fun rippleRounded(
        color: Int,
        radius: Int,
        rippleColor: Int = LobsterWaterColors.PRESS_RIPPLE_DARK
    ): RippleDrawable = withRipple(rounded(color, radius), radius, rippleColor)

    private fun rebuildShortcutRows() {
        primaryActionRowView?.let { row ->
            row.removeAllViews()
            val shortcuts = mirroredForCurrentHand(
                listOf(PrimaryShortcut.NEWLINE, PrimaryShortcut.UNDO, PrimaryShortcut.REWRITE)
            )
            shortcuts.forEachIndexed { index, shortcut ->
                row.addView(primaryShortcutButton(shortcut, isLast = index == shortcuts.lastIndex))
            }
        }

        quickTopRowView?.let { row ->
            row.removeAllViews()
            val shortcuts = mirroredForCurrentHand(listOf(QuickShortcut.FORMAT, QuickShortcut.POLISH))
            shortcuts.forEachIndexed { index, shortcut ->
                row.addView(quickActionButton(shortcut, isLast = index == shortcuts.lastIndex))
            }
        }

        quickBottomRowView?.let { row ->
            row.removeAllViews()
            val shortcuts = mirroredForCurrentHand(listOf(QuickShortcut.CONCISE, QuickShortcut.CLEAR))
            shortcuts.forEachIndexed { index, shortcut ->
                row.addView(quickActionButton(shortcut, isLast = index == shortcuts.lastIndex))
            }
        }
    }

    private fun <T> mirroredForCurrentHand(defaultOrder: List<T>): List<T> {
        // Right hand is the default baseline; left hand is always derived from its mirror.
        return if (rightHandLayout) defaultOrder else defaultOrder.asReversed()
    }

    private fun primaryShortcutButton(shortcut: PrimaryShortcut, isLast: Boolean): Button {
        return Button(this).apply {
            when (shortcut) {
                PrimaryShortcut.NEWLINE -> {
                    text = MobileStrings.newline(this@LobsterIME)
                    textSize = 14f
                    fitPanelLabel(9, 14)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setTextColor(LobsterWaterColors.ACCENT_DEEP)
                    background = keycap(radiusDp = 12f)
                    setOnClickListener { handleNewline() }
                }
                PrimaryShortcut.UNDO -> {
                    text = MobileStrings.undo(this@LobsterIME)
                    textSize = 13f
                    fitPanelLabel(9, 13)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setTextColor(LobsterWaterColors.ACCENT_DEEP)
                    background = keycap(radiusDp = 12f)
                    setOnClickListener { handleUndo() }
                    undoButton = this
                }
                PrimaryShortcut.REWRITE -> {
                    text = MobileStrings.rewrite(this@LobsterIME)
                    textSize = 13f
                    fitPanelLabel(9, 13)
                    typeface = Typeface.DEFAULT_BOLD
                    setTextColor(LobsterWaterColors.TEXT_ON_ACCENT)
                    // 强调键帽:与回车键同源(ENTER 渐变 + ENTER_SHADOW 投影)
                    background = keycap(radiusDp = 12f, style = LobsterKeycap.Style.ACCENT)
                    setOnClickListener { handleRewrite() }
                    rewriteButton = this
                }
            }
            setAllCaps(false)
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            setPadding(0, 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(0, dp(42), 1f).apply {
                if (!isLast) rightMargin = dp(8)
            }
        }
    }

    private fun quickActionButton(
        shortcut: QuickShortcut,
        isLast: Boolean
    ): TextView {
        val label = when (shortcut) {
            QuickShortcut.FORMAT -> MobileStrings.quickFormat(this)
            QuickShortcut.POLISH -> MobileStrings.quickPolish(this)
            QuickShortcut.CONCISE -> MobileStrings.quickConcise(this)
            QuickShortcut.CLEAR -> MobileStrings.clearInput(this)
        }
        return TextView(this).apply {
            text = label
            textSize = 13f
            fitPanelLabel(8, 13)
            setTextColor(if (shortcut == QuickShortcut.CLEAR) LobsterWaterColors.ERROR else LobsterWaterColors.ACCENT_DEEP)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            setIncludeFontPadding(false)
            background = keycap(radiusDp = 12f)
            setOnClickListener {
                when (shortcut) {
                    QuickShortcut.FORMAT -> handleQuickAction(AndroidQuickAction.FORMAT)
                    QuickShortcut.POLISH -> handleQuickAction(AndroidQuickAction.POLISH)
                    QuickShortcut.CONCISE -> handleQuickAction(AndroidQuickAction.CONCISE)
                    QuickShortcut.CLEAR -> handleClearInputText()
                }
            }
            layoutParams = LinearLayout.LayoutParams(0, dp(40), 1f).apply {
                if (!isLast) rightMargin = dp(8)
            }
        }
    }

    private fun toggleSymbolPanel() {
        symbolPanelVisible = !symbolPanelVisible
        if (symbolPanelVisible) {
            personaPanelVisible = false
            personaDetail = null
            // 每次进入符号面板默认「最近」,不记忆上次选中的分类
            voiceSymbolCategory = SymbolData.RECENT_ID
            rebuildSymbolPanel()
        }
        refreshKeyboardUi()
    }

    private fun togglePersonaPanel() {
        personaPanelVisible = !personaPanelVisible
        if (personaPanelVisible) {
            symbolPanelVisible = false
            personaDetail = null
            rebuildPersonaPanel()
            loadPersonasForPanel(showLoading = personas.isEmpty())
        }
        refreshKeyboardUi()
    }

    private fun loadPersonasForPanel(showLoading: Boolean = personas.isEmpty()) {
        val authHeader = getAuthHeader()
        if (authHeader == null) {
            showError(MobileStrings.loginRequired(this))
            return
        }
        personasLoading = showLoading
        personasRefreshing = !showLoading
        if (showLoading || personaPanelVisible) {
            rebuildPersonaPanel()
        }
        scope.launch {
            try {
                val response = apiService.getPersonas(authHeader)
                if (response.isSuccessful) {
                    replacePanelPersonas(response.body()?.personas.orEmpty())
                    errorMessage = ""
                } else {
                    throw personaApiError(authHeader, response.code(), response.errorBody()?.string())
                }
            } catch (e: Exception) {
                showError(e.message ?: MobileStrings.mainLoadPersonasFailed(this@LobsterIME))
            } finally {
                personasLoading = false
                personasRefreshing = false
                rebuildPersonaPanel()
                refreshKeyboardUi()
            }
        }
    }

    private fun activatePersonaForPanel(persona: PersonaItem) {
        val authHeader = getAuthHeader() ?: return showError(MobileStrings.loginRequired(this))
        pendingPersonaActionId = persona.id
        rebuildPersonaPanel()
        scope.launch {
            try {
                val response = apiService.activatePersona(authHeader, persona.id)
                if (!response.isSuccessful) {
                    throw personaApiError(authHeader, response.code(), response.errorBody()?.string())
                }
                response.body()?.let { applyActivatedPersona(it) }
                pendingPersonaActionId = null
                rebuildPersonaPanel()
                loadPersonasForPanel(showLoading = false)
            } catch (e: Exception) {
                pendingPersonaActionId = null
                showError(e.message ?: MobileStrings.mainActivatePersonaFailed(this@LobsterIME))
                rebuildPersonaPanel()
                refreshKeyboardUi()
            }
        }
    }

    private fun deactivatePersonasForPanel() {
        val authHeader = getAuthHeader() ?: return showError(MobileStrings.loginRequired(this))
        pendingPersonaActionId = personas.firstOrNull { it.isActive }?.id ?: personaDetail?.id
        rebuildPersonaPanel()
        scope.launch {
            try {
                val response = apiService.deactivatePersonas(authHeader)
                if (!response.isSuccessful) {
                    throw personaApiError(authHeader, response.code(), response.errorBody()?.string())
                }
                clearActivePanelPersona()
                pendingPersonaActionId = null
                rebuildPersonaPanel()
                loadPersonasForPanel(showLoading = false)
            } catch (e: Exception) {
                pendingPersonaActionId = null
                showError(e.message ?: MobileStrings.mainActivatePersonaFailed(this@LobsterIME))
                rebuildPersonaPanel()
                refreshKeyboardUi()
            }
        }
    }

    private enum class PersonaModule {
        TRANSCRIBE,
        REWRITE
    }

    private fun togglePersonaModule(persona: PersonaItem, module: PersonaModule) {
        val authHeader = getAuthHeader() ?: return showError(MobileStrings.loginRequired(this))
        val current = persona.prompts
        val updated = when (module) {
            PersonaModule.TRANSCRIBE -> current.copy(transcribeEnabled = !current.transcribeEnabled && current.transcribePrompt.isPromptConfigured())
            PersonaModule.REWRITE -> current.copy(rewriteEnabled = !current.rewriteEnabled && current.rewritePrompt.isPromptConfigured())
        }
        pendingPersonaActionId = persona.id
        rebuildPersonaPanel()
        scope.launch {
            try {
                val response = apiService.updatePersona(
                    token = authHeader,
                    id = persona.id,
                    body = PersonaUpdateBody(name = null, description = null, prompts = updated)
                )
                if (!response.isSuccessful) {
                    throw personaApiError(authHeader, response.code(), response.errorBody()?.string())
                }
                response.body()?.let { replacePanelPersona(it) }
                pendingPersonaActionId = null
                rebuildPersonaPanel()
                loadPersonasForPanel(showLoading = false)
            } catch (e: Exception) {
                pendingPersonaActionId = null
                showError(e.message ?: MobileStrings.mainSavePersonaFailed(this@LobsterIME))
                rebuildPersonaPanel()
                refreshKeyboardUi()
            }
        }
    }

    private fun replacePanelPersonas(next: List<PersonaItem>) {
        personas = next
        personaDetail = personaDetail?.let { selected ->
            personas.firstOrNull { it.id == selected.id }
        }
    }

    private fun replacePanelPersona(updated: PersonaItem) {
        personas = personas.map { if (it.id == updated.id) updated else it }
        personaDetail = personaDetail?.let { selected ->
            if (selected.id == updated.id) updated else selected
        }
    }

    private fun applyActivatedPersona(activated: PersonaItem) {
        personas = personas.map { persona ->
            if (persona.id == activated.id) activated else persona.copy(isActive = false)
        }
        personaDetail = personaDetail?.let { selected ->
            personas.firstOrNull { it.id == selected.id } ?: selected.copy(isActive = false)
        }
    }

    private fun clearActivePanelPersona() {
        personas = personas.map { persona ->
            if (persona.isBuiltin) {
                persona.copy(isActive = false)
            } else {
                persona.copy(
                    isActive = false,
                    prompts = persona.prompts.copy(
                        transcribeEnabled = false,
                        rewriteEnabled = false,
                        intentEnabled = false
                    )
                )
            }
        }
        personaDetail = personaDetail?.let { persona ->
            persona.copy(
                isActive = false,
                prompts = persona.prompts.copy(
                    transcribeEnabled = false,
                    rewriteEnabled = false,
                    intentEnabled = false
                )
            )
        }
    }

    private fun personaApiError(authHeader: String, statusCode: Int, errorText: String?): IllegalStateException {
        val apiError = runCatching {
            GsonBuilder().create().fromJson(errorText, ApiErrorResponse::class.java)
        }.getOrNull()
        if (statusCode == 401 || apiError?.code == "USER_BANNED") {
            AuthSession.clearIfCurrent(this, authHeader)
            return IllegalStateException(MobileStrings.sessionExpired(this))
        }
        return IllegalStateException(apiError?.message ?: MobileStrings.requestFailed(this, statusCode))
    }

    private fun rebuildPersonaPanel() {
        val panel = personaPanel ?: return
        panel.removeAllViews()
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(36)
            )
        }
        header.addView(SymbolBackButton(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(36), dp(34)).apply {
                leftMargin = dp(2)
                rightMargin = dp(6)
            }
            setOnClickListener {
                if (personaDetail != null) {
                    personaDetail = null
                    rebuildPersonaPanel()
                } else {
                    personaPanelVisible = false
                    refreshKeyboardUi()
                }
            }
        })
        header.addView(TextView(this).apply {
            text = personaDetail?.name ?: MobileStrings.persona(this@LobsterIME)
            setTextColor(LobsterWaterColors.TEXT_MAIN)
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER_VERTICAL
            maxLines = 1
            setIncludeFontPadding(false)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
        })
        header.addView(personaHeaderButton(MobileStrings.refresh(this)).apply {
            alpha = if (personasRefreshing) 0.55f else 1f
            isEnabled = !personasRefreshing
            setOnClickListener { loadPersonasForPanel(showLoading = personas.isEmpty()) }
        })
        panel.addView(header)

        val hint = TextView(this).apply {
            text = if (personaDetail == null) MobileStrings.personaHint(this@LobsterIME) else MobileStrings.personaModuleHint(this@LobsterIME)
            setTextColor(LobsterWaterColors.TEXT_MUTED)
            textSize = 11f
            maxLines = 1
            gravity = Gravity.CENTER_VERTICAL
            setIncludeFontPadding(false)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(22)
            )
        }
        panel.addView(hint)

        if (personasLoading) {
            panel.addView(TextView(this).apply {
                text = MobileStrings.processingShort(this@LobsterIME)
                setTextColor(LobsterWaterColors.TEXT_MUTED)
                textSize = 13f
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    0,
                    1f
                )
            })
            return
        }

        val selected = personaDetail
        if (selected != null) {
            panel.addView(personaDetailView(selected))
        } else {
            panel.addView(personaListView())
        }
    }

    private fun personaListView(): View {
        if (personas.isEmpty()) {
            return TextView(this).apply {
                text = MobileStrings.personaEmpty(this@LobsterIME)
                setTextColor(LobsterWaterColors.TEXT_MUTED)
                textSize = 13f
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    0,
                    1f
                )
            }
        }
        return ScrollView(this).apply {
            isFillViewport = false
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
            addView(LinearLayout(this@LobsterIME).apply {
                orientation = LinearLayout.VERTICAL
                personas.forEach { persona ->
                    addView(personaListRow(persona))
                }
            })
        }
    }

    private fun personaListRow(persona: PersonaItem): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rippleRounded(if (persona.isActive) LobsterWaterColors.BUTTON_BG_STRONG else LobsterWaterColors.BUTTON_BG, dp(12))
            setPadding(dp(10), dp(6), dp(8), dp(6))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(48)
            ).apply { bottomMargin = dp(7) }
            setOnClickListener {
                if (!persona.isBuiltin) {
                    personaDetail = persona
                    rebuildPersonaPanel()
                }
            }
            addView(LinearLayout(this@LobsterIME).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
                addView(TextView(this@LobsterIME).apply {
                    text = persona.name
                    setTextColor(LobsterWaterColors.TEXT_MAIN)
                    textSize = 13f
                    typeface = Typeface.DEFAULT_BOLD
                    maxLines = 1
                    setIncludeFontPadding(false)
                })
                addView(TextView(this@LobsterIME).apply {
                    text = persona.description?.takeIf { it.isNotBlank() }
                        ?: if (persona.isBuiltin) "" else moduleSummary(persona.prompts)
                    setTextColor(LobsterWaterColors.TEXT_MUTED)
                    textSize = 10f
                    maxLines = 1
                    setIncludeFontPadding(false)
                })
            })
            val isPending = pendingPersonaActionId == persona.id
            addView(personaHeaderButton(
                if (isPending) MobileStrings.processingShort(this@LobsterIME)
                else if (persona.isActive) MobileStrings.disable(this@LobsterIME)
                else MobileStrings.enable(this@LobsterIME)
            ).apply {
                alpha = if (pendingPersonaActionId == null || isPending) 1f else 0.55f
                isEnabled = pendingPersonaActionId == null
                setOnClickListener {
                    if (persona.isActive) deactivatePersonasForPanel() else activatePersonaForPanel(persona)
                }
            })
        }
    }

    private fun personaDetailView(persona: PersonaItem): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
            if (!persona.description.isNullOrBlank()) {
                addView(TextView(this@LobsterIME).apply {
                    text = persona.description
                    setTextColor(LobsterWaterColors.TEXT_MUTED)
                    textSize = 11f
                    maxLines = 2
                    setIncludeFontPadding(false)
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        dp(32)
                    ).apply { bottomMargin = dp(4) }
                })
            }
            addView(personaModuleRow(persona, PersonaModule.TRANSCRIBE))
            addView(personaModuleRow(persona, PersonaModule.REWRITE))
            addView(LinearLayout(this@LobsterIME).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    dp(38)
                ).apply { topMargin = dp(6) }
                val isPending = pendingPersonaActionId == persona.id
                addView(personaWideButton(
                    if (isPending) MobileStrings.processingShort(this@LobsterIME)
                    else if (persona.isActive) MobileStrings.disable(this@LobsterIME)
                    else MobileStrings.enable(this@LobsterIME)
                ).apply {
                    isEnabled = pendingPersonaActionId == null
                    alpha = if (pendingPersonaActionId == null || isPending) 1f else 0.55f
                    setOnClickListener {
                        if (persona.isActive) deactivatePersonasForPanel() else activatePersonaForPanel(persona)
                    }
                })
            })
        }
    }

    private fun personaModuleRow(persona: PersonaItem, module: PersonaModule): View {
        val prompts = persona.prompts
        val title = when (module) {
            PersonaModule.TRANSCRIBE -> MobileStrings.personaTranscribe(this)
            PersonaModule.REWRITE -> MobileStrings.personaRewrite(this)
        }
        val prompt = when (module) {
            PersonaModule.TRANSCRIBE -> prompts.transcribePrompt
            PersonaModule.REWRITE -> prompts.rewritePrompt
        }
        val enabled = when (module) {
            PersonaModule.TRANSCRIBE -> prompts.transcribeEnabled
            PersonaModule.REWRITE -> prompts.rewriteEnabled
        }
        val hasPrompt = prompt.isPromptConfigured()
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rippleRounded(if (enabled) LobsterWaterColors.BUTTON_BG_STRONG else LobsterWaterColors.BUTTON_BG, dp(12))
            alpha = if (hasPrompt) 1f else 0.48f
            setPadding(dp(12), 0, dp(8), 0)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(42)
            ).apply { bottomMargin = dp(7) }
            if (hasPrompt && pendingPersonaActionId == null) {
                setOnClickListener { togglePersonaModule(persona, module) }
            }
            addView(TextView(this@LobsterIME).apply {
                text = title
                setTextColor(LobsterWaterColors.TEXT_MAIN)
                textSize = 13f
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER_VERTICAL
                setIncludeFontPadding(false)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
            })
            addView(TextView(this@LobsterIME).apply {
                text = when {
                    enabled -> MobileStrings.active(this@LobsterIME)
                    hasPrompt -> MobileStrings.inactive(this@LobsterIME)
                    else -> MobileStrings.builtin(this@LobsterIME)
                }
                setTextColor(if (enabled) LobsterWaterColors.ACCENT else LobsterWaterColors.TEXT_MUTED)
                textSize = 11f
                gravity = Gravity.CENTER
                typeface = Typeface.DEFAULT_BOLD
                background = rounded(if (enabled) LobsterWaterColors.BADGE_ACTIVE_BG else LobsterWaterColors.BADGE_INACTIVE_BG, dp(18))
                setIncludeFontPadding(false)
                layoutParams = LinearLayout.LayoutParams(dp(66), dp(28))
            })
        }
    }

    private fun personaHeaderButton(label: String): TextView {
        return TextView(this).apply {
            text = label
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            textSize = 12f
            fitPanelLabel(8, 12)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            setIncludeFontPadding(false)
            background = keycap(radiusDp = 16f)
            layoutParams = LinearLayout.LayoutParams(dp(58), dp(32))
        }
    }

    private fun personaWideButton(label: String): TextView {
        return TextView(this).apply {
            text = label
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            textSize = 13f
            fitPanelLabel(9, 13)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            setIncludeFontPadding(false)
            background = keycap(radiusDp = 12f)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(38)
            )
        }
    }

    private fun moduleSummary(prompts: PersonaPrompts): String {
        val enabled = buildList {
            if (prompts.transcribeEnabled) add(MobileStrings.personaTranscribe(this@LobsterIME))
            if (prompts.rewriteEnabled) add(MobileStrings.personaRewrite(this@LobsterIME))
        }
        return if (enabled.isEmpty()) MobileStrings.builtin(this) else enabled.joinToString(" / ")
    }

    /** 语音模式符号面板当前分类(与键盘模式符号板共用 SymbolData 数据与最近使用存储)。 */
    private var voiceSymbolCategory = SymbolData.RECENT_ID

    private fun rebuildSymbolPanel() {
        val panel = symbolPanel ?: return
        panel.removeAllViews()
        val prefs = TypingPreferences(this)
        val recents = prefs.recentSymbols()
        if (voiceSymbolCategory == SymbolData.RECENT_ID && recents.isEmpty()) voiceSymbolCategory = "zh"
        val uiLang = MobileStrings.currentLanguage(this).code

        // 头部:返回 + 标题
        val tools = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }
        tools.addView(SymbolBackButton(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(36), dp(34)).apply {
                leftMargin = dp(2)
                rightMargin = dp(2)
            }
            setOnClickListener {
                symbolPanelVisible = false
                refreshKeyboardUi()
            }
        })
        tools.addView(TextView(this).apply {
            text = MobileStrings.symbols(this@LobsterIME)
            setTextColor(LobsterWaterColors.TEXT_MAIN)
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        panel.addView(tools)

        // 分类标签行(横向滚动):最近 + 全部分类
        val catRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val catIds = listOf(SymbolData.RECENT_ID) + SymbolData.categories.map { it.id }
        for (id in catIds) {
            val active = id == voiceSymbolCategory
            catRow.addView(TextView(this).apply {
                text = SymbolData.label(id, uiLang)
                setTextColor(if (active) LobsterWaterColors.TEXT_ON_ACCENT else LobsterWaterColors.ACCENT_DEEP)
                textSize = 12f
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                setIncludeFontPadding(false)
                setPadding(dp(10), dp(6), dp(10), dp(6))
                background = android.graphics.drawable.GradientDrawable().apply {
                    setColor(if (active) LobsterWaterColors.ACCENT else LobsterWaterColors.BADGE_INACTIVE_BG)
                    cornerRadius = dp(13).toFloat()
                    if (!active) setStroke(dp(1).coerceAtLeast(1), LobsterWaterColors.BORDER)
                }
                setOnClickListener {
                    voiceSymbolCategory = id
                    rebuildSymbolPanel()
                }
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { leftMargin = dp(2); rightMargin = dp(2) }
            })
        }
        panel.addView(android.widget.HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(catRow)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(4) }
        })

        // 符号网格(撑满面板剩余高度,纵向滚动)
        val items = if (voiceSymbolCategory == SymbolData.RECENT_ID) recents
        else SymbolData.categories.firstOrNull { it.id == voiceSymbolCategory }?.items ?: emptyList()
        val grid = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        items.chunked(8).forEach { rowSymbols ->
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = dp(6) }
            }
            rowSymbols.forEach { value ->
                row.addView(symbolButton(value).apply {
                    setOnClickListener {
                        currentInputConnection?.commitText(value, 1)
                        prefs.recordRecentSymbol(value)
                    }
                })
            }
            // 尾行补齐,保持等宽
            repeat(8 - rowSymbols.size) {
                row.addView(View(this), LinearLayout.LayoutParams(dp(36), dp(34)).apply { leftMargin = dp(2); rightMargin = dp(2) })
            }
            grid.addView(row)
        }
        panel.addView(android.widget.ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            addView(grid)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f
            ).apply { topMargin = dp(4) }
        })
    }

    private fun symbolButton(label: String): TextView {
        return TextView(this).apply {
            text = label
            textSize = 14f
            fitPanelLabel(8, 14)
            setTextColor(LobsterWaterColors.ACCENT_DEEP)
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            setIncludeFontPadding(false)
            setPadding(0, 0, 0, 0)
            background = keycap(radiusDp = 12f)
            layoutParams = LinearLayout.LayoutParams(dp(36), dp(34)).apply {
                leftMargin = dp(2)
                rightMargin = dp(2)
            }
        }
    }

    private fun createApiService(): ApiService {
        val loggingInterceptor = HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BASIC
        }
        val client = OkHttpClient.Builder()
            .connectTimeout(ApiConfig.CONNECT_TIMEOUT, TimeUnit.SECONDS)
            .readTimeout(ApiConfig.READ_TIMEOUT, TimeUnit.SECONDS)
            .writeTimeout(ApiConfig.WRITE_TIMEOUT, TimeUnit.SECONDS)
            .addInterceptor { chain ->
                val language = MobileStrings.currentLanguage(this@LobsterIME).code
                val request = chain.request().newBuilder()
                    .header("X-Client-Platform", ApiConfig.CLIENT_PLATFORM)
                    .header("X-Accept-Language", language)
                    .build()
                chain.proceed(request)
            }
            .addInterceptor(loggingInterceptor)
            .build()

        return Retrofit.Builder()
            .baseUrl(ApiConfig.BASE_URL)
            .client(client)
            .addConverterFactory(GsonConverterFactory.create(GsonBuilder().setLenient().create()))
            .build()
            .create(ApiService::class.java)
    }

    private fun Operation.apiValue(): String {
        return when (this) {
            Operation.TRANSCRIBE -> "transcribe"
            Operation.REWRITE -> "rewrite"
        }
    }

    private fun String?.isPromptConfigured(): Boolean {
        return !this.isNullOrBlank()
    }

    private fun TextView.fitPanelLabel(minSp: Int, maxSp: Int) {
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        setSingleLine(true)
        setAutoSizeTextTypeUniformWithConfiguration(
            minSp,
            maxSp,
            1,
            TypedValue.COMPLEX_UNIT_SP
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        stopBackspaceRepeat()
        realtimeWsClient?.let { client ->
            realtimeWsClient = null
            client.close()
        }
        realtimeStreamer.release()
        scope.cancel()
    }
}

private class SymbolBackButton(context: Context) : View(context) {
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = LobsterWaterColors.SYMBOL_BACK_FILL }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = LobsterWaterColors.SYMBOL_BACK_STROKE
        strokeWidth = 4f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        style = Paint.Style.STROKE
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val radius = minOf(width, height) / 2f
        canvas.drawCircle(width / 2f, height / 2f, radius, fillPaint)
        val cx = width / 2f
        val cy = height / 2f
        canvas.drawLine(cx + 7f, cy - 8f, cx - 5f, cy, iconPaint)
        canvas.drawLine(cx - 5f, cy, cx + 7f, cy + 8f, iconPaint)
    }
}

private class FixedHeightImeRoot(
    context: Context,
    private val fixedHeightPx: Int
) : LinearLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        super.onMeasure(
            widthMeasureSpec,
            MeasureSpec.makeMeasureSpec(fixedHeightPx, MeasureSpec.EXACTLY)
        )
        setMeasuredDimension(measuredWidth, fixedHeightPx)
    }
}
