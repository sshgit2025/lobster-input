import UIKit
import SwiftUI

/// 「Sapphire Glass 蓝宝石玻璃」主题(与安卓端逐值对齐),主 App 与键盘扩展共用。
/// 设计令牌:纵向渐变面板 + 玻璃填充 + 3D 键帽,统一品牌色阶、文字层级、描边、语义色。
enum LobsterWaterPalette {
    // MARK: - 背景与表面
    /// 全局背景 fallback(面板实际为 panelTop→panelBottom 纵向渐变) #F0F7FD
    static let panel = UIColor(red: 0.941, green: 0.969, blue: 0.992, alpha: 1)
    /// 面板渐变顶部 #F4FAFF
    static let panelTop = UIColor(red: 0.957, green: 0.980, blue: 1.0, alpha: 1)
    /// 面板渐变底部 #E2EEF9
    static let panelBottom = UIColor(red: 0.886, green: 0.933, blue: 0.976, alpha: 1)
    /// 卡片表面(纯白) #FFFFFF
    static let surface = UIColor.white
    /// 次级表面(浅蓝,用于 chip / 次级容器) #E9F2FA
    static let surfaceMuted = UIColor(red: 0.914, green: 0.949, blue: 0.980, alpha: 1)
    /// 柔和描边 / 分割线 #C9DDEF
    static let border = UIColor(red: 0.788, green: 0.867, blue: 0.937, alpha: 1)

    // MARK: - 品牌色阶
    /// 深品牌色(按下 / 深文字) #0B4E8F
    static let accentDeep = UIColor(red: 0.043, green: 0.306, blue: 0.561, alpha: 1)
    /// 主品牌色 #1268C0
    static let accent = UIColor(red: 0.071, green: 0.408, blue: 0.753, alpha: 1)
    /// 亮品牌色(渐变起端 / 高亮) #3D93E8
    static let accentBright = UIColor(red: 0.239, green: 0.576, blue: 0.910, alpha: 1)
    /// 浅强调色(柔和填充 / 玻璃描边) #A9CFF2
    static let accentSoft = UIColor(red: 0.663, green: 0.812, blue: 0.949, alpha: 1)
    /// 浅按钮玻璃填充(accent @ 10%)
    static let button = accent.withAlphaComponent(0.10)
    /// 强按钮玻璃填充(accent @ 18%)
    static let buttonStrong = accent.withAlphaComponent(0.18)

    // MARK: - 文字层级
    /// 主文字 #0A2C4E
    static let text = UIColor(red: 0.039, green: 0.173, blue: 0.306, alpha: 1)
    /// 次级文字 #54748F
    static let muted = UIColor(red: 0.329, green: 0.455, blue: 0.561, alpha: 1)
    /// 三级文字 / 占位 #8AA6BF
    static let tertiary = UIColor(red: 0.541, green: 0.651, blue: 0.749, alpha: 1)

    // MARK: - 语义色
    /// 错误 #E5484D
    static let danger = UIColor(red: 0.898, green: 0.282, blue: 0.302, alpha: 1)
    /// 成功 #1FA971
    static let success = UIColor(red: 0.122, green: 0.663, blue: 0.443, alpha: 1)

    // MARK: - 录音涟漪钮渐变
    /// 录音按钮顶部 #BFE0F8
    static let orbTop = UIColor(red: 0.749, green: 0.878, blue: 0.973, alpha: 1)
    /// 录音按钮底部 #2E7CC9
    static let orbBottom = UIColor(red: 0.180, green: 0.486, blue: 0.788, alpha: 1)

    // MARK: - 3D 键帽(打字键盘)
    /// 字母键帽渐变顶部 #FFFFFF
    static let keyTop = UIColor.white
    /// 字母键帽渐变底部 #EFF6FC
    static let keyBottom = UIColor(red: 0.937, green: 0.965, blue: 0.988, alpha: 1)
    /// 字母键帽按压渐变顶部 #D9EAF8
    static let keyPressTop = UIColor(red: 0.851, green: 0.918, blue: 0.973, alpha: 1)
    /// 字母键帽按压渐变底部 #CBE1F3
    static let keyPressBottom = UIColor(red: 0.796, green: 0.882, blue: 0.953, alpha: 1)
    /// 功能键帽渐变顶部 #E7F1FA
    static let funcTop = UIColor(red: 0.906, green: 0.945, blue: 0.980, alpha: 1)
    /// 功能键帽渐变底部 #D7E7F5
    static let funcBottom = UIColor(red: 0.843, green: 0.906, blue: 0.961, alpha: 1)
    /// 功能键帽按压渐变顶部 #C9DEF0
    static let funcPressTop = UIColor(red: 0.788, green: 0.871, blue: 0.941, alpha: 1)
    /// 功能键帽按压渐变底部 #BFD7EC
    static let funcPressBottom = UIColor(red: 0.749, green: 0.843, blue: 0.925, alpha: 1)
    /// 键帽底缘 3D 投影 #2C4A66 @ 25%
    static let keyShadow = UIColor(red: 0.173, green: 0.290, blue: 0.400, alpha: 0.25)
    /// 回车键渐变顶部 #4D9DEC
    static let enterTop = UIColor(red: 0.302, green: 0.616, blue: 0.925, alpha: 1)
    /// 回车键渐变底部 #1268C0(= accent)
    static let enterBottom = UIColor(red: 0.071, green: 0.408, blue: 0.753, alpha: 1)

    // MARK: - SwiftUI Color 版本
    static var panelColor: Color { Color(uiColor: panel) }
    static var panelTopColor: Color { Color(uiColor: panelTop) }
    static var panelBottomColor: Color { Color(uiColor: panelBottom) }
    static var surfaceColor: Color { Color(uiColor: surface) }
    static var surfaceMutedColor: Color { Color(uiColor: surfaceMuted) }
    static var borderColor: Color { Color(uiColor: border) }
    static var accentDeepColor: Color { Color(uiColor: accentDeep) }
    static var accentColor: Color { Color(uiColor: accent) }
    static var accentBrightColor: Color { Color(uiColor: accentBright) }
    static var accentSoftColor: Color { Color(uiColor: accentSoft) }
    static var textColor: Color { Color(uiColor: text) }
    static var mutedColor: Color { Color(uiColor: muted) }
    static var tertiaryColor: Color { Color(uiColor: tertiary) }
    static var dangerColor: Color { Color(uiColor: danger) }
    static var successColor: Color { Color(uiColor: success) }
    static var orbTopColor: Color { Color(uiColor: orbTop) }
    static var orbBottomColor: Color { Color(uiColor: orbBottom) }
    static var keyTopColor: Color { Color(uiColor: keyTop) }
    static var keyBottomColor: Color { Color(uiColor: keyBottom) }
    static var enterTopColor: Color { Color(uiColor: enterTop) }
    static var enterBottomColor: Color { Color(uiColor: enterBottom) }

    /// 品牌渐变(主按钮 / 强调):accentBright → accent
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentBrightColor, accentColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 面板纵向渐变(SwiftUI 版):panelTop → panelBottom
    static var panelGradient: LinearGradient {
        LinearGradient(
            colors: [panelTopColor, panelBottomColor],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// 键盘扩展统一控件规格(Sapphire Glass):
/// 模式切换主按钮高 32 / 圆角 16 / 字 13 semibold;键帽圆角 8;过场与按压动画参数。
enum KeyboardMetrics {
    /// 模式切换 pill 高度
    static let pillHeight: CGFloat = 32
    /// 模式切换 pill 圆角(胶囊)
    static let pillCornerRadius: CGFloat = 16
    /// 模式切换 pill 字号(semibold)
    static let pillFontSize: CGFloat = 13
    /// 键帽圆角
    static let keyCornerRadius: CGFloat = 8
    /// 顶部工具栏高度(语音 header 44 + 上边距 8 → 按钮顶 Y = 14,
    /// 与打字候选栏 4 + (52-32)/2 = 14 对齐)
    static let toolbarHeight: CGFloat = 44
    /// 矩形键帽按钮圆角(次级功能按钮)
    static let keycapRectCornerRadius: CGFloat = 12
    /// 键帽底缘投影纵向偏移
    static let keycapShadowOffsetY: CGFloat = 1.5
    /// 键帽底缘投影模糊半径
    static let keycapShadowRadius: CGFloat = 1.5
    /// 键帽按压下沉距离
    static let keycapPressSink: CGFloat = 1
    /// 模式切换入场动画时长
    static let modeEnterDuration: TimeInterval = 0.2
    /// 模式切换出场动画时长
    static let modeExitDuration: TimeInterval = 0.14
    /// 子面板(符号/人设)crossDissolve 过渡时长
    static let panelTransitionDuration: TimeInterval = 0.18
    /// 按压反馈缩放
    static let pressScale: CGFloat = 0.96
    /// 按压反馈按下时长(快速,避免拖影)
    static let pressDuration: TimeInterval = 0.08
    /// 入场平移距离(translationY 12 → 0)
    static let modeEnterTranslationY: CGFloat = 12
}

/// 统一度量令牌:圆角、间距、阴影。扁平 + 柔和圆角风格。
enum LobsterMetrics {
    // 圆角
    static let radiusCard: CGFloat = 16
    static let radiusButton: CGFloat = 12
    static let radiusInput: CGFloat = 12
    static let radiusSmall: CGFloat = 8

    // 间距
    static let spacing1: CGFloat = 4
    static let spacing2: CGFloat = 8
    static let spacing3: CGFloat = 12
    static let spacing4: CGFloat = 16
    static let spacing5: CGFloat = 20
    static let spacing6: CGFloat = 24
    static let spacing8: CGFloat = 32

    // 柔和蓝调阴影
    static let shadowColor = Color(.sRGB, red: 0.173, green: 0.290, blue: 0.400, opacity: 0.10)
    static let shadowRadius: CGFloat = 16
    static let shadowY: CGFloat = 6
}

/// 统一卡片样式:白底 + 柔和蓝调阴影 + 细描边 + 柔和圆角(扁平质感)。
struct LobsterCardStyle: ViewModifier {
    var cornerRadius: CGFloat = LobsterMetrics.radiusCard
    var padding: CGFloat = LobsterMetrics.spacing4

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(LobsterWaterPalette.surfaceColor, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LobsterWaterPalette.borderColor, lineWidth: 1)
            )
            .shadow(color: LobsterMetrics.shadowColor, radius: LobsterMetrics.shadowRadius, y: LobsterMetrics.shadowY)
    }
}

extension View {
    /// 应用统一卡片样式。
    func lobsterCard(cornerRadius: CGFloat = LobsterMetrics.radiusCard, padding: CGFloat = LobsterMetrics.spacing4) -> some View {
        modifier(LobsterCardStyle(cornerRadius: cornerRadius, padding: padding))
    }

    /// 统一页面水蓝背景(与键盘面板一致)。List/Form 需配合 `.scrollContentBackground(.hidden)`。
    func lobsterScreenBackground() -> some View {
        background(LobsterWaterPalette.panelColor.ignoresSafeArea())
    }
}

/// 分组小标题:像精致设置 App 那样的区块标签。
struct LobsterSectionHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(LobsterWaterPalette.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }
}

/// 水波渐变品牌 Hero:主界面顶部的标志性卡片。
struct LobsterBrandHero: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LobsterWaterPalette.accentGradient,
            in: RoundedRectangle(cornerRadius: LobsterMetrics.radiusCard, style: .continuous)
        )
        .shadow(color: LobsterWaterPalette.accentColor.opacity(0.28), radius: 16, y: 8)
    }
}
