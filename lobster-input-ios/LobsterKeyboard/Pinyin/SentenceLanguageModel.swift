import Foundation

/// 整句语言模型(2026-07,九宫格智能整句核心):词级 bigram(主)+ 字级 bigram OOV veto(兜底)。
///
/// 修"打对拼音却出弱智句"(因为你搬过来→因为你包裹来):原整句 DP 只按词频打分,无上下文语言模型。
/// 给整句 DP 的**跨词边界**打分:词 bigram 命中→中心化 delta(奖励好搭配),未命中→字级 OOV veto(仅罚)。
/// 参数与 tools/keyboard-verify/engine_lm.py 逐一对齐(全量回归电池 13/13 验证)。
///
/// 存储照抄 CustomDictionary/ByteTable:Data(.mappedIfSafe) 内存映射 + 行偏移索引 + 字节二分。
/// 数据文件行按 key 排序(生成期 sorted),可直接二分。命中行才转 String 解析权重(内存友好)。
final class SentenceLanguageModel {

    private struct Table {
        var bytes: Data = Data()
        var lineStart: [UInt32] = []
        var keyLen: [UInt16] = []
        var lineEnd: [UInt32] = []
        var ready = false
    }

    private var wordT = Table()
    private var charT = Table()
    private(set) var isReady = false

    func load() {
        charT = parse(resource: "char_bigram")
        wordT = parse(resource: "word_bigram")
        isReady = charT.ready || wordT.ready
    }

    private func parse(resource: String) -> Table {
        var t = Table()
        guard let url = Bundle(for: SentenceLanguageModel.self).url(forResource: resource, withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return t }
        var starts: [UInt32] = []; var klens: [UInt16] = []; var ends: [UInt32] = []
        let NL: UInt8 = 0x0A, TAB: UInt8 = 0x09
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let n = buf.count
            var i = 0
            while i < n {
                let start = i
                var tab = -1
                var j = i
                while j < n && buf[j] != NL {
                    if buf[j] == TAB && tab < 0 { tab = j }
                    j += 1
                }
                if tab > start {
                    starts.append(UInt32(start)); klens.append(UInt16(tab - start)); ends.append(UInt32(j))
                }
                i = j + 1
            }
        }
        t.bytes = data; t.lineStart = starts; t.keyLen = klens; t.lineEnd = ends; t.ready = !starts.isEmpty
        return t
    }

    // MARK: 字节二分定位 key 行

    private func compareKey(_ t: Table, _ index: Int, _ q: [UInt8]) -> Int {
        let s = Int(t.lineStart[index]); let len = Int(t.keyLen[index])
        let m = min(len, q.count)
        var k = 0
        while k < m {
            let a = t.bytes[s + k], b = q[k]
            if a != b { return a < b ? -1 : 1 }
            k += 1
        }
        if len == q.count { return 0 }
        return len < q.count ? -1 : 1
    }

    /// 返回 key 精确命中的行号;无则 -1。
    private func findLine(_ t: Table, _ key: String) -> Int {
        if !t.ready { return -1 }
        let q = Array(key.utf8)
        var lo = 0, hi = t.lineStart.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if compareKey(t, mid, q) < 0 { lo = mid + 1 } else { hi = mid }
        }
        if lo < t.lineStart.count && compareKey(t, lo, q) == 0 { return lo }
        return -1
    }

    /// 行内查 key2 的权重(行体 `k2 w2 k3 w3 ...`)。命中返回权重,否则 nil。
    private func weightIn(_ t: Table, _ line: Int, _ target: String) -> Int? {
        let s = Int(t.lineStart[line]) + Int(t.keyLen[line]) + 1
        let e = Int(t.lineEnd[line])
        guard s < e else { return nil }
        let parts = String(decoding: t.bytes[s ..< e], as: UTF8.self).split(separator: " ")
        var i = 0
        while i + 1 < parts.count {
            if parts[i] == target { return Int(parts[i + 1]) }
            i += 2
        }
        return nil
    }

    // MARK: 打分(与 engine_lm.py 逐一对齐)

    /// 跨词边界打分:词 bigram 命中→中心化 delta;未命中→字级 OOV veto。整句 DP 每次词转移调用一次。
    func boundaryScore(_ pw: String, _ w: String) -> Int {
        if !isReady || pw.isEmpty || w.isEmpty { return 0 }
        if let wd = wordDelta(pw, w) { return wd }
        return charVeto(String(pw.last!), String(w.first!))
    }

    private func wordDelta(_ pw: String, _ w: String) -> Int? {
        let line = findLine(wordT, pw)
        if line < 0 { return nil }
        guard let b = weightIn(wordT, line, w) else { return nil }
        let x = Int(Double(b - Self.WREF) * Self.WBETA)
        if x > Self.WHI { return Self.WHI }
        if x < -Self.WLO { return -Self.WLO }
        return x
    }

    private func charVeto(_ prevLast: String, _ curFirst: String) -> Int {
        let line = findLine(charT, prevLast)
        if line < 0 { return -Self.LM_LO }
        guard let wv = weightIn(charT, line, curFirst) else { return -Self.LM_LO }
        let x = Int(Double(wv - Self.LM_REF) * Self.LM_BETA)
        if x >= 0 { return 0 }
        return x > -Self.LM_LO ? x : -Self.LM_LO
    }

    // 与 tools/keyboard-verify/engine_lm.py 逐一对齐(勿单独改,须同步 Python 参照并重跑回归)
    private static let WREF = -700
    private static let WBETA = 0.13
    private static let WHI = 55
    private static let WLO = 40
    private static let LM_REF = -520
    private static let LM_BETA = 0.16
    private static let LM_LO = 70
}
