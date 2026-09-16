import Foundation

/// Hangul 2-set(두벌식)组字自动机(与 scratch-keyboard-verify/hangul_composer.py 参照实现逐行对齐,镜像安卓)。
/// Unicode:音节 = 0xAC00 + (cho*21 + jung)*28 + jong。
/// 复合中声(ㅗ+ㅏ=ㅘ)、复合终声(ㄹ+ㄱ=ㄺ)、终声借调(닭+이=닭이)、逐 jamo 退格拆解。
final class HangulComposer {

    private var cho: Character?
    private var jung: Character?
    private var jong: Character?

    var isEmpty: Bool { cho == nil && jung == nil && jong == nil }

    /// 当前组合中显示的字符(未定稿,恒 ≤1 字符)。
    func current() -> String {
        if let c = cho, let j = jung {
            let ci = Self.cho.firstIndex(of: c)!
            let ji = Self.jung.firstIndex(of: j)!
            let gi = jong.flatMap { Self.jong.firstIndex(of: $0) } ?? 0
            let scalar = 0xAC00 + (ci * 21 + ji) * 28 + gi
            return String(UnicodeScalar(scalar)!)
        }
        if let c = cho { return String(c) }
        if let j = jung { return String(j) }
        return ""
    }

    func reset() { cho = nil; jung = nil; jong = nil }

    /// 输入一个 compatibility jamo,返回需定稿上屏的文本(可空)。
    func feed(_ jamo: Character) -> String {
        Self.vowels.contains(jamo) ? feedVowel(jamo) : feedConsonant(jamo)
    }

    private func feedConsonant(_ c: Character) -> String {
        if cho == nil && jung == nil { cho = c; return "" }
        if jung == nil {
            // 只有 cho:辅音+辅音 → 前一个定稿,新辅音开始(双辅音走 shift,不自动合并)
            let out = String(cho!)
            reset(); cho = c
            return out
        }
        if jong == nil {
            // 【修 孤元音丢辅音】终声必须挂在完整 cho+jung 音节上;孤元音(cho=nil)挂终声后
            // current() 渲染不出、辅音被静默吞掉(ㅏ+ㄱ 曾丢 ㄱ)。标准行为:孤元音定稿,辅音另起。
            if cho != nil && Self.jongSet.contains(c) { jong = c; return "" }
            // 孤元音 / ㄸㅃㅉ 不能作终声:定稿当前,新起
            let out = current()
            reset(); cho = c
            return out
        }
        if let comb = Self.jongCombine[Pair(jong!, c)] { jong = comb; return "" }
        let out = current()
        reset(); cho = c
        return out
    }

    private func feedVowel(_ v: Character) -> String {
        if let g = jong {
            // 终声借调:复合终声拆最后一个辅音做新 cho,单终声整个移走
            if let split = Self.jongSplit[g] {
                jong = split.0
                let out = current()
                reset(); cho = split.1; jung = v
                return out
            }
            jong = nil
            let out = current()
            reset(); cho = g; jung = v
            return out
        }
        if let j = jung {
            if let comb = Self.jungCombine[Pair(j, v)] { jung = comb; return "" }
            let out = current()
            reset(); jung = v
            return out
        }
        if cho != nil { jung = v; return "" }
        jung = v
        return ""
    }

    /// 组合态内逐 jamo 拆解;返回 false 表示无组合态(需删文档字符)。
    func backspace() -> Bool {
        if let g = jong {
            jong = Self.jongSplit[g]?.0
            return true
        }
        if let j = jung {
            jung = Self.jungSplit[j]?.0
            return true
        }
        if cho != nil { cho = nil; return true }
        return false
    }

    // MARK: - 静态表

    private struct Pair: Hashable {
        let a: Character; let b: Character
        init(_ a: Character, _ b: Character) { self.a = a; self.b = b }
    }

    private static let cho = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private static let jung = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    // jong[0] 为占位(无终声);firstIndex 用于 Unicode 组装
    private static let jong: [Character] = [" ", "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
    private static let jongSet = Set(jong.dropFirst())
    private static let vowels = Set(jung)

    private static let jungCombine: [Pair: Character] = [
        Pair("ㅗ", "ㅏ"): "ㅘ", Pair("ㅗ", "ㅐ"): "ㅙ", Pair("ㅗ", "ㅣ"): "ㅚ",
        Pair("ㅜ", "ㅓ"): "ㅝ", Pair("ㅜ", "ㅔ"): "ㅞ", Pair("ㅜ", "ㅣ"): "ㅟ",
        Pair("ㅡ", "ㅣ"): "ㅢ"
    ]
    private static let jongCombine: [Pair: Character] = [
        Pair("ㄱ", "ㅅ"): "ㄳ", Pair("ㄴ", "ㅈ"): "ㄵ", Pair("ㄴ", "ㅎ"): "ㄶ",
        Pair("ㄹ", "ㄱ"): "ㄺ", Pair("ㄹ", "ㅁ"): "ㄻ", Pair("ㄹ", "ㅂ"): "ㄼ", Pair("ㄹ", "ㅅ"): "ㄽ",
        Pair("ㄹ", "ㅌ"): "ㄾ", Pair("ㄹ", "ㅍ"): "ㄿ", Pair("ㄹ", "ㅎ"): "ㅀ",
        Pair("ㅂ", "ㅅ"): "ㅄ"
    ]
    private static let jungSplit: [Character: (Character, Character)] =
        Dictionary(uniqueKeysWithValues: jungCombine.map { ($0.value, ($0.key.a, $0.key.b)) })
    private static let jongSplit: [Character: (Character, Character)] =
        Dictionary(uniqueKeysWithValues: jongCombine.map { ($0.value, ($0.key.a, $0.key.b)) })
}
