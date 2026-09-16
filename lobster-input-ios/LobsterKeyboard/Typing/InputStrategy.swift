import Foundation

/// 输入策略(策略模式)。封装"按字母键如何变成文本/候选"的差异(中/英/俄/韩 × 26/9)。
protocol TypingInputStrategy: AnyObject {
    /// 字母键:26 键传字母,9 宫格传数字字符串,韩语传 jamo。
    func onAlpha(_ value: String)
    /// 基于当前组合串产出候选(英文/俄语/韩语策略返回空)。
    func candidates() -> [PinyinCandidate]
    /// 候选栏组合显示(英文/俄语/韩语策略返回空串)。
    func composingDisplay() -> String
    /// 切换到本策略时复位内部状态。
    func reset()
    /// 删除键:返回 true 表示已在策略内部消化(韩语组字逐 jamo 拆解),false 走默认删除。
    func onDelete() -> Bool
    /// 输入中断点(空格/回车/标点/切页/切语言):定稿策略内部组合态(韩语当前音节)。
    func flush()
}

extension TypingInputStrategy {
    func reset() {}
    func onDelete() -> Bool { false }
    func flush() {}
}

/// 策略运行上下文(由 Controller 实现)。
protocol StrategyContext: AnyObject {
    var composing: String { get set }
    var engine: PinyinEngine { get }
    var shiftActive: Bool { get }
    func commit(_ text: String)
    func deleteBeforeCursor()
    func refreshCandidates()
    func consumeShift()
    /// 组合预览写入目标框(韩语组字音节,setMarkedText 通道;拼音不走此通道)。
    func composingText(_ text: String)
    /// 定稿目标框中的组合预览。
    func finishComposing()
}

/// 中文 · 26 键全拼。
final class ChineseQwertyStrategy: TypingInputStrategy {
    private unowned let ctx: StrategyContext
    init(_ ctx: StrategyContext) { self.ctx = ctx }
    func onAlpha(_ value: String) { ctx.composing += value.lowercased(); ctx.refreshCandidates() }
    func candidates() -> [PinyinCandidate] { ctx.engine.candidates(ctx.composing) }
    func composingDisplay() -> String { ctx.composing.isEmpty ? "" : ctx.engine.displaySegmented(ctx.composing) }
}

/// 中文 · 9 宫格 T9。组合区不显示数字串(业界做法),候选栏只出汉字候选。
final class ChineseT9Strategy: TypingInputStrategy {
    private unowned let ctx: StrategyContext
    init(_ ctx: StrategyContext) { self.ctx = ctx }
    func onAlpha(_ value: String) { ctx.composing += value; ctx.refreshCandidates() }
    func candidates() -> [PinyinCandidate] { ctx.engine.candidatesForT9(ctx.composing) }
    func composingDisplay() -> String { "" }
}

/// 英文 · 26 键直接上屏。
final class EnglishQwertyStrategy: TypingInputStrategy {
    private unowned let ctx: StrategyContext
    init(_ ctx: StrategyContext) { self.ctx = ctx }
    func onAlpha(_ value: String) {
        ctx.commit(ctx.shiftActive ? value.uppercased() : value.lowercased())
        ctx.consumeShift()
    }
    func candidates() -> [PinyinCandidate] { [] }
    func composingDisplay() -> String { "" }
}

/// 俄语 · ЙЦУКЕН 直接上屏(西里尔字母大小写随 shift;ё 由 е 长按提供,布局层配置)。
final class RussianStrategy: TypingInputStrategy {
    private unowned let ctx: StrategyContext
    init(_ ctx: StrategyContext) { self.ctx = ctx }
    func onAlpha(_ value: String) {
        ctx.commit(ctx.shiftActive ? value.uppercased() : value.lowercased())
        ctx.consumeShift()
    }
    func candidates() -> [PinyinCandidate] { [] }
    func composingDisplay() -> String { "" }
}

/// 韩语 · 2-set(두벌식)组字上屏。jamo 经 [HangulComposer] 组字:
/// 定稿部分 commit,组合中音节走 setMarkedText 预览(业界标准);
/// 删除键优先在组合内逐 jamo 拆解;空格/回车/标点/切页先 flush 定稿。
final class KoreanStrategy: TypingInputStrategy {
    private unowned let ctx: StrategyContext
    private let composer = HangulComposer()
    init(_ ctx: StrategyContext) { self.ctx = ctx }

    func onAlpha(_ value: String) {
        guard let jamo = value.first else { return }
        let committed = composer.feed(jamo)
        // commit(insertText)会替换 marked 区并定稿(标准语义)
        if !committed.isEmpty { ctx.commit(committed) }
        syncPreview()
        ctx.consumeShift()
    }

    func onDelete() -> Bool {
        if composer.isEmpty { return false }
        _ = composer.backspace()
        syncPreview()
        return true
    }

    func flush() {
        if composer.isEmpty { return }
        // 组合预览已显示当前音节,finishComposing 直接把它定稿进文档
        composer.reset()
        ctx.finishComposing()
    }

    func reset() { composer.reset() }
    func candidates() -> [PinyinCandidate] { [] }
    func composingDisplay() -> String { "" }

    private func syncPreview() {
        let cur = composer.current()
        if cur.isEmpty { ctx.composingText(""); ctx.finishComposing() } else { ctx.composingText(cur) }
    }
}

// 英文 T9 多击策略已废弃(业界共识:九宫格中文切英文直接变 26 键英文),
// 英文模式一律使用 EnglishQwertyStrategy(见 KeyboardController.pickStrategy)。
