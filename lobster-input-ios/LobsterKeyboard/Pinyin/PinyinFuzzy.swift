import Foundation

/// 模糊音 + 容错纠错(引擎层无状态工具)。与安卓 PinyinFuzzy.kt 对齐。
/// 模糊音:把合法音节派生出等价音节集合(平翘舌/前后鼻音/边鼻音…),按开关启用。
/// 纠错:对单个音节做编辑距离≤1(替换/插入/删除/邻键)还原成合法音节,仅在精确/模糊不足时兜底。
enum PinyinFuzzy {

    struct Settings {
        var zZh = false; var cCh = false; var sSh = false
        var lN = false; var fH = false; var rL = false
        var anAng = false; var enEng = false; var inIng = false
        var correction = false

        var anyInitial: Bool { zZh || cCh || sSh || lN || fH || rL }
        var anyFinal: Bool { anAng || enEng || inIng }
        var anyFuzzy: Bool { anyInitial || anyFinal }
    }

    private static let neighbors: [Character: String] = [
        "q": "wa", "w": "qes", "e": "wrd", "r": "etf", "t": "ryg",
        "y": "tuh", "u": "yij", "i": "uok", "o": "ipl", "p": "ol",
        "a": "qsz", "s": "awdzx", "d": "serfcx", "f": "drtgvc",
        "g": "ftyhbv", "h": "gyujnb", "j": "huikmn", "k": "jiolm",
        "l": "kop", "z": "asx", "x": "zsdc", "c": "xdfv",
        "v": "cfgb", "b": "vghn", "n": "bhjm", "m": "njk"
    ]

    /// 把一个合法音节派生出模糊等价音节集合(含自身)。调用方需对模糊命中降权。
    static func variants(_ syllable: String, _ s: Settings) -> [String] {
        if !s.anyFuzzy || syllable.isEmpty { return [syllable] }
        var set: [String] = [syllable]
        var seen: Set<String> = [syllable]
        func add(_ v: String) { if seen.insert(v).inserted { set.append(v) } }

        if s.anyInitial {
            for v in set {
                if s.zZh { if v.hasPrefix("zh") { add("z" + v.dropFirst(2)) } else if v.hasPrefix("z") { add("zh" + v.dropFirst(1)) } }
                if s.cCh { if v.hasPrefix("ch") { add("c" + v.dropFirst(2)) } else if v.hasPrefix("c") { add("ch" + v.dropFirst(1)) } }
                if s.sSh { if v.hasPrefix("sh") { add("s" + v.dropFirst(2)) } else if v.hasPrefix("s") { add("sh" + v.dropFirst(1)) } }
                if s.lN { if v.hasPrefix("l") { add("n" + v.dropFirst(1)) } else if v.hasPrefix("n") { add("l" + v.dropFirst(1)) } }
                if s.fH { if v.hasPrefix("f") { add("h" + v.dropFirst(1)) } else if v.hasPrefix("h") { add("f" + v.dropFirst(1)) } }
                if s.rL { if v.hasPrefix("r") { add("l" + v.dropFirst(1)) } else if v.hasPrefix("l") { add("r" + v.dropFirst(1)) } }
            }
        }
        if s.anyFinal {
            for v in set {
                if s.anAng { if v.hasSuffix("ang") { add(String(v.dropLast(3)) + "an") } else if v.hasSuffix("an") { add(String(v.dropLast(2)) + "ang") } }
                if s.enEng { if v.hasSuffix("eng") { add(String(v.dropLast(3)) + "en") } else if v.hasSuffix("en") { add(String(v.dropLast(2)) + "eng") } }
                if s.inIng { if v.hasSuffix("ing") { add(String(v.dropLast(3)) + "in") } else if v.hasSuffix("in") { add(String(v.dropLast(2)) + "ing") } }
            }
        }
        return set
    }

    /// 对一个"非法音节"做编辑距离≤1 纠错,返回可能的合法音节(由 isSyllable 校验)。结果上限 8。
    static func corrections(_ token: String, _ isSyllable: (String) -> Bool) -> [String] {
        let chars = Array(token)
        if chars.count < 2 || chars.count > 6 { return [] }
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) { if isSyllable(s) && seen.insert(s).inserted { out.append(s) } }
        // 删除一个字母
        for i in chars.indices { var c = chars; c.remove(at: i); add(String(c)) }
        // 替换为邻键
        for i in chars.indices {
            for n in (neighbors[chars[i]] ?? "") {
                var c = chars; c[i] = n; add(String(c))
            }
            if out.count >= 8 { return out }
        }
        // 插入一个字母
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for i in 0...chars.count {
            for ch in letters {
                var c = chars; c.insert(ch, at: i); add(String(c))
                if out.count >= 8 { return out }
            }
        }
        return out
    }
}
