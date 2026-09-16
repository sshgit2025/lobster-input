// 对应安卓 ui/theme/Color.kt + Theme.kt + Type.kt + LobsterWaterColors.kt(主应用侧色板/字体/形状令牌)
// 色值基于安卓源码移植,鸿蒙侧按 UX 自检对比度要求保留必要覆盖。

/** Material 色板结构:与 Compose ColorScheme 字段一一对应(仅保留主应用用到的字段)。 */
export class AppColorScheme {
  primary: string = '#0A84C4'
  onPrimary: string = '#FFFFFF'
  primaryContainer: string = '#CDEEFB'
  onPrimaryContainer: string = '#073A56'
  secondary: string = '#2BA7E0'
  onSecondary: string = '#FFFFFF'
  secondaryContainer: string = '#D7EFFB'
  onSecondaryContainer: string = '#073A56'
  tertiary: string = '#06B6D4'
  onTertiary: string = '#FFFFFF'
  tertiaryContainer: string = '#CFF4FB'
  onTertiaryContainer: string = '#053B45'
  error: string = '#E5484D'
  onError: string = '#FFFFFF'
  errorContainer: string = '#FDE2E2'
  onErrorContainer: string = '#5A1216'
  background: string = '#F4FAFE'
  onBackground: string = '#0B3A52'
  surface: string = '#FFFFFF'
  onSurface: string = '#0B3A52'
  surfaceVariant: string = '#ECF5FB'
  onSurfaceVariant: string = '#466C82'
  outline: string = '#DCEBF4'
  outlineVariant: string = '#E6F1F8'
  // 半透明衍生色(Compose 里 copy(alpha) 的等价预生成,避免页面散落计算)
  outlineAlpha50: string = '#80DCEBF4'
  errorAlpha50: string = '#80E5484D'
}

/** Dark — 同色相深海蓝(Color.kt md_theme_dark_*) */
function buildDarkScheme(): AppColorScheme {
  const s = new AppColorScheme()
  s.primary = '#5FC4F0'
  s.onPrimary = '#052E45'
  s.primaryContainer = '#0E4665'
  s.onPrimaryContainer = '#CDEEFB'
  s.secondary = '#8AD3F4'
  s.onSecondary = '#052E45'
  s.secondaryContainer = '#1C3850'
  s.onSecondaryContainer = '#D7EFFB'
  s.tertiary = '#67DDF0'
  s.onTertiary = '#043640'
  s.tertiaryContainer = '#0C4C58'
  s.onTertiaryContainer = '#CFF4FB'
  s.error = '#FFB4AB'
  s.onError = '#5A1216'
  s.errorContainer = '#7A2A2D'
  s.onErrorContainer = '#FDE2E2'
  s.background = '#0A1F2E'
  s.onBackground = '#E6F3FB'
  s.surface = '#10293B'
  s.onSurface = '#E6F3FB'
  s.surfaceVariant = '#1C3850'
  s.onSurfaceVariant = '#9FC2D4'
  s.outline = '#33536A'
  s.outlineVariant = '#274458'
  s.outlineAlpha50 = '#8033536A'
  s.errorAlpha50 = '#80FFB4AB'
  return s
}

/** 主题入口:启动时按系统深浅色调用 setDarkMode,页面统一引用 AppTheme.colors。 */
export class AppTheme {
  static readonly light: AppColorScheme = new AppColorScheme()
  static readonly dark: AppColorScheme = buildDarkScheme()
  /** 当前生效色板(默认浅色;Index 启动时根据系统 colorMode 切换)。 */
  static colors: AppColorScheme = AppTheme.light

  static setDarkMode(dark: boolean): void {
    AppTheme.colors = dark ? AppTheme.dark : AppTheme.light
  }
}

/** 水波品牌渐变(与键盘录音涟漪钮一致,MainScreen.kt LobsterBrandGradient)。 */
export class AppBrand {
  static readonly gradientStart: string = '#2BA7E0'
  static readonly gradientEnd: string = '#0A84C4'
}

/** 形状令牌:Theme.kt LobsterShapes + MainScreen.kt 统一视觉令牌。 */
export class AppShapes {
  static readonly extraSmall: number = 8
  static readonly small: number = 12
  static readonly medium: number = 16
  static readonly large: number = 20
  static readonly extraLarge: number = 28
  // MainScreen 统一视觉令牌
  static readonly card: number = 16      // LobsterCardShape
  static readonly button: number = 12    // LobsterButtonShape
  static readonly field: number = 12     // LobsterFieldShape
  static readonly chip: number = 999     // LobsterChipShape(RoundedCornerShape(50) 胶囊)
  static readonly dialog: number = 20
}

/** 字体令牌结构(Type.kt TextStyle 等价)。 */
export class TypeToken {
  fontSize: number = 14
  lineHeight: number = 20
  fontWeight: FontWeight = FontWeight.Normal
  letterSpacing: number = 0

  constructor(fontSize: number, lineHeight: number, fontWeight: FontWeight, letterSpacing: number) {
    this.fontSize = fontSize
    this.lineHeight = lineHeight
    this.fontWeight = fontWeight
    this.letterSpacing = letterSpacing
  }
}

/** Type.kt Typography 一比一(fp 尺寸,系统默认字体)。 */
export class AppTypography {
  static readonly displayLarge: TypeToken = new TypeToken(57, 64, FontWeight.Normal, -0.25)
  static readonly displayMedium: TypeToken = new TypeToken(45, 52, FontWeight.Normal, 0)
  static readonly displaySmall: TypeToken = new TypeToken(36, 44, FontWeight.Normal, 0)
  static readonly headlineLarge: TypeToken = new TypeToken(30, 38, FontWeight.Medium, -0.25)
  static readonly headlineMedium: TypeToken = new TypeToken(26, 34, FontWeight.Medium, 0)
  static readonly headlineSmall: TypeToken = new TypeToken(24, 32, FontWeight.Medium, 0)
  static readonly titleLarge: TypeToken = new TypeToken(22, 28, FontWeight.Bold, 0)
  static readonly titleMedium: TypeToken = new TypeToken(16, 22, FontWeight.Medium, 0.1)
  static readonly titleSmall: TypeToken = new TypeToken(14, 20, FontWeight.Medium, 0.1)
  static readonly bodyLarge: TypeToken = new TypeToken(16, 24, FontWeight.Normal, 0.15)
  static readonly bodyMedium: TypeToken = new TypeToken(14, 20, FontWeight.Normal, 0.25)
  static readonly bodySmall: TypeToken = new TypeToken(12, 16, FontWeight.Normal, 0.4)
  static readonly labelLarge: TypeToken = new TypeToken(14, 20, FontWeight.Medium, 0.1)
  static readonly labelMedium: TypeToken = new TypeToken(12, 16, FontWeight.Medium, 0.5)
  static readonly labelSmall: TypeToken = new TypeToken(11, 16, FontWeight.Medium, 0.5)
}

/**
 * 「Sapphire Glass」蓝宝石玻璃质感设计令牌(LobsterWaterColors.kt 主应用侧可引用部分)。
 * 键盘面板自绘 View 请使用 ime 侧同名移植文件;此处供主应用页面引用,色值与安卓完全一致。
 */
export class LobsterWaterColors {
  // ---- 面板背景(纵向渐变:冰面 → 深一阶) ----
  static readonly PANEL_BG_TOP: string = '#F4FAFF'
  static readonly PANEL_BG_BOTTOM: string = '#E2EEF9'
  static readonly PANEL_BG: string = LobsterWaterColors.PANEL_BG_TOP
  // ---- 表面 / 边框 ----
  static readonly PANEL_SURFACE: string = '#FFFFFF'
  static readonly SURFACE_MUTED: string = '#E9F2FA'
  static readonly BORDER: string = '#C9DDEF'
  static readonly SURFACE_GRADIENT_TOP: string = '#FFFFFF'
  static readonly SURFACE_GRADIENT_BOTTOM: string = '#F7FBFF'
  // ---- 蓝宝石 accent 色阶 ----
  static readonly ACCENT_DEEP: string = '#0B4E8F'
  static readonly ACCENT: string = '#1268C0'
  static readonly ACCENT_BRIGHT: string = '#3D93E8'
  static readonly ACCENT_SOFT: string = '#A9CFF2'
  // ---- 玻璃按钮 ----
  static readonly BUTTON_BG: string = '#1A1268C0'
  static readonly BUTTON_BG_STRONG: string = '#2E1268C0'
  static readonly SECONDARY_STROKE: string = '#99A9CFF2'
  static readonly PRESS_RIPPLE_LIGHT: string = '#33FFFFFF'
  static readonly PRESS_RIPPLE_DARK: string = '#261268C0'
  // ---- 文字 ----
  static readonly TEXT_MAIN: string = '#0A2C4E'
  static readonly TEXT_MUTED: string = '#496A82'
  static readonly TEXT_ON_ACCENT: string = '#FFFFFF'
  static readonly ERROR: string = '#E5484D'
  // ---- 徽标 / 遮罩 ----
  static readonly BADGE_ACTIVE_BG: string = '#291268C0'
  static readonly BADGE_INACTIVE_BG: string = '#141268C0'
  static readonly PANEL_SCRIM: string = '#33FFFFFF'
}
