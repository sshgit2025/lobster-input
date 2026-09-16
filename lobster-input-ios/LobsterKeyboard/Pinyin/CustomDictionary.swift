import Foundation

/// 产品内置自定义扩展词库(custom_dict v2,61 万词)。数据访问层,与 PinyinDictionary 同构:
///  - 文件与主词库同格式:`拼音连写key\t词1 lv1 词2 lv2 ...`(key 升序、key 内 lv 降序),
///    由 tools/keyboard-verify/gen_custom_dict.py 生成,**与主词库零重复**、词频等级同量纲。
///  - 存储照抄主词库 ByteTable 模式:Data(.mappedIfSafe) 内存映射 + 紧凑行偏移索引 + 字节二分
///    (59 万 key 若解码成 String 并行数组会撑爆键盘扩展内存上限,字节表词条文本不解码、
///    命中行才转 String;mmap 为只读文件页,不计 dirty 内存)。
///  - T9 数字码索引:行号按 key 的数字码字典序排列([Int32] 排列,数字码查询/排序时由 key
///    字节即时换算比较,**不物化 59 万数字码串**——物化峰值 ~40MB 会顶到扩展 jetsam 线)。
///
/// 加载约定:数据在生成期已保证「全 CJK 2-8 字、拼音可完整切分合法音节、可映射数字码」,
/// 运行时**不做**贪心 allValidSyllables 校验(贪心会误杀 zuoleyinianduo 这类回溯才可切的合法键),
/// 只跳过注释/坏行。由 PinyinEngine 在主词库 READY 后**异步挂载**,挂载前查询按空表返回。
final class CustomDictionary {

    private(set) var isReady = false

    private var bytes: Data = Data()
    private var lineStart: [UInt32] = []
    private var keyLen: [UInt16] = []
    private var lineEnd: [UInt32] = []
    /// 行号排列:按 key 的 T9 数字码字典序(同码内按行号即 key 升序,稳定)。
    private var t9Order: [Int32] = []

    /// 自定义词最长数字码(T9 词层循环上限,biang=14 位不受 maxT9WordDigits 截断)。
    private(set) var maxDigitLen = 0

    private let letter2digit: [UInt8] = {
        var m = [UInt8](repeating: 0, count: 128)
        for c in "abc".utf8 { m[Int(c)] = UInt8(ascii: "2") }
        for c in "def".utf8 { m[Int(c)] = UInt8(ascii: "3") }
        for c in "ghi".utf8 { m[Int(c)] = UInt8(ascii: "4") }
        for c in "jkl".utf8 { m[Int(c)] = UInt8(ascii: "5") }
        for c in "mno".utf8 { m[Int(c)] = UInt8(ascii: "6") }
        for c in "pqrs".utf8 { m[Int(c)] = UInt8(ascii: "7") }
        for c in "tuv".utf8 { m[Int(c)] = UInt8(ascii: "8") }
        for c in "wxyz".utf8 { m[Int(c)] = UInt8(ascii: "9") }
        return m
    }()

    func load() {
        guard let url = Bundle(for: CustomDictionary.self).url(forResource: "custom_dict", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        var starts: [UInt32] = []
        var klens: [UInt16] = []
        var ends: [UInt32] = []
        starts.reserveCapacity(620_000); klens.reserveCapacity(620_000); ends.reserveCapacity(620_000)
        let n = data.count
        // 61 万行/16.7MB:扫描走裸指针(Data 逐字节下标在扩展里慢一个量级,拖冷挂载时长)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            var i = 0
            while i < n {
                let start = i
                var tab = -1
                var j = i
                while j < n && p[j] != 0x0A {
                    if p[j] == 0x09 && tab < 0 { tab = j }
                    j += 1
                }
                // 跳过注释行与无 TAB 的坏行(数据生成期已保证合法,这里只防御格式损坏)
                if tab > start && p[start] != 0x23 {
                    starts.append(UInt32(start)); klens.append(UInt16(min(tab - start, 65535))); ends.append(UInt32(j))
                }
                i = j + 1
            }
        }
        bytes = data
        lineStart = starts
        keyLen = klens
        lineEnd = ends
        buildT9Order()
        isReady = true
    }

    /// 数字码排列:比较器由 key 字节即时换算数字码(后台线程一次性 ~11M 次比较,
    /// 换取零物化内存——键盘扩展内存上限严苛,临时数字码串数组的分配峰值不可接受)。
    private func buildT9Order() {
        let count = lineStart.count
        var order: [Int32] = []
        order.reserveCapacity(count)
        var maxLen = 0
        bytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            for idx in 0 ..< count {
                let s = Int(lineStart[idx]); let kl = Int(keyLen[idx])
                var valid = true
                for k in 0 ..< kl {
                    let b = p[s + k]
                    if b >= 128 || letter2digit[Int(b)] == 0 { valid = false; break }
                }
                if !valid { continue }
                if kl > maxLen { maxLen = kl }
                order.append(Int32(idx))
            }
            order.sort { a, b in
                let c = compareDigitRows(p, Int(a), Int(b))
                return c != 0 ? c < 0 : a < b
            }
        }
        maxDigitLen = maxLen
        t9Order = order
    }

    /// 两行 key 的数字码字典序比较(排序用;key 已验证全部可映射数字)。
    private func compareDigitRows(_ p: UnsafeBufferPointer<UInt8>, _ ia: Int, _ ib: Int) -> Int {
        let sa = Int(lineStart[ia]); let la = Int(keyLen[ia])
        let sb = Int(lineStart[ib]); let lb = Int(keyLen[ib])
        let m = min(la, lb)
        var k = 0
        while k < m {
            let da = letter2digit[Int(p[sa + k])]
            let db = letter2digit[Int(p[sb + k])]
            if da != db { return da < db ? -1 : 1 }
            k += 1
        }
        if la == lb { return 0 }
        return la < lb ? -1 : 1
    }

    // MARK: 拼音键查询(字节二分,照抄 PinyinDictionary.ByteTable 模式)

    private func compareKey(at index: Int, _ q: [UInt8]) -> Int {
        let s = Int(lineStart[index]); let len = Int(keyLen[index])
        let m = min(len, q.count)
        var k = 0
        while k < m {
            let a = bytes[s + k], b = q[k]
            if a != b { return a < b ? -1 : 1 }
            k += 1
        }
        if len == q.count { return 0 }
        return len < q.count ? -1 : 1
    }

    private func lowerBound(_ q: [UInt8]) -> Int {
        var lo = 0, hi = lineStart.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if compareKey(at: mid, q) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func keyStartsWith(_ index: Int, _ q: [UInt8]) -> Bool {
        if Int(keyLen[index]) < q.count { return false }
        let s = Int(lineStart[index])
        for k in 0 ..< q.count where bytes[s + k] != q[k] { return false }
        return true
    }

    private func keyAt(_ index: Int) -> String {
        let s = Int(lineStart[index])
        return String(decoding: bytes[s ..< s + Int(keyLen[index])], as: UTF8.self)
    }

    /// 解析行内候选:`词1 lv1 词2 lv2 ...`(与主词库 wordsAt 同语义;limit 供取首选词短路)。
    private func wordsAt(_ index: Int, limit: Int = Int.max) -> [(String, Int)] {
        let s = Int(lineStart[index]) + Int(keyLen[index]) + 1
        let e = Int(lineEnd[index])
        guard s < e else { return [] }
        let parts = String(decoding: bytes[s ..< e], as: UTF8.self).split(separator: " ")
        var out: [(String, Int)] = []
        var i = 0
        while i + 1 < parts.count && out.count < limit {
            let w = String(parts[i]); let lv = Int(parts[i + 1]) ?? 0
            if !w.isEmpty { out.append((w, lv)) }
            i += 2
        }
        return out
    }

    /// 整键精确查词(与主词库 exactWords 同语义)。
    func exactWords(_ key: String) -> [(String, Int)] {
        guard isReady, !key.isEmpty else { return [] }
        let q = [UInt8](key.utf8)
        let i = lowerBound(q)
        if i >= lineStart.count || compareKey(at: i, q) != 0 { return [] }
        return wordsAt(i)
    }

    func bestWord(_ key: String) -> (String, Int)? {
        guard isReady, !key.isEmpty else { return nil }
        let q = [UInt8](key.utf8)
        let i = lowerBound(q)
        if i >= lineStart.count || compareKey(at: i, q) != 0 { return nil }
        return wordsAt(i, limit: 1).first
    }

    /// 前缀补全:每个更长同前缀 key 取首选词,返回 (词, 等级, key长)(与主词库 prefixWords 同语义)。
    func prefixWords(_ prefix: String, _ limit: Int) -> [(String, Int, Int)] {
        guard isReady, !prefix.isEmpty else { return [] }
        let q = [UInt8](prefix.utf8)
        var out: [(String, Int, Int)] = []
        var i = lowerBound(q)
        while i < lineStart.count && out.count < limit {
            if !keyStartsWith(i, q) { break }
            if Int(keyLen[i]) != q.count, let first = wordsAt(i, limit: 1).first {
                out.append((first.0, first.1, Int(keyLen[i])))
            }
            i += 1
        }
        return out
    }

    // MARK: T9 数字码查询(排列二分,数字码由 key 字节即时换算)

    /// key(行 index)的数字码与查询数字码逐位比较;prefixOnly 时 key 更长视为相等(前缀命中)。
    private func compareDigits(at index: Int, _ q: [UInt8], prefixOnly: Bool) -> Int {
        let s = Int(lineStart[index]); let len = Int(keyLen[index])
        let m = min(len, q.count)
        var k = 0
        while k < m {
            let b = bytes[s + k]
            let d = b < 128 ? letter2digit[Int(b)] : 0
            if d != q[k] { return d < q[k] ? -1 : 1 }
            k += 1
        }
        if prefixOnly && len >= q.count { return 0 }
        if len == q.count { return 0 }
        return len < q.count ? -1 : 1
    }

    private func t9LowerBound(_ q: [UInt8]) -> Int {
        var lo = 0, hi = t9Order.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if compareDigits(at: Int(t9Order[mid]), q, prefixOnly: false) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 数字码精确查词:跨同码拼音合并,返回 (词, 等级, 拼音key)(与主词库 t9ExactWords 同语义)。
    func t9ExactWords(_ digits: String) -> [(String, Int, String)] {
        guard isReady, !digits.isEmpty else { return [] }
        let q = [UInt8](digits.utf8)
        var out: [(String, Int, String)] = []
        var i = t9LowerBound(q)
        while i < t9Order.count {
            let ref = Int(t9Order[i])
            if compareDigits(at: ref, q, prefixOnly: false) != 0 { break }
            let key = keyAt(ref)
            for (w, lv) in wordsAt(ref) { out.append((w, lv, key)) }
            i += 1
        }
        return out
    }

    /// 数字码前缀补全:每个更长同前缀码取首选词(与主词库 t9PrefixWords 同语义)。
    func t9PrefixWords(_ digits: String, _ limit: Int) -> [PinyinDictionary.T9PrefixHit] {
        guard isReady, !digits.isEmpty else { return [] }
        let q = [UInt8](digits.utf8)
        var out: [PinyinDictionary.T9PrefixHit] = []
        var i = t9LowerBound(q)
        while i < t9Order.count && out.count < limit {
            let ref = Int(t9Order[i])
            if compareDigits(at: ref, q, prefixOnly: true) != 0 { break }
            if Int(keyLen[ref]) != q.count, let first = wordsAt(ref, limit: 1).first {
                out.append(PinyinDictionary.T9PrefixHit(word: first.0, level: first.1, keyDigitLen: Int(keyLen[ref]), pinyinKey: keyAt(ref)))
            }
            i += 1
        }
        return out
    }
}
