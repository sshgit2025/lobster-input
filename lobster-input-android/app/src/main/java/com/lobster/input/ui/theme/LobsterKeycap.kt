package com.lobster.input.ui.theme

import android.content.res.ColorStateList
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.StateListDrawable
import android.util.StateSet

/**
 * 「Sapphire Glass」通用 3D 键帽背景构造器,与 KeyView 自绘键帽同源的视觉语言:
 * 底缘投影(向下偏移 KEYCAP_SHADOW_DP)+ 纵向渐变键帽体(+1dp 描边)+ 外层 Ripple 按压反馈。
 * 语音面板 / 候选栏 / 符号·人设面板的所有次级、强调、Primary 按钮统一走这里,禁止散落自绘键帽。
 *
 * 注意:投影层占据布局底部 KEYCAP_SHADOW_DP 高度,按钮布局高度需按「视觉高 + 投影」预留
 * (如 36dp 视觉高 → 布局高 LobsterKeyboardMetrics.BUTTON_TOTAL_HEIGHT_DP = 38dp)。
 * 禁用态(state_enabled=false)自动去掉投影,降饱和仍由调用方现有 alpha 逻辑负责。
 */
object LobsterKeycap {

    /**
     * 键帽风格:
     * - SECONDARY:玻璃功能键(FUNC_TOP→FUNC_BOTTOM 渐变 + BORDER 描边 + KEY_SHADOW 投影)。
     * - ACCENT:强调键(ENTER_TOP→ENTER_BOTTOM 渐变 + ENTER_SHADOW 投影,与回车键同源)。
     * - PRIMARY:模式切换胶囊(ACCENT_BRIGHT→ACCENT 渐变不变 + ENTER_SHADOW 投影)。
     */
    enum class Style { SECONDARY, ACCENT, PRIMARY }

    /**
     * 构造 3D 键帽背景。
     * @param density  displayMetrics.density。
     * @param radiusDp 圆角(dp):胶囊按钮传视觉高度一半,矩形按钮传 12。
     */
    fun background(density: Float, radiusDp: Float, style: Style = Style.SECONDARY): RippleDrawable {
        val radiusPx = radiusDp * density
        val shadowPx = (LobsterKeyboardMetrics.KEYCAP_SHADOW_DP * density).toInt().coerceAtLeast(1)

        val shadow = GradientDrawable().apply {
            setColor(if (style == Style.SECONDARY) LobsterWaterColors.KEY_SHADOW else LobsterWaterColors.ENTER_SHADOW)
            cornerRadius = radiusPx
        }
        // 常态:投影向下偏移(上 inset)、键帽体压在投影上方(下 inset)
        val keycap = LayerDrawable(arrayOf(shadow, body(density, radiusPx, style))).apply {
            setLayerInset(0, 0, shadowPx, 0, 0)
            setLayerInset(1, 0, 0, 0, shadowPx)
        }
        // 禁用态:去掉投影,键帽体几何保持一致(不因状态切换跳动)
        val disabled = LayerDrawable(arrayOf(body(density, radiusPx, style))).apply {
            setLayerInset(0, 0, 0, 0, shadowPx)
        }
        val content = StateListDrawable().apply {
            addState(intArrayOf(-android.R.attr.state_enabled), disabled)
            addState(StateSet.WILD_CARD, keycap)
        }
        val mask = GradientDrawable().apply {
            setColor(LobsterWaterColors.PANEL_SURFACE)
            cornerRadius = radiusPx
        }
        val ripple = if (style == Style.SECONDARY) {
            LobsterWaterColors.PRESS_RIPPLE_DARK
        } else {
            LobsterWaterColors.PRESS_RIPPLE_LIGHT
        }
        return RippleDrawable(ColorStateList.valueOf(ripple), content, mask)
    }

    private fun body(density: Float, radiusPx: Float, style: Style): GradientDrawable {
        val colors = when (style) {
            Style.SECONDARY -> intArrayOf(LobsterWaterColors.FUNC_TOP, LobsterWaterColors.FUNC_BOTTOM)
            Style.ACCENT -> intArrayOf(LobsterWaterColors.ENTER_TOP, LobsterWaterColors.ENTER_BOTTOM)
            Style.PRIMARY -> intArrayOf(LobsterWaterColors.ACCENT_BRIGHT, LobsterWaterColors.ACCENT)
        }
        return GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, colors).apply {
            cornerRadius = radiusPx
            if (style == Style.SECONDARY) {
                setStroke((1f * density).toInt().coerceAtLeast(1), LobsterWaterColors.BORDER)
            }
        }
    }
}
