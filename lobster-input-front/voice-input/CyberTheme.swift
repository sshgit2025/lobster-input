/// CyberTheme.swift
/// 沙棕极简视觉系统：低对比卡片、柔和边框、浅深双主题。
import SwiftUI
import Combine

// MARK: - Font Helpers

enum CyberFont {
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func heading(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat) -> Font { .system(size: size, weight: .regular) }
    static func label(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

// MARK: - Theme Store

enum AppThemeMode: String, CaseIterable, Identifiable {
    case sandLight
    case sandDark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .sandLight: return L10n.themeLight
        case .sandDark: return L10n.themeDark
        }
    }
    var icon: String {
        switch self {
        case .sandLight: return "sun.max"
        case .sandDark: return "moon"
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case sand, mono, blue, orange, red, green, purple

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    func color(for mode: AppThemeMode) -> Color {
        switch (mode, self) {
        case (.sandLight, .mono): return Color(hex: 0x18181B)
        case (.sandLight, .sand): return Color(hex: 0x9C7D5B)
        case (.sandLight, .blue): return Color(hex: 0x2563EB)
        case (.sandLight, .orange): return Color(hex: 0xEA580C)
        case (.sandLight, .red): return Color(hex: 0xDC2626)
        case (.sandLight, .green): return Color(hex: 0x15803D)
        case (.sandLight, .purple): return Color(hex: 0x7C3AED)
        case (.sandDark, .mono): return Color(hex: 0xFAFAFA)
        case (.sandDark, .sand): return Color(hex: 0xD4BA94)
        case (.sandDark, .blue): return Color(hex: 0x3B82F6)
        case (.sandDark, .orange): return Color(hex: 0xFB923C)
        case (.sandDark, .red): return Color(hex: 0xF87171)
        case (.sandDark, .green): return Color(hex: 0x4ADE80)
        case (.sandDark, .purple): return Color(hex: 0xA78BFA)
        }
    }
}

struct ThemePalette {
    let bg: Color
    let elevated: Color
    let sunken: Color
    let hover: Color
    let active: Color
    let line: Color
    let lineStrong: Color
    let fg: Color
    let muted: Color
    let subtle: Color
    let faint: Color
    let accent: Color
    let accentSoft: Color
    let accentRing: Color
    let accentForeground: Color
    let success: Color
    let warning: Color
    let danger: Color
    let info: Color
}

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let modeStorageKey = "app_theme_mode"
    private static let accentStorageKey = "app_accent"

    @Published var mode: AppThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeStorageKey) }
    }
    @Published var accent: AppAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Self.accentStorageKey) }
    }

    var palette: ThemePalette {
        let accentColor = accent.color(for: mode)
        switch mode {
        case .sandLight:
            return ThemePalette(
                bg: Color(red: 0.957, green: 0.937, blue: 0.906),
                elevated: Color(red: 0.984, green: 0.973, blue: 0.949),
                sunken: Color(red: 0.925, green: 0.898, blue: 0.847),
                hover: Color(red: 0.36, green: 0.27, blue: 0.16).opacity(0.05),
                active: Color(red: 0.36, green: 0.27, blue: 0.16).opacity(0.08),
                line: Color(red: 0.36, green: 0.27, blue: 0.16).opacity(0.10),
                lineStrong: Color(red: 0.36, green: 0.27, blue: 0.16).opacity(0.18),
                fg: Color(red: 0.173, green: 0.149, blue: 0.125),
                muted: Color(red: 0.420, green: 0.373, blue: 0.314),
                subtle: Color(red: 0.659, green: 0.612, blue: 0.529),
                faint: Color(red: 0.847, green: 0.812, blue: 0.745),
                accent: accentColor,
                accentSoft: accentColor.opacity(accent == .mono ? 0.06 : 0.10),
                accentRing: accentColor.opacity(accent == .mono ? 0.18 : 0.22),
                accentForeground: .white,
                success: Color(red: 0.086, green: 0.639, blue: 0.290),
                warning: Color(red: 0.851, green: 0.467, blue: 0.024),
                danger: Color(red: 0.863, green: 0.149, blue: 0.149),
                info: Color(red: 0.145, green: 0.388, blue: 0.922)
            )
        case .sandDark:
            return ThemePalette(
                bg: Color(hex: 0x14110D),
                elevated: Color(hex: 0x1C1814),
                sunken: Color(hex: 0x100D0A),
                hover: Color(hex: 0xD4BA94).opacity(0.06),
                active: Color(hex: 0xD4BA94).opacity(0.10),
                line: Color(hex: 0xD4BA94).opacity(0.08),
                lineStrong: Color(hex: 0xD4BA94).opacity(0.16),
                fg: Color(hex: 0xF1EBE0),
                muted: Color(hex: 0xA89C87),
                subtle: Color(hex: 0x786C58),
                faint: Color(hex: 0x3D3528),
                accent: accentColor,
                accentSoft: accentColor.opacity(accent == .mono ? 0.08 : 0.14),
                accentRing: accentColor.opacity(accent == .mono ? 0.20 : 0.30),
                accentForeground: Color(hex: accent == .sand ? 0x1A140D : 0x0E0E10),
                success: Color(red: 0.133, green: 0.773, blue: 0.369),
                warning: Color(red: 0.961, green: 0.620, blue: 0.043),
                danger: Color(red: 0.937, green: 0.267, blue: 0.267),
                info: Color(red: 0.231, green: 0.510, blue: 0.965)
            )
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.modeStorageKey)
        mode = AppThemeMode(rawValue: stored ?? "") ?? .sandLight
        let storedAccent = UserDefaults.standard.string(forKey: Self.accentStorageKey)
        accent = AppAccent(rawValue: storedAccent ?? "") ?? .sand
    }

    func toggle() {
        mode = mode == .sandLight ? .sandDark : .sandLight
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Colors

enum Cyber {
    private static var p: ThemePalette { ThemeStore.shared.palette }

    static var bgTop: Color { p.bg }
    static var bgBot: Color { p.bg }
    static var panelBg: Color { p.elevated }
    static var cardBg: Color { p.elevated }
    static var sidebarBg: Color { p.sunken }

    static var textBright: Color { p.fg }
    static var textDim: Color { p.muted }
    static var textGhost: Color { p.subtle }

    static var borderDim: Color { p.line }
    static var dividerCol: Color { p.line }
    static var lineStrong: Color { p.lineStrong }

    static var hoverBg: Color { p.hover }
    static var activeBg: Color { p.active }
    static var faint: Color { p.faint }

    static var accent: Color { p.accent }
    static var accentSoft: Color { p.accentSoft }
    static var accentRing: Color { p.accentRing }
    static var accentForeground: Color { p.accentForeground }

    static var success: Color { p.success }
    static var warning: Color { p.warning }
    static var danger: Color { p.danger }
    static var info: Color { p.info }
}

// MARK: - Layout

enum CyberLayout {
    static let windowW: CGFloat = 1080
    static let windowH: CGFloat = 720
    static let contentMaxW: CGFloat = 1180
    static let readingMaxW: CGFloat = 980
    static let sidebarW: CGFloat = 220
    static let overlayW: CGFloat = 172
    static let overlayH: CGFloat = 46
    static let resultOverlayW: CGFloat = 460
    static let resultOverlayMaxH: CGFloat = 240
    static let resultOverlayMinH: CGFloat = 80
    static let searchOverlayW: CGFloat = 680
    static let searchOverlayMaxH: CGFloat = 600
    static let searchOverlayMinH: CGFloat = 200
    static let authW: CGFloat = 520
    static let permW: CGFloat = 520
    static let permH: CGFloat = 560
    static let sheetW: CGFloat = 480
    static let corner: CGFloat = 12
    static let cornerSm: CGFloat = 8
    static let padH: CGFloat = 32
    static let padV: CGFloat = 24
}

// MARK: - Card Style

struct NeonCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: CyberLayout.corner)
                    .fill(Cyber.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CyberLayout.corner)
                    .stroke(Cyber.borderDim, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 12, y: 4)
    }
}

extension View {
    func neonCard(_ color: Color = Cyber.borderDim, glow: CGFloat = 0) -> some View {
        modifier(NeonCardStyle())
    }
    func cyberCard(glow: Color = Cyber.borderDim) -> some View {
        modifier(NeonCardStyle())
    }
}

// MARK: - Button Styles

struct NeonButtonStyle: ButtonStyle {
    var color: Color = Cyber.accent
    var isPrimary: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(
                isEnabled
                    ? (configuration.isPressed ? color.opacity(0.72) : color)
                    : Cyber.textGhost
            )
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                    .fill(configuration.isPressed ? Cyber.activeBg : Cyber.panelBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                    .stroke(isEnabled ? Cyber.borderDim : Cyber.borderDim.opacity(0.55), lineWidth: 1)
            )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? Cyber.accentForeground : Cyber.accentForeground.opacity(0.5))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                    .fill(isEnabled ? (configuration.isPressed ? Cyber.accent.opacity(0.85) : Cyber.accent) : Cyber.accent.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                    .stroke(isEnabled ? Cyber.accent : Cyber.accent.opacity(0.4), lineWidth: 1)
            )
    }
}

typealias CyberButtonStyle = NeonButtonStyle

// MARK: - TextField Style

struct CyberTextFieldStyle: TextFieldStyle {
    var accent: Color = Cyber.accent
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(CyberFont.body(14))
            .foregroundStyle(Cyber.textBright)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                    .fill(Cyber.panelBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                    .stroke(Cyber.borderDim, lineWidth: 1)
            )
    }
}

// MARK: - Divider

struct CyberDivider: View {
    var color: Color = Cyber.dividerCol
    var body: some View {
        Rectangle()
            .fill(Cyber.dividerCol)
            .frame(height: 1)
    }
}

// MARK: - Badge & Tags

struct CountBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Cyber.textGhost)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Cyber.sidebarBg, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Cyber.borderDim, lineWidth: 1))
    }
}

struct KbdTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Cyber.textDim)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Cyber.borderDim, lineWidth: 1)
            )
    }
}

// MARK: - Section Title

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Cyber.textGhost)
            .tracking(0.8)
    }
}

// MARK: - Status Dot

struct StatusDot: View {
    enum DotStyle { case success, muted, accent }
    let style: DotStyle
    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
            .overlay {
                if style != .muted {
                    Circle().stroke(dotColor.opacity(0.18), lineWidth: 3).scaleEffect(1.7)
                }
            }
    }
    private var dotColor: Color {
        switch style {
        case .success: return Cyber.success
        case .muted: return Cyber.textGhost
        case .accent: return Cyber.accent
        }
    }
}
