package com.lobster.input.keyboard.typing

import android.annotation.SuppressLint
import android.content.res.ColorStateList
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.keyboard.pinyin.Candidate
import com.lobster.input.keyboard.pinyin.PinyinEngine
import com.lobster.input.keyboard.pinyin.PinyinLoadState
import com.lobster.input.keyboard.typing.composing.ComposingTextBridge
import com.lobster.input.keyboard.typing.coordinator.KeyboardMicCoordinator
import com.lobster.input.ui.theme.LobsterKeyboardMetrics
import com.lobster.input.ui.theme.LobsterKeycap
import com.lobster.input.ui.theme.LobsterWaterColors

/** 打字键盘面板(视图容器)。组装候选栏 + 键区 + 输入阻塞遮罩。 */
@SuppressLint("ViewConstructor")
class TypingKeyboardView(
    context: android.content.Context,
    host: TypingKeyboardHost,
    engine: PinyinEngine,
    composingBridge: ComposingTextBridge,
    private val micCoordinator: KeyboardMicCoordinator
) : FrameLayout(context), KeyboardRenderer, KeyView.Delegate, CandidateBarView.Delegate {

    private val controller = KeyboardController(host, engine, composingBridge)
    private val layoutFactory = KeyboardLayoutFactory(host)

    private val density = context.resources.displayMetrics.density
    private fun dp(v: Float) = (v * density).toInt()

    private val candidateBar: CandidateBarView
    private val keyboardArea: LinearLayout
    private val candidatesPanel: ScrollView
    private val candidatesPanelInner: LinearLayout
    private val bubble: TextView
    private val blockOverlay: View

    private var latestCandidates: List<Candidate> = emptyList()
    private var panelOpen = false

    init {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
        // 面板背景:与语音面板完全一致的纵向冰面渐变
        background = GradientDrawable(
            GradientDrawable.Orientation.TOP_BOTTOM,
            intArrayOf(LobsterWaterColors.PANEL_BG_TOP, LobsterWaterColors.PANEL_BG_BOTTOM)
        )
        // 上 padding 为 0:候选栏顶边与语音面板 header 顶边同一 Y(都从根 padding top=10dp 起算),两模式左上按钮完全对齐
        setPadding(dp(3f), 0, dp(3f), dp(5f))

        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
        }
        addView(column)

        candidateBar = CandidateBarView(context, this)
        column.addView(candidateBar)

        keyboardArea = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        column.addView(keyboardArea)

        // 展开多行候选网格面板:覆盖键区位置,纵向滚动看全部候选(找生僻词)。
        candidatesPanelInner = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(4f), dp(4f), dp(4f), dp(4f))
        }
        candidatesPanel = ScrollView(context).apply {
            isVerticalScrollBarEnabled = true
            visibility = View.GONE
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            addView(candidatesPanelInner)
        }
        column.addView(candidatesPanel)

        bubble = TextView(context).apply {
            setTextColor(LobsterWaterColors.TEXT_MAIN)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 26f)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            includeFontPadding = false
            background = GradientDrawable().apply {
                setColor(LobsterWaterColors.PANEL_SURFACE); cornerRadius = dp(8f).toFloat()
                setStroke(dp(1f).coerceAtLeast(1), LobsterWaterColors.BORDER)
            }
            elevation = dp(4f).toFloat()
            visibility = View.GONE
        }
        addView(bubble, LayoutParams(dp(46f), dp(52f)))

        blockOverlay = View(context).apply {
            setBackgroundColor(LobsterWaterColors.PANEL_SCRIM)
            visibility = View.GONE
            isClickable = true
        }
        addView(blockOverlay, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))

        controller.bind(this)
        rebuildKeyboard()
        controller.refreshCandidates()
    }

    fun resetComposing() = controller.reset()
    fun onSessionEnd() = controller.onSessionEnd()
    fun refreshEnterKey() = rebuildKeyboard()
    fun onEngineLoadState(state: PinyinLoadState, detail: String?) = controller.onEngineLoadState(state, detail)
    fun applyInputBlocked(blocked: Boolean) = controller.setInputBlocked(blocked)
    fun updateMicLevel(level: Float) = candidateBar.updateLevel(level)
    fun setMicProgress(remaining: Float) = candidateBar.setRecordProgress(remaining)
    fun stopMicRecordingUI() = candidateBar.setRecording(false)
    fun showStatus(message: String?) = candidateBar.showStatus(message)

    override fun rebuildKeyboard() {
        if (panelOpen) closeCandidatesPanel()
        candidateBar.setMicVisible(!controller.isPasswordField())
        candidateBar.setMicEnabled(controller.isMicAvailable())
        keyboardArea.removeAllViews()
        if (controller.isToolsPage()) { buildToolsKeyboard(); return }
        if (controller.isEmojiPage()) { buildEmojiKeyboard(); return }
        if (controller.isClipPage()) { buildClipboardKeyboard(); return }
        if (controller.isSymBoardPage()) { buildSymbolBoardKeyboard(); return }
        val state = controller.layoutState()
        val rows = layoutFactory.build(state)
        val rowSpacing = dp(LobsterKeyboardMetrics.KEY_ROW_SPACING_DP.toFloat())
        val rowHeight = dynamicRowHeightPx(rows.size, rowSpacing)
        for (row in rows) {
            val rowView = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, rowHeight).apply { topMargin = rowSpacing }
            }
            for (spec in row) {
                if (spec.type == KeyType.GAP) {
                    rowView.addView(View(context), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, spec.weight))
                    continue
                }
                val keySpec = if (spec.type == KeyType.ENTER) spec.copy(main = controller.enterKeyLabel()) else spec
                rowView.addView(
                    KeyView(context, keySpec, this),
                    LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, spec.weight).apply {
                        leftMargin = dp(2.5f); rightMargin = dp(2.5f)
                    }
                )
            }
            keyboardArea.addView(rowView)
        }
    }

    /**
     * 键区可用高度(px)= 面板内容高(286 - 根上下 padding)- 自身上下 padding - 候选栏行高。
     * 用固定规格反推,不依赖测量时机(rebuild 常发生在布局完成前)。
     */
    private fun keyboardAreaHeightPx(): Int =
        dp(LobsterKeyboardMetrics.TYPING_CONTENT_HEIGHT_DP.toFloat()) - paddingTop - paddingBottom -
            dp(LobsterKeyboardMetrics.TOOLBAR_HEIGHT_DP.toFloat())

    /** 行高动态吃满键区:行高 = (键区可用高 - 行距总和) / 行数,底部不留死空隙(误差 ≤ 行数 px)。 */
    private fun dynamicRowHeightPx(rowCount: Int, rowSpacingPx: Int): Int {
        if (rowCount <= 0) return dp(46f)
        return (keyboardAreaHeightPx() - rowCount * rowSpacingPx) / rowCount
    }

    /** 工具/emoji/剪贴板子页滚动区高度(px):同样吃满键区,只给底部返回栏留位。 */
    private fun subPageScrollHeightPx(footerHeightPx: Int, footerTopMarginPx: Int): Int =
        keyboardAreaHeightPx() - footerHeightPx - footerTopMarginPx

    /** 工具子页(齿轮入口):布局切换 / emoji / 剪贴板 / 俄语·韩语键盘 磁贴 + 返回,不加高面板。 */
    private fun buildToolsKeyboard() {
        val cn = controller.isChineseMode()
        val grid = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(8f), dp(10f), dp(8f), dp(10f)) }
        val lang = controller.currentLang()
        val tiles = ArrayList<Triple<String, String, String>>()
        // 布局切换(26↔九宫格)仅中文有意义
        if (cn) tiles.add(Triple("layout", if (controller.layoutState().nineGrid) "⌨" else "⑨", if (controller.layoutState().nineGrid) MobileStrings.switchTo26Keys(context) else MobileStrings.switchToNineGrid(context)))
        tiles.add(Triple("emoji", "😊", MobileStrings.toolEmoji(context)))
        tiles.add(Triple("clip", "📋", MobileStrings.toolClipboard(context)))
        // 扩展语种键盘直达(对齐 Gboard 语言切换菜单):已在该语种时显示退出,点击回默认语种键盘
        tiles.add(Triple("lang_ru", "РУ", if (lang == InputLang.RU) MobileStrings.exitRussian(context) else "Русский"))
        tiles.add(Triple("lang_ko", "한", if (lang == InputLang.KO) MobileStrings.exitKorean(context) else "한국어"))
        var rowView: LinearLayout? = null
        tiles.forEachIndexed { i, (key, glyph, label) ->
            if (i % 3 == 0) {
                rowView = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT) }
                grid.addView(rowView)
            }
            rowView!!.addView(toolTile(glyph, label) { controller.runTool(key) }, LinearLayout.LayoutParams(0, dp(64f), 1f).apply { leftMargin = dp(5f); rightMargin = dp(5f); topMargin = dp(5f) })
        }
        val scrollView = ScrollView(context).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, subPageScrollHeightPx(dp(40f), dp(2f)))
            addView(grid)
        }
        val footer = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(40f)).apply { topMargin = dp(2f) }
        }
        footer.addView(emojiFooterButton(MobileStrings.back(context)) { controller.handleKey(KeySpec(KeyType.ALPHA)) },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f).apply { leftMargin = dp(3f); rightMargin = dp(3f) })
        keyboardArea.addView(scrollView)
        keyboardArea.addView(footer)
    }

    private fun toolTile(glyph: String, label: String, onClick: () -> Unit) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
        background = GradientDrawable().apply { setColor(LobsterWaterColors.BADGE_INACTIVE_BG); cornerRadius = dp(12f).toFloat(); setStroke(dp(1f).coerceAtLeast(1), LobsterWaterColors.BORDER) }
        addView(TextView(context).apply { text = glyph; setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f); gravity = Gravity.CENTER; includeFontPadding = false })
        addView(TextView(context).apply { text = label; setTextColor(LobsterWaterColors.ACCENT_DEEP); setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f); gravity = Gravity.CENTER; setPadding(0, dp(4f), 0, 0) })
        setOnClickListener { performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP); onClick() }
    }

    /**
     * 分类符号板(问题1):左侧竖排分类标签(最近/中文/英文/括号/数学/序号/货币/箭头),
     * 右侧滚动符号网格;底部返回/删除。数据=SymbolData(脚本验证),最近使用持久化于偏好。
     */
    private var symBoardCategory = SymbolData.RECENT_ID

    /** 进入分类符号板时重置为「最近」,不记忆上次(含语音入口)选中的分类。 */
    override fun onEnterSymBoard() { symBoardCategory = SymbolData.RECENT_ID }

    private fun buildSymbolBoardKeyboard() {
        // 分类切换会直接重入本方法,先清空旧的 body/footer,避免叠层导致点击命中旧视图、切不了分类
        keyboardArea.removeAllViews()
        val uiLang = MobileStrings.currentLanguage(context).code
        val panelH = subPageScrollHeightPx(dp(40f), dp(2f))
        val recents = controller.recentSymbols()
        // 最近为空时默认落到中文分类(避免空面板)
        if (symBoardCategory == SymbolData.RECENT_ID && recents.isEmpty()) symBoardCategory = "zh"

        val body = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, panelH)
        }

        // 左侧分类栏(纵向滚动)
        val catColumn = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(4f), dp(4f), dp(2f), dp(4f)) }
        val catIds = listOf(SymbolData.RECENT_ID) + SymbolData.categories.map { it.id }
        for (id in catIds) {
            val active = id == symBoardCategory
            catColumn.addView(TextView(context).apply {
                text = SymbolData.label(id, uiLang)
                setTextColor(if (active) LobsterWaterColors.TEXT_ON_ACCENT else LobsterWaterColors.ACCENT_DEEP)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                includeFontPadding = false
                background = GradientDrawable().apply {
                    setColor(if (active) LobsterWaterColors.ACCENT else LobsterWaterColors.BADGE_INACTIVE_BG)
                    cornerRadius = dp(8f).toFloat()
                    if (!active) setStroke(dp(1f).coerceAtLeast(1), LobsterWaterColors.BORDER)
                }
                setOnClickListener {
                    performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                    symBoardCategory = id
                    buildSymbolBoardKeyboard()
                }
            }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(34f)).apply { bottomMargin = dp(4f) })
        }
        body.addView(ScrollView(context).apply {
            isVerticalScrollBarEnabled = false
            addView(catColumn)
        }, LinearLayout.LayoutParams(dp(64f), LinearLayout.LayoutParams.MATCH_PARENT))

        // 右侧符号网格(纵向滚动)
        val items = if (symBoardCategory == SymbolData.RECENT_ID) recents
        else SymbolData.categories.firstOrNull { it.id == symBoardCategory }?.items ?: emptyList()
        val cols = ((width - dp(72f)) / dp(46f)).coerceIn(5, 9)
        val grid = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(2f), dp(4f), dp(4f), dp(4f)) }
        var rowView: LinearLayout? = null
        items.forEachIndexed { i, s ->
            if (i % cols == 0) {
                rowView = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT) }
                grid.addView(rowView)
            }
            rowView!!.addView(TextView(context).apply {
                text = s
                setTextColor(LobsterWaterColors.TEXT_MAIN)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                gravity = Gravity.CENTER
                includeFontPadding = false
                background = LobsterKeycap.background(density, 10f)
                setOnClickListener {
                    performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                    controller.selectSymbol(s)
                }
            }, LinearLayout.LayoutParams(0, dp(40f), 1f).apply { leftMargin = dp(2f); rightMargin = dp(2f); topMargin = dp(2f); bottomMargin = dp(2f) })
        }
        // 尾行补齐占位,保证格子等宽
        val rem = items.size % cols
        if (rem != 0) repeat(cols - rem) {
            rowView!!.addView(View(context), LinearLayout.LayoutParams(0, dp(40f), 1f).apply { leftMargin = dp(2f); rightMargin = dp(2f) })
        }
        body.addView(ScrollView(context).apply {
            isVerticalScrollBarEnabled = true
            addView(grid)
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))

        val footer = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(40f)).apply { topMargin = dp(2f) }
        }
        footer.addView(emojiFooterButton(MobileStrings.back(context)) {
            controller.handleKey(KeySpec(KeyType.ALPHA))
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.4f).apply { leftMargin = dp(3f); rightMargin = dp(3f) })
        footer.addView(View(context), LinearLayout.LayoutParams(0, 1, 4f))
        footer.addView(emojiFooterButton("⌫") {
            controller.handleKey(KeySpec(KeyType.DELETE))
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.4f).apply { leftMargin = dp(3f); rightMargin = dp(3f) })

        keyboardArea.addView(body)
        keyboardArea.addView(footer)
    }

    /** emoji 面板:返回栏 + 纵向滚动网格(最近 + 分类) + 删除。 */
    private fun buildEmojiKeyboard() {
        val panelH = subPageScrollHeightPx(dp(40f), dp(2f))
        val cols = ((width - dp(8f)) / dp(46f)).coerceIn(6, 10)

        val grid = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(4f), dp(2f), dp(4f), dp(2f)) }
        val all = ArrayList<String>()
        controller.recentEmojis().let { if (it.isNotEmpty()) all.addAll(it.take(cols * 2)) }
        for (cat in EmojiData.categories) all.addAll(cat.items)
        var rowView: LinearLayout? = null
        all.forEachIndexed { i, e ->
            if (i % cols == 0) {
                rowView = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT) }
                grid.addView(rowView)
            }
            rowView!!.addView(emojiCell(e), LinearLayout.LayoutParams(0, dp(40f), 1f))
        }
        val scrollView = ScrollView(context).apply {
            isVerticalScrollBarEnabled = true
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, panelH)
            addView(grid)
        }

        val footer = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(40f)).apply { topMargin = dp(2f) }
        }
        footer.addView(emojiFooterButton(if (controller.isChineseMode()) MobileStrings.pinyinLabel(context) else MobileStrings.abcKeyLabel(context)) {
            controller.handleKey(KeySpec(KeyType.ALPHA))
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.4f).apply { leftMargin = dp(3f); rightMargin = dp(3f) })
        footer.addView(View(context), LinearLayout.LayoutParams(0, 1, 4f))
        footer.addView(emojiFooterButton("⌫") {
            controller.handleKey(KeySpec(KeyType.DELETE))
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.4f).apply { leftMargin = dp(3f); rightMargin = dp(3f) })

        keyboardArea.addView(scrollView)
        keyboardArea.addView(footer)
    }

    private fun emojiCell(e: String) = TextView(context).apply {
        text = e
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
        gravity = Gravity.CENTER
        includeFontPadding = false
        setOnClickListener {
            performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
            controller.selectEmoji(e)
        }
    }

    private fun emojiFooterButton(label: String, onClick: () -> Unit) = TextView(context).apply {
        text = label
        setTextColor(LobsterWaterColors.ACCENT_DEEP)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        typeface = Typeface.DEFAULT_BOLD
        gravity = Gravity.CENTER
        background = LobsterKeycap.background(density, 12f)
        setOnClickListener { performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP); onClick() }
    }

    /** 剪贴板面板:返回栏 + 剪贴历史(可删) + 快捷短语,纵向滚动,胶囊样式贴合水蓝主题。 */
    private fun buildClipboardKeyboard() {
        val panelH = subPageScrollHeightPx(dp(40f), dp(2f))
        val inner = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(8f), dp(6f), dp(8f), dp(6f)) }

        val history = controller.clipboardHistory()
        inner.addView(clipSectionLabel(MobileStrings.toolClipboard(context)))
        if (history.isEmpty()) {
            inner.addView(clipHint(MobileStrings.clipEmptyHint(context)))
        } else {
            for (item in history) inner.addView(clipItemRow(item, deletable = true))
        }
        inner.addView(clipSectionLabel(MobileStrings.quickPhrasesLabel(context)))
        for (p in controller.quickPhrases()) inner.addView(clipItemRow(p, deletable = false))

        val scrollView = ScrollView(context).apply {
            isVerticalScrollBarEnabled = true
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, panelH)
            addView(inner)
        }
        val footer = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(40f)).apply { topMargin = dp(2f) }
        }
        footer.addView(emojiFooterButton(if (controller.isChineseMode()) MobileStrings.pinyinLabel(context) else MobileStrings.abcKeyLabel(context)) {
            controller.handleKey(KeySpec(KeyType.ALPHA))
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.4f).apply { leftMargin = dp(3f); rightMargin = dp(3f) })
        footer.addView(View(context), LinearLayout.LayoutParams(0, 1, 4f))
        footer.addView(emojiFooterButton(MobileStrings.clearInput(context)) {
            controller.clearClipboard(); buildClipboardKeyboard()
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.4f).apply { leftMargin = dp(3f); rightMargin = dp(3f) })
        keyboardArea.addView(scrollView)
        keyboardArea.addView(footer)
    }

    private fun clipSectionLabel(text: String) = TextView(context).apply {
        this.text = text
        setTextColor(LobsterWaterColors.ACCENT_DEEP)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        typeface = Typeface.DEFAULT_BOLD
        setPadding(dp(4f), dp(8f), dp(4f), dp(4f))
    }

    private fun clipHint(text: String) = TextView(context).apply {
        this.text = text
        setTextColor(LobsterWaterColors.TEXT_MUTED)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setPadding(dp(6f), dp(6f), dp(6f), dp(6f))
    }

    private fun clipItemRow(item: String, deletable: Boolean) = TextView(context).apply {
        text = item
        setTextColor(LobsterWaterColors.TEXT_MAIN)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        maxLines = 2
        ellipsize = android.text.TextUtils.TruncateAt.END
        includeFontPadding = false
        setPadding(dp(12f), dp(11f), dp(12f), dp(11f))
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(6f) }
        background = GradientDrawable().apply {
            setColor(LobsterWaterColors.BADGE_INACTIVE_BG); cornerRadius = dp(12f).toFloat()
            setStroke(dp(1f).coerceAtLeast(1), LobsterWaterColors.BORDER)
        }
        setOnClickListener {
            performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
            controller.selectClip(item)
        }
        if (deletable) setOnLongClickListener {
            performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            controller.removeClipboardItem(item); buildClipboardKeyboard(); true
        }
    }

    override fun renderCandidates(composingDisplay: String, candidates: List<Candidate>, layoutLabel: String) {
        latestCandidates = candidates
        candidateBar.render(composingDisplay, candidates, layoutLabel, controller.layoutState().nineGrid)
        if (panelOpen) {
            if (candidates.isEmpty()) closeCandidatesPanel() else buildCandidatesPanel()
        }
    }

    private var pinyinSelector: ScrollView? = null

    /** 显示/恢复键区最左一列的原按键(选择器覆盖时隐藏,避免重影;INVISIBLE 保留占位不抖动)。 */
    private fun setLeftColumnHidden(hidden: Boolean) {
        for (i in 0 until keyboardArea.childCount) {
            (keyboardArea.getChildAt(i) as? LinearLayout)?.getChildAt(0)?.visibility = if (hidden) View.INVISIBLE else View.VISIBLE
        }
    }

    private var pinyinSelectorInner: LinearLayout? = null

    /** 左侧竖排拼音选择器:覆盖键区最左一列(输入态,搜狗式)。每项固定高度,超出可上下滑动(无滚动条)。 */
    override fun renderPinyinSelector(options: List<String>, active: String) {
        if (options.isEmpty()) { pinyinSelector?.visibility = GONE; setLeftColumnHidden(false); return }
        // 【常驻可改选】展开候选面板时选择器保留(对齐搜狗:展开态左列拼音仍可改选);
        // 键区已隐藏无法重测几何,沿用面板打开前的几何只刷新选项内容。
        if (panelOpen) {
            val sv = pinyinSelector ?: return
            sv.visibility = VISIBLE
            val inner = pinyinSelectorInner ?: return
            inner.removeAllViews()
            for (opt in options) {
                inner.addView(selectorCell(opt, opt == active), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(42f)).apply { topMargin = dp(2f) })
            }
            return
        }
        // 需已完成布局才能定位;未就绪则本帧先隐藏(下次按键布局就绪后自然渲染),不递归 post 以免主线程打满
        if (keyboardArea.height == 0 || keyboardArea.childCount == 0) { pinyinSelector?.visibility = GONE; setLeftColumnHidden(false); return }
        val firstRow = keyboardArea.getChildAt(0) as? LinearLayout ?: return
        val firstKey = firstRow.getChildAt(0) ?: return
        val sv = pinyinSelector ?: ScrollView(context).also { s ->
            s.isVerticalScrollBarEnabled = false
            s.overScrollMode = View.OVER_SCROLL_NEVER
            s.setBackgroundColor(LobsterWaterColors.PANEL_BG)
            val inner = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
            pinyinSelectorInner = inner
            s.addView(inner, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            pinyinSelector = s
            this@TypingKeyboardView.addView(s, LayoutParams(dp(44f), dp(44f)))
        }
        setLeftColumnHidden(true) // 隐藏原左列键,消除重影
        sv.visibility = VISIBLE
        (sv.layoutParams as LayoutParams).apply {
            width = firstKey.right - firstKey.left
            height = keyboardArea.height - dp(5f)
            leftMargin = keyboardArea.left + firstKey.left
            topMargin = keyboardArea.top + firstRow.top + dp(2.5f)
        }
        val inner = pinyinSelectorInner!!
        inner.removeAllViews()
        for (opt in options) {
            // 每项固定高度 dp(42),超出总高则整列可滑动
            inner.addView(selectorCell(opt, opt == active), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(42f)).apply { topMargin = dp(2f) })
        }
        sv.requestLayout()
    }

    private fun selectorCell(text: String, active: Boolean) = TextView(context).apply {
        this.text = text
        gravity = Gravity.CENTER
        includeFontPadding = false
        setTextColor(if (active) LobsterWaterColors.TEXT_ON_ACCENT else LobsterWaterColors.ACCENT_DEEP)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, if (text.length > 3) 11f else 13f)
        typeface = Typeface.DEFAULT_BOLD
        background = GradientDrawable().apply {
            setColor(if (active) LobsterWaterColors.ACCENT else LobsterWaterColors.BADGE_INACTIVE_BG)
            cornerRadius = dp(8f).toFloat()
            if (!active) setStroke(dp(1f).coerceAtLeast(1), LobsterWaterColors.ACCENT_SOFT)
        }
        setOnClickListener {
            performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
            controller.selectT9Pinyin(text)
        }
    }

    /** 展开面板左侧缩进(px):选择器可见时 = 选择器列宽 + 6dp 缝隙(业界:展开态拼音列保留可改选)。 */
    private var panelIndentPx = 0

    private fun toggleCandidatesPanel() {
        if (panelOpen) { closeCandidatesPanel(); return }
        if (latestCandidates.size <= 1) return
        panelOpen = true
        // 【常驻可改选】选择器保留,面板内容右移避让(缩进 = 列宽 + 缝隙)
        panelIndentPx = pinyinSelector?.takeIf { it.visibility == VISIBLE }
            ?.let { (it.layoutParams as LayoutParams).width + dp(6f) } ?: 0
        buildCandidatesPanel()
        if (keyboardArea.height > 0) candidatesPanel.layoutParams = candidatesPanel.layoutParams.apply { height = keyboardArea.height }
        keyboardArea.visibility = View.GONE
        candidatesPanel.visibility = View.VISIBLE
        candidateBar.setExpandedArrow(true)
    }

    private fun closeCandidatesPanel() {
        panelOpen = false
        candidatesPanel.visibility = View.GONE
        keyboardArea.visibility = View.VISIBLE
        candidateBar.setExpandedArrow(false)
        // 收起后恢复选择器(仍处输入态时)
        controller.refreshCandidates()
    }

    /** 贪心换行把全部候选铺成多行网格(选择器可见时整体右移避让,左列拼音可改选)。 */
    private fun buildCandidatesPanel() {
        candidatesPanelInner.removeAllViews()
        candidatesPanelInner.setPadding(panelIndentPx, candidatesPanelInner.paddingTop,
            candidatesPanelInner.paddingRight, candidatesPanelInner.paddingBottom)
        val maxW = (width - dp(16f) - panelIndentPx).coerceAtLeast(dp(200f))
        var row = newPanelRow()
        var rowW = 0
        candidatesPanelInner.addView(row)
        // 全量铺开(引擎输出有界 ≤ ~350;截断会破坏「锁定音节后单字全量可达」,一次性构建无按键时延)
        for (c in latestCandidates) {
            val chip = panelChip(c)
            val chipW = (c.word.length * dp(20f)) + dp(28f)
            if (rowW + chipW > maxW && row.childCount > 0) {
                row = newPanelRow(); rowW = 0; candidatesPanelInner.addView(row)
            }
            row.addView(chip)
            rowW += chipW
        }
    }

    private fun newPanelRow() = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
    }

    private fun panelChip(c: Candidate) = TextView(context).apply {
        text = c.word
        setTextColor(LobsterWaterColors.TEXT_MAIN)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        gravity = Gravity.CENTER
        includeFontPadding = false
        setPadding(dp(12f), dp(8f), dp(12f), dp(8f))
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            rightMargin = dp(4f); bottomMargin = dp(4f)
        }
        // Secondary pill 风格候选 chip(保留小圆角)+ Ripple 按压反馈
        val chipRadius = dp(10f).toFloat()
        background = RippleDrawable(
            ColorStateList.valueOf(LobsterWaterColors.PRESS_RIPPLE_DARK),
            GradientDrawable().apply {
                setColor(LobsterWaterColors.BUTTON_BG); cornerRadius = chipRadius
                setStroke(dp(1f).coerceAtLeast(1), LobsterWaterColors.SECONDARY_STROKE)
            },
            GradientDrawable().apply { setColor(LobsterWaterColors.PANEL_SURFACE); cornerRadius = chipRadius }
        )
        setOnClickListener {
            performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
            closeCandidatesPanel()
            controller.selectCandidate(c)
        }
        setOnLongClickListener {
            performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            controller.forgetCandidate(c)
            if (panelOpen) buildCandidatesPanel()
            true
        }
    }

    override fun invalidateKeys() {
        fun walk(v: View) {
            if (v is KeyView) v.invalidate()
            if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
        }
        walk(keyboardArea)
    }

    override fun setInputBlocked(blocked: Boolean) {
        blockOverlay.visibility = if (blocked) View.VISIBLE else View.GONE
        keyboardArea.alpha = if (blocked) 0.45f else 1f
    }

    override fun renderEngineState(state: PinyinLoadState, detail: String?) {
        candidateBar.renderEngineState(state, detail)
    }

    override fun isShiftActive() = controller.isShiftActive()
    override fun isCapsLock() = controller.isCapsLock()
    override fun isMicActive() = false
    override fun isChineseMode() = controller.isChineseMode()
    override fun onKeyTap(spec: KeySpec) {
        // 录音中按任意键 → 结束实时识别(消费该键,不上屏),符合豆包式交互
        if (micCoordinator.isActive()) { micCoordinator.onRecordEnd(); return }
        controller.handleKey(spec)
    }
    override fun onKeyLongPress(spec: KeySpec) = controller.handleLongPress(spec)
    override fun onDeletePressDown() = controller.onDeletePressDown()
    override fun onDeletePressUp() = controller.onDeletePressUp()
    override fun onSpaceSlide(steps: Int) = controller.moveCursor(steps)

    private val tmpRect = Rect()
    override fun onKeyShowBubble(view: KeyView, text: String) {
        tmpRect.set(0, 0, view.width, view.height)
        offsetDescendantRectToMyCoords(view, tmpRect)
        val bw = dp(46f); val bh = dp(52f)
        val lp = bubble.layoutParams as LayoutParams
        lp.leftMargin = (tmpRect.centerX() - bw / 2).coerceIn(0, (width - bw).coerceAtLeast(0))
        lp.topMargin = (tmpRect.top - bh - dp(2f)).coerceAtLeast(0)
        bubble.layoutParams = lp
        bubble.text = text
        bubble.visibility = View.VISIBLE
    }

    override fun onKeyHideBubble() { bubble.visibility = View.GONE }

    override fun onCandidateSelected(candidate: Candidate) = controller.selectCandidate(candidate)
    override fun onCandidateLongPress(candidate: Candidate) = controller.forgetCandidate(candidate)
    override fun onPinyinOptionSelected(pinyin: String) = controller.selectT9Pinyin(pinyin)
    override fun onReturnToVoice() = controller.returnToVoice()
    override fun onToggleLayout() = controller.toggleLayout()
    override fun onMicRecordStart() = micCoordinator.onRecordStart()
    override fun onMicRecordEnd() = micCoordinator.onRecordEnd()
    override fun onMicCancel() = micCoordinator.onRecordEnd()
    override fun onExpandCandidates() = toggleCandidatesPanel()
    override fun onToolsTapped() = controller.openTools()
    override fun returnVoiceText() = controller.returnVoiceText()
    override fun layoutSwitchText() = controller.layoutSwitchText()
    override fun canUndo() = controller.canUndo()
    override fun onUndo() = controller.handleKey(KeySpec(KeyType.UNDO))
}
