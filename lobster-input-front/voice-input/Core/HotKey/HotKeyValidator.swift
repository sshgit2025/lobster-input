import Foundation
import AppKit
import Carbon
import CoreGraphics

/// 快捷键冲突检测:录制新快捷键时校验「App 内重复 / macOS 系统保留 Fn 组合 / 系统符号热键占用」。
/// reject 级别阻止保存;warn 级别允许保存但提示用户可能失效。
enum HotKeyConflict: Equatable {
    /// 与 App 内另一个功能的快捷键完全相同(阻止保存)
    case duplicate(HotKeyCombo)
    /// macOS 系统保留的 Fn 组合,如 Fn+Q/E/F/A/C/D/H/N/M(阻止保存)
    case systemReserved
    /// 与已启用的系统快捷键(Spotlight ⌘Space、窗口平铺 Fn+Ctrl+方向 等)冲突(仅警告)
    case systemShortcut
}

enum HotKeyValidator {
    /// macOS 系统保留的 Fn+字母(听写/表情/勿扰/快速备忘录等,Sonoma 起,不可自定义):
    /// Q=12 E=14 F=3 A=0 C=8 D=2 H=4 N=45 M=46
    private static let reservedFnLetterKeyCodes: Set<Int> = [12, 14, 3, 0, 8, 2, 4, 45, 46]
    /// Sequoia 窗口平铺占用的 Fn+Ctrl+键:方向键 123-126 及 F=3 C=8 R=15
    private static let reservedFnControlKeyCodes: Set<Int> = [123, 124, 125, 126, 3, 8, 15]

    private static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    static func validate(
        candidate: HotKeyConfig,
        for combo: HotKeyCombo,
        existing: [HotKeyCombo: HotKeyConfig]
    ) -> [HotKeyConflict] {
        var conflicts: [HotKeyConflict] = []
        let candidateModifiers = NSEvent.ModifierFlags(rawValue: UInt(candidate.modifiers)).intersection(relevantModifiers)

        for (otherCombo, other) in existing where otherCombo != combo {
            let otherModifiers = NSEvent.ModifierFlags(rawValue: UInt(other.modifiers)).intersection(relevantModifiers)
            if other.requiresFn == candidate.requiresFn
                && other.keyCode == candidate.keyCode
                && otherModifiers == candidateModifiers {
                conflicts.append(.duplicate(otherCombo))
            }
        }

        if candidate.requiresFn && candidate.keyCode >= 0 {
            if candidateModifiers.isEmpty && reservedFnLetterKeyCodes.contains(candidate.keyCode) {
                conflicts.append(.systemReserved)
            }
            if candidateModifiers == [.control] && reservedFnControlKeyCodes.contains(candidate.keyCode) {
                conflicts.append(.systemShortcut)
            }
        }

        // 非 Fn 组合与系统符号热键(Spotlight、截屏等)比对;Fn 组合不会以相同形态出现在符号热键表
        if !candidate.requiresFn && candidate.keyCode >= 0 {
            let carbonMods = carbonModifierBits(from: candidateModifiers)
            if enabledSymbolicHotkeys().contains(where: { $0.keyCode == candidate.keyCode && $0.carbonModifiers == carbonMods }) {
                conflicts.append(.systemShortcut)
            }
        }

        return conflicts
    }

    private struct SymbolicHotkey {
        let keyCode: Int
        let carbonModifiers: Int
    }

    /// 枚举系统已启用的符号热键(CopySymbolicHotKeys),失败时返回空(不阻塞用户)
    private static func enabledSymbolicHotkeys() -> [SymbolicHotkey] {
        var arrRef: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&arrRef) == noErr,
              let list = arrRef?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard (dict["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = dict["kHISymbolicHotKeyCode"] as? Int else { return nil }
            let mods = (dict["kHISymbolicHotKeyModifiers"] as? Int) ?? 0
            return SymbolicHotkey(keyCode: code, carbonModifiers: mods)
        }
    }

    private static func carbonModifierBits(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        return result
    }
}
