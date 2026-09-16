package com.lobster.input.ui.theme

/**
 * 「Sapphire Glass」蓝宝石玻璃质感设计令牌(输入法面板专用,主 App Compose 亦可引用)。
 * 冰面渐变背景 + 玻璃胶囊按钮 + 3D 键帽;所有键盘 View 的颜色必须收敛引用本文件,禁止散落硬编码。
 */
object LobsterWaterColors {
    // ---- 面板背景(纵向渐变:冰面 → 深一阶,营造冰面深度) ----
    const val PANEL_BG_TOP = 0xFFF4FAFF.toInt()
    const val PANEL_BG_BOTTOM = 0xFFE2EEF9.toInt()

    /** 兼容纯色背景场景(取渐变顶色)。 */
    const val PANEL_BG = PANEL_BG_TOP

    // ---- 表面 / 边框 ----
    const val PANEL_SURFACE = 0xFFFFFFFF.toInt()
    const val SURFACE_MUTED = 0xFFE9F2FA.toInt()
    const val BORDER = 0xFFC9DDEF.toInt()

    /** 玻璃卡片纵向渐变(白 → 极淡冰蓝)。 */
    const val SURFACE_GRADIENT_TOP = 0xFFFFFFFF.toInt()
    const val SURFACE_GRADIENT_BOTTOM = 0xFFF7FBFF.toInt()

    // ---- 蓝宝石 accent 色阶 ----
    const val ACCENT_DEEP = 0xFF0B4E8F.toInt()
    const val ACCENT = 0xFF1268C0.toInt()
    const val ACCENT_BRIGHT = 0xFF3D93E8.toInt()
    const val ACCENT_SOFT = 0xFFA9CFF2.toInt()

    // ---- 玻璃按钮 ----
    const val BUTTON_BG = 0x1A1268C0
    const val BUTTON_BG_STRONG = 0x2E1268C0

    /** 次级按钮(Secondary pill)1dp 描边。 */
    const val SECONDARY_STROKE = 0x99A9CFF2.toInt()

    /** RippleDrawable 按压反馈:浅色涟漪(深色底按钮用)/ 深色涟漪(玻璃底按钮用)。 */
    const val PRESS_RIPPLE_LIGHT = 0x33FFFFFF
    const val PRESS_RIPPLE_DARK = 0x261268C0

    // ---- 文字 ----
    const val TEXT_MAIN = 0xFF0A2C4E.toInt()
    const val TEXT_MUTED = 0xFF54748F.toInt()
    const val TEXT_ON_ACCENT = 0xFFFFFFFF.toInt()
    const val ERROR = 0xFFE5484D.toInt()

    // ---- 徽标 / 遮罩 ----
    const val BADGE_ACTIVE_BG = 0x291268C0
    const val BADGE_INACTIVE_BG = 0x141268C0
    const val PANEL_SCRIM = 0x33FFFFFF

    // ---- 符号面板返回钮 ----
    const val SYMBOL_BACK_FILL = 0x1A1268C0
    const val SYMBOL_BACK_STROKE = 0xFF0B4E8F.toInt()

    // ---- 3D 键帽(纵向渐变) ----
    const val KEY_TOP = 0xFFFFFFFF.toInt()
    const val KEY_BOTTOM = 0xFFEFF6FC.toInt()
    const val KEY_PRESS_TOP = 0xFFD9EAF8.toInt()
    const val KEY_PRESS_BOTTOM = 0xFFCBE1F3.toInt()
    const val FUNC_TOP = 0xFFE7F1FA.toInt()
    const val FUNC_BOTTOM = 0xFFD7E7F5.toInt()
    const val FUNC_PRESS_TOP = 0xFFC9DEF0.toInt()
    const val FUNC_PRESS_BOTTOM = 0xFFBFD7EC.toInt()
    const val KEY_SHADOW = 0x402C4A66

    // ---- 回车键(蓝宝石渐变 + 内顶部高光) ----
    const val ENTER_TOP = 0xFF4D9DEC.toInt()
    const val ENTER_BOTTOM = 0xFF1268C0.toInt()
    const val ENTER_HIGHLIGHT = 0x59FFFFFF
    const val ENTER_SHADOW = 0x730B4E8F

    // ---- 录音钮(冰面 → 深蓝宝石) ----
    const val ORB_TOP = 0xFFBFE0F8.toInt()
    const val ORB_BOTTOM = 0xFF2E7CC9.toInt()
    const val ORB_RIM = 0x8C1268C0.toInt()
    const val ORB_MIC_HI = 0xFFF4FAFF.toInt()
    const val ORB_DOT_DIM = 0x590B4E8F
}

/**
 * 「Sapphire Glass」统一控件规格(纯视觉尺寸/动画常量)。
 */
object LobsterKeyboardMetrics {
    /** 顶栏/候选栏按钮统一高度(dp,键帽体视觉高)。 */
    const val BUTTON_HEIGHT_DP = 36

    /** 3D 键帽底缘投影厚度(dp),LobsterKeycap 的投影层占据布局底部这段高度。 */
    const val KEYCAP_SHADOW_DP = 1.5f

    /** 含底缘投影的标准按钮布局总高(dp)= 36 视觉高 + 2 投影预留,保证键帽体不被压缩。 */
    const val BUTTON_TOTAL_HEIGHT_DP = 38

    /** 顶部工具栏行高(dp):语音 header 与键盘候选栏统一此规格,保证两模式左上按钮 Y 完全对齐。 */
    const val TOOLBAR_HEIGHT_DP = 44

    /** 打字面板内容可用高(dp)= 面板固定高 286 - 根容器上下 padding(10+10),用于键区行高反推吃满面板。 */
    const val TYPING_CONTENT_HEIGHT_DP = 266

    /** 键区行间距(每行 topMargin,dp)。 */
    const val KEY_ROW_SPACING_DP = 5

    /** 顶栏/候选栏按钮统一圆角(dp,胶囊)。 */
    const val BUTTON_CORNER_DP = 18

    /** 键帽圆角(dp)。 */
    const val KEY_CORNER_DP = 8

    /** 面板过场:入场时长(ms)。 */
    const val ANIM_ENTER_MS = 200L

    /** 面板过场:出场时长(ms)。 */
    const val ANIM_EXIT_MS = 140L

    /** 入场时 translationY 起始偏移(dp)。 */
    const val ANIM_ENTER_TRANSLATE_DP = 12

    /** 按压缩放比例(预留视觉 token)。 */
    const val PRESS_SCALE = 0.96f
}
