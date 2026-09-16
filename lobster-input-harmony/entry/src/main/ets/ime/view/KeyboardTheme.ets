/**
 * 「Sapphire Glass」蓝宝石玻璃质感设计令牌(键盘面板专用,色板中枢)。
 * 1:1 移植安卓 ui/theme/LobsterWaterColors.kt + LobsterKeycap.kt(色值原样照搬,禁止散落硬编码)。
 * 冰面渐变背景 + 玻璃胶囊按钮 + 3D 键帽;所有键盘组件的颜色必须收敛引用本文件。
 */

/** 蓝宝石水色板(与安卓 LobsterWaterColors 完全一致,ARGB)。 */
export class LobsterWaterColors {
  // ---- 面板背景(纵向渐变:冰面 → 深一阶,营造冰面深度) ----
  static readonly PANEL_BG_TOP: number = 0xFFF4FAFF
  static readonly PANEL_BG_BOTTOM: number = 0xFFE2EEF9

  /** 兼容纯色背景场景(取渐变顶色)。 */
  static readonly PANEL_BG: number = 0xFFF4FAFF

  // ---- 表面 / 边框 ----
  static readonly PANEL_SURFACE: number = 0xFFFFFFFF
  static readonly SURFACE_MUTED: number = 0xFFE9F2FA
  static readonly BORDER: number = 0xFFC9DDEF

  /** 玻璃卡片纵向渐变(白 → 极淡冰蓝)。 */
  static readonly SURFACE_GRADIENT_TOP: number = 0xFFFFFFFF
  static readonly SURFACE_GRADIENT_BOTTOM: number = 0xFFF7FBFF

  // ---- 蓝宝石 accent 色阶 ----
  static readonly ACCENT_DEEP: number = 0xFF0B4E8F
  static readonly ACCENT: number = 0xFF1268C0
  static readonly ACCENT_BRIGHT: number = 0xFF3D93E8
  static readonly ACCENT_SOFT: number = 0xFFA9CFF2

  // ---- 玻璃按钮 ----
  static readonly BUTTON_BG: number = 0x1A1268C0
  static readonly BUTTON_BG_STRONG: number = 0x2E1268C0

  /** 次级按钮(Secondary pill)1vp 描边。 */
  static readonly SECONDARY_STROKE: number = 0x99A9CFF2

  /** 按压反馈:浅色涟漪(深色底按钮用)/ 深色涟漪(玻璃底按钮用)。 */
  static readonly PRESS_RIPPLE_LIGHT: number = 0x33FFFFFF
  static readonly PRESS_RIPPLE_DARK: number = 0x261268C0

  // ---- 文字 ----
  static readonly TEXT_MAIN: number = 0xFF0A2C4E
  static readonly TEXT_MUTED: number = 0xFF54748F
  static readonly TEXT_ON_ACCENT: number = 0xFFFFFFFF
  static readonly ERROR: number = 0xFFE5484D

  // ---- 徽标 / 遮罩 ----
  static readonly BADGE_ACTIVE_BG: number = 0x291268C0
  static readonly BADGE_INACTIVE_BG: number = 0x141268C0
  static readonly PANEL_SCRIM: number = 0x33FFFFFF

  // ---- 符号面板返回钮 ----
  static readonly SYMBOL_BACK_FILL: number = 0x1A1268C0
  static readonly SYMBOL_BACK_STROKE: number = 0xFF0B4E8F

  // ---- 3D 键帽(纵向渐变) ----
  static readonly KEY_TOP: number = 0xFFFFFFFF
  static readonly KEY_BOTTOM: number = 0xFFEFF6FC
  static readonly KEY_PRESS_TOP: number = 0xFFD9EAF8
  static readonly KEY_PRESS_BOTTOM: number = 0xFFCBE1F3
  static readonly FUNC_TOP: number = 0xFFE7F1FA
  static readonly FUNC_BOTTOM: number = 0xFFD7E7F5
  static readonly FUNC_PRESS_TOP: number = 0xFFC9DEF0
  static readonly FUNC_PRESS_BOTTOM: number = 0xFFBFD7EC
  static readonly KEY_SHADOW: number = 0x402C4A66

  // ---- 回车键(蓝宝石渐变 + 内顶部高光) ----
  static readonly ENTER_TOP: number = 0xFF4D9DEC
  static readonly ENTER_BOTTOM: number = 0xFF1268C0
  static readonly ENTER_HIGHLIGHT: number = 0x59FFFFFF
  static readonly ENTER_SHADOW: number = 0x730B4E8F

  // ---- 录音钮(冰面 → 深蓝宝石) ----
  static readonly ORB_TOP: number = 0xFFBFE0F8
  static readonly ORB_BOTTOM: number = 0xFF2E7CC9
  static readonly ORB_RIM: number = 0x8C1268C0
  static readonly ORB_MIC_HI: number = 0xFFF4FAFF
  static readonly ORB_DOT_DIM: number = 0x590B4E8F
}

/** 「Sapphire Glass」统一控件规格(纯视觉尺寸/动画常量,与安卓 LobsterKeyboardMetrics 一致)。 */
export class LobsterKeyboardMetrics {
  /** 键盘面板固定总高(vp,对应安卓 KEYBOARD_PANEL_HEIGHT_DP / FixedHeightImeRoot)。 */
  static readonly PANEL_HEIGHT_DP: number = 286

  /** 语音面板根容器左右 padding(vp,对应安卓 root.setPadding(14,10,14,10))。 */
  static readonly VOICE_ROOT_PADDING_H_DP: number = 14

  /** 语音面板根容器上下 padding(vp)。 */
  static readonly VOICE_ROOT_PADDING_V_DP: number = 10

  /** 顶栏/候选栏按钮统一高度(vp,键帽体视觉高)。 */
  static readonly BUTTON_HEIGHT_DP: number = 36

  /** 3D 键帽底缘投影厚度(vp)。 */
  static readonly KEYCAP_SHADOW_DP: number = 1.5

  /** 含底缘投影的标准按钮布局总高(vp)= 36 视觉高 + 2 投影预留。 */
  static readonly BUTTON_TOTAL_HEIGHT_DP: number = 38

  /** 顶部工具栏行高(vp):语音 header 与键盘候选栏统一此规格。 */
  static readonly TOOLBAR_HEIGHT_DP: number = 44

  /** 打字面板内容可用高(vp)= 面板固定高 286 - 根容器上下 padding(10+10)。 */
  static readonly TYPING_CONTENT_HEIGHT_DP: number = 266

  /** 键区行间距(每行 topMargin,vp)。 */
  static readonly KEY_ROW_SPACING_DP: number = 5

  /** 顶栏/候选栏按钮统一圆角(vp,胶囊)。 */
  static readonly BUTTON_CORNER_DP: number = 18

  /** 键帽圆角(vp)。 */
  static readonly KEY_CORNER_DP: number = 8

  /** 面板过场:入场时长(ms)。 */
  static readonly ANIM_ENTER_MS: number = 200

  /** 面板过场:出场时长(ms)。 */
  static readonly ANIM_EXIT_MS: number = 140

  /** 入场时 translationY 起始偏移(vp)。 */
  static readonly ANIM_ENTER_TRANSLATE_DP: number = 12

  /** 按压缩放比例(预留视觉 token)。 */
  static readonly PRESS_SCALE: number = 0.96
}

/**
 * 键帽风格(与安卓 LobsterKeycap.Style 对齐):
 * - SECONDARY:玻璃功能键(FUNC_TOP→FUNC_BOTTOM 渐变 + BORDER 描边 + KEY_SHADOW 投影)。
 * - ACCENT:强调键(ENTER_TOP→ENTER_BOTTOM 渐变 + ENTER_SHADOW 投影,与回车键同源)。
 * - PRIMARY:模式切换胶囊(ACCENT_BRIGHT→ACCENT 渐变 + ENTER_SHADOW 投影)。
 */
export enum KeycapStyle {
  SECONDARY = 0,
  ACCENT = 1,
  PRIMARY = 2
}

/** 一组键帽渲染令牌(渐变/描边/投影),由 LobsterKeycap.tokens 产出。 */
export class KeycapTokens {
  gradientTop: number = LobsterWaterColors.FUNC_TOP
  gradientBottom: number = LobsterWaterColors.FUNC_BOTTOM
  shadowColor: number = LobsterWaterColors.KEY_SHADOW
  strokeColor: number = LobsterWaterColors.BORDER
  hasStroke: boolean = true
  rippleColor: number = LobsterWaterColors.PRESS_RIPPLE_DARK
}

/**
 * 「Sapphire Glass」通用 3D 键帽令牌构造器(安卓 LobsterKeycap.background 的声明式等价物):
 * 底缘投影 + 纵向渐变键帽体(SECONDARY 加 1vp 描边)。按压反馈由组件 stateStyles 透明度模拟
 * (ArkUI 无 RippleDrawable,妥协点)。
 */
export class LobsterKeycap {
  static tokens(style: KeycapStyle): KeycapTokens {
    const t = new KeycapTokens()
    if (style === KeycapStyle.SECONDARY) {
      t.gradientTop = LobsterWaterColors.FUNC_TOP
      t.gradientBottom = LobsterWaterColors.FUNC_BOTTOM
      t.shadowColor = LobsterWaterColors.KEY_SHADOW
      t.strokeColor = LobsterWaterColors.BORDER
      t.hasStroke = true
      t.rippleColor = LobsterWaterColors.PRESS_RIPPLE_DARK
    } else if (style === KeycapStyle.ACCENT) {
      t.gradientTop = LobsterWaterColors.ENTER_TOP
      t.gradientBottom = LobsterWaterColors.ENTER_BOTTOM
      t.shadowColor = LobsterWaterColors.ENTER_SHADOW
      t.hasStroke = false
      t.rippleColor = LobsterWaterColors.PRESS_RIPPLE_LIGHT
    } else {
      t.gradientTop = LobsterWaterColors.ACCENT_BRIGHT
      t.gradientBottom = LobsterWaterColors.ACCENT
      t.shadowColor = LobsterWaterColors.ENTER_SHADOW
      t.hasStroke = false
      t.rippleColor = LobsterWaterColors.PRESS_RIPPLE_LIGHT
    }
    return t
  }
}

/** ARGB 数值色 → canvas 可用的 rgba() 字符串(带指定透明度,0-1)。 */
export function rgbaOf(argb: number, alpha01: number): string {
  const r = (argb >>> 16) & 0xFF
  const g = (argb >>> 8) & 0xFF
  const b = argb & 0xFF
  const a = Math.max(0, Math.min(1, alpha01))
  return `rgba(${r},${g},${b},${a.toFixed(3)})`
}

/** ARGB 数值色 → canvas 可用的 rgba() 字符串(透明度取自自身 alpha 通道)。 */
export function cssOf(argb: number): string {
  const a = ((argb >>> 24) & 0xFF) / 255
  return rgbaOf(argb, a)
}

/** canvas 字体串(尺寸 vp)。 */
export function canvasFont(sizeVp: number, bold: boolean): string {
  return (bold ? 'bold ' : '') + sizeVp.toString() + 'vp sans-serif'
}

/** 圆角矩形路径(canvas 无内置 roundRect,统一走此 helper)。 */
export function roundRectPath(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
  const rr = Math.min(r, Math.min(w, h) / 2)
  ctx.beginPath()
  ctx.moveTo(x + rr, y)
  ctx.arcTo(x + w, y, x + w, y + h, rr)
  ctx.arcTo(x + w, y + h, x, y + h, rr)
  ctx.arcTo(x, y + h, x, y, rr)
  ctx.arcTo(x, y, x + w, y, rr)
  ctx.closePath()
}

/** 角度 → 弧度(安卓 drawArc 用角度,canvas 用弧度)。 */
export function rad(deg: number): number {
  return deg * Math.PI / 180
}

/**
 * Sapphire Glass 3D 键帽胶囊按钮(安卓 LobsterKeycap 同源):
 * primary=蓝宝石纵向渐变白字;secondary=FUNC 渐变键帽 + 1vp 描边、文字 ACCENT_DEEP;
 * 均带底缘投影;按压反馈用透明度模拟 Ripple(妥协点)。
 */
@Component
export struct KeycapButton {
  label: string = ''
  primary: boolean = false
  fontSizeFp: number = 12.5
  radiusVp: number = LobsterKeyboardMetrics.BUTTON_CORNER_DP
  heightVp: number = LobsterKeyboardMetrics.BUTTON_HEIGHT_DP
  /** 撑满父容器宽度(子页 footer 按钮用);候选栏胶囊为包内容宽。 */
  stretch: boolean = false
  bold: boolean = true
  /** 文字颜色覆盖(0=按 primary 取默认)。 */
  textColorOverride: number = 0
  onTap: () => void = () => {}

  @Styles
  pressedStyle() {
    .opacity(0.78)
  }

  @Styles
  normalStyle() {
    .opacity(1)
  }

  private gradColors(): [ResourceColor, number][] {
    const t = LobsterKeycap.tokens(this.primary ? KeycapStyle.PRIMARY : KeycapStyle.SECONDARY)
    return [[t.gradientTop, 0], [t.gradientBottom, 1]]
  }

  private textColor(): number {
    if (this.textColorOverride !== 0) {
      return this.textColorOverride
    }
    return this.primary ? LobsterWaterColors.TEXT_ON_ACCENT : LobsterWaterColors.ACCENT_DEEP
  }

  build() {
    Text(this.label)
      .fontSize(this.fontSizeFp)
      .fontWeight(this.bold ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.textColor())
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .height(this.heightVp)
      .width(this.stretch ? '100%' : 'auto')
      .padding({ left: 12, right: 12 })
      .linearGradient({ angle: 180, colors: this.gradColors() })
      .borderRadius(this.radiusVp)
      .border({
        width: this.primary ? 0 : 1,
        color: LobsterWaterColors.BORDER
      })
      .shadow({
        radius: 1,
        color: this.primary ? LobsterWaterColors.ENTER_SHADOW : LobsterWaterColors.KEY_SHADOW,
        offsetX: 0,
        offsetY: LobsterKeyboardMetrics.KEYCAP_SHADOW_DP
      })
      .stateStyles({
        pressed: this.pressedStyle,
        normal: this.normalStyle
      })
      .onClick(() => {
        this.onTap()
      })
  }
}
