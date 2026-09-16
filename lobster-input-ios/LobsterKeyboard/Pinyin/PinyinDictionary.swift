import Foundation

/// 拼音词库(数据访问层)。词库来源:成熟开源 rime-ice(雾凇拼音)。
///
/// 含两张按 key 排序的紧凑字节表(键盘扩展内存友好,字节二分):
///  - full     全拼连写 → 候选(pinyin_dict.txt)
///  - initials 首字母简拼 → 候选(initials_dict.txt),支持业界标准简拼(cs→测试)
final class PinyinDictionary {

    private(set) var isReady = false

    /// 一张按 key 升序排列的词表:mmap 字节缓冲 + 紧凑行偏移索引 + 字节二分。
    /// 字节用 Data(.mappedIfSafe) 内存映射(内核按需分页,不全量拷贝、无加载峰值翻倍);
    /// 行偏移用 UInt32、key 长度用 UInt16,索引内存比 [Int] 减半。
    private final class ByteTable {
        private var bytes: Data = Data()
        private var lineStart: [UInt32] = []
        private var keyLen: [UInt16] = []
        private var lineEnd: [UInt32] = []

        func load(_ url: URL) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            bytes = data
            let n = bytes.count
            lineStart.reserveCapacity(170_000); keyLen.reserveCapacity(170_000); lineEnd.reserveCapacity(170_000)
            var i = 0
            while i < n {
                let start = i
                var tab = -1
                var j = i
                while j < n && bytes[j] != 0x0A {
                    if bytes[j] == 0x09 && tab < 0 { tab = j }
                    j += 1
                }
                if tab > start {
                    lineStart.append(UInt32(start)); keyLen.append(UInt16(min(tab - start, 65535))); lineEnd.append(UInt32(j))
                }
                i = j + 1
            }
        }

        var count: Int { lineStart.count }

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

        func indexOfKey(_ q: [UInt8]) -> Int {
            var lo = 0, hi = count - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let c = compareKey(at: mid, q)
                if c < 0 { lo = mid + 1 } else if c > 0 { hi = mid - 1 } else { return mid }
            }
            return -1
        }

        func lowerBound(_ q: [UInt8]) -> Int {
            var lo = 0, hi = count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if compareKey(at: mid, q) < 0 { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        func keyAt(_ index: Int) -> String {
            let s = Int(lineStart[index])
            return String(decoding: bytes[s ..< s + Int(keyLen[index])], as: UTF8.self)
        }

        func wordsAt(_ index: Int) -> [(String, Int)] {
            let s = Int(lineStart[index]) + Int(keyLen[index]) + 1
            let e = Int(lineEnd[index])
            guard s < e else { return [] }
            let parts = String(decoding: bytes[s ..< e], as: UTF8.self).split(separator: " ")
            var out: [(String, Int)] = []
            var i = 0
            while i + 1 < parts.count {
                let w = String(parts[i]); let lv = Int(parts[i + 1]) ?? 0
                if !w.isEmpty { out.append((w, lv)) }
                i += 2
            }
            return out
        }

        func exact(_ key: String) -> [(String, Int)] {
            let idx = indexOfKey([UInt8](key.utf8))
            return idx < 0 ? [] : wordsAt(idx)
        }

        func hasPrefix(_ prefix: String) -> Bool {
            let lb = lowerBound([UInt8](prefix.utf8))
            return lb < count && keyAt(lb).hasPrefix(prefix)
        }

        /// 前缀匹配:返回 (词, 等级, key长度)。
        func prefix(_ prefix: String, _ limit: Int) -> [(String, Int, Int)] {
            var out: [(String, Int, Int)] = []
            var pi = lowerBound([UInt8](prefix.utf8))
            while pi < count && out.count < limit {
                let k = keyAt(pi)
                if !k.hasPrefix(prefix) { break }
                if k.count != prefix.count, let first = wordsAt(pi).first {
                    out.append((first.0, first.1, k.count))
                }
                pi += 1
            }
            return out
        }

        /// key 的 ASCII 字节(T9 建索引用)。
        func keyBytesAt(_ index: Int) -> ArraySlice<UInt8> {
            let s = Int(lineStart[index])
            return [UInt8](bytes[s ..< s + Int(keyLen[index])])[...]
        }
    }

    private let full = ByteTable()
    private let initials = ByteTable()
    private var syllables = Set<String>()
    private var syllablePrefixes = Set<String>()
    private(set) var maxSyllableLen = 6

    func load() {
        isReady = false
        if let u = url("pinyin_dict") { full.load(u) }
        if let u = url("initials_dict") { initials.load(u) }
        loadSyllables()
        buildT9Index()
        buildCharReadings()
        isReady = full.count > 0
    }

    // 字读音表(切分歧义的权威裁决数据,镜像安卓):由词典单字条目构建——key 为合法音节
    // 的行,其单字词都记为该字的读音(华→hua、纳→na)。用于把候选词拼音按字对齐切分
    // (华纳+huana→hua|na),取代贪心最长匹配(huan|a)。
    private var charReadings: [Character: [String]] = [:]

    func readingsOf(_ c: Character) -> [String] { charReadings[c] ?? [] }

    private func buildCharReadings() {
        for idx in 0 ..< full.count {
            let key = full.keyAt(idx)
            guard syllables.contains(key) else { continue }
            for (w, _) in full.wordsAt(idx) where w.count == 1 {
                let ch = w.first!
                var list = charReadings[ch] ?? []
                if !list.contains(key) { list.append(key); charReadings[ch] = list }
            }
        }
        // 长读音在前:对齐 DFS 先试长音节,减少回溯
        for (k, v) in charReadings { charReadings[k] = v.sorted { $0.count > $1.count } }
    }

    private func url(_ name: String) -> URL? {
        Bundle(for: PinyinDictionary.self).url(forResource: name, withExtension: "txt")
    }

    private func loadSyllables() {
        guard let u = url("syllables"), let text = try? String(contentsOf: u, encoding: .utf8) else { return }
        for raw in text.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            syllables.insert(s)
            var prefix = ""
            for ch in s { prefix.append(ch); syllablePrefixes.insert(prefix) }
            if s.count > maxSyllableLen { maxSyllableLen = s.count }
        }
    }

    func isSyllable(_ s: String) -> Bool { syllables.contains(s) }
    func isSyllablePrefix(_ s: String) -> Bool { syllablePrefixes.contains(s) }

    /// 返回 input 从 pos 起的最长合法音节长度,无则 0(候选兜底用)。
    func longestSyllableAt(_ chars: [Character], _ pos: Int) -> Int {
        let maxLen = min(maxSyllableLen, chars.count - pos)
        if maxLen < 1 { return 0 }
        var len = maxLen
        while len >= 1 {
            if syllables.contains(String(chars[pos ..< pos + len])) { return len }
            len -= 1
        }
        return 0
    }

    // 全拼
    func exactWords(_ key: String) -> [(String, Int)] { full.exact(key) }
    func prefixWords(_ prefix: String, _ limit: Int) -> [(String, Int, Int)] { full.prefix(prefix, limit) }
    func bestWord(_ key: String) -> (String, Int)? { full.exact(key).first }

    // T9 数字码索引(业界标准:词库按数字码直查,根治 DFS 展开截断丢词)。
    // full 表每个拼音 key 预转数字码后排序;同码不同拼音的行都会命中(shangban/qiangban 同码)。
    private var t9Keys: [[UInt8]] = []
    private var t9Refs: [Int32] = []

    struct T9PrefixHit {
        let word: String
        let level: Int
        let keyDigitLen: Int
        let pinyinKey: String
    }

    private func buildT9Index() {
        var letter2digit = [UInt8](repeating: 0, count: 128)
        for c in "abc".utf8 { letter2digit[Int(c)] = UInt8(ascii: "2") }
        for c in "def".utf8 { letter2digit[Int(c)] = UInt8(ascii: "3") }
        for c in "ghi".utf8 { letter2digit[Int(c)] = UInt8(ascii: "4") }
        for c in "jkl".utf8 { letter2digit[Int(c)] = UInt8(ascii: "5") }
        for c in "mno".utf8 { letter2digit[Int(c)] = UInt8(ascii: "6") }
        for c in "pqrs".utf8 { letter2digit[Int(c)] = UInt8(ascii: "7") }
        for c in "tuv".utf8 { letter2digit[Int(c)] = UInt8(ascii: "8") }
        for c in "wxyz".utf8 { letter2digit[Int(c)] = UInt8(ascii: "9") }
        var rows: [([UInt8], Int32)] = []
        rows.reserveCapacity(full.count)
        outer: for idx in 0 ..< full.count {
            let keyBytes = full.keyBytesAt(idx)
            var digits = [UInt8]()
            digits.reserveCapacity(keyBytes.count)
            for c in keyBytes {
                let d = c < 128 ? letter2digit[Int(c)] : 0
                if d == 0 { continue outer }
                digits.append(d)
            }
            rows.append((digits, Int32(idx)))
        }
        rows.sort { lexLess($0.0, $1.0) }
        t9Keys = rows.map { $0.0 }
        t9Refs = rows.map { $0.1 }
    }

    private func lexLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let m = min(a.count, b.count)
        var i = 0
        while i < m {
            if a[i] != b[i] { return a[i] < b[i] }
            i += 1
        }
        return a.count < b.count
    }

    private func t9LowerBound(_ key: [UInt8]) -> Int {
        var lo = 0, hi = t9Keys.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if lexLess(t9Keys[mid], key) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 数字码精确查词:跨同码拼音合并,返回 (词, 等级, 拼音key)。
    func t9ExactWords(_ digits: String) -> [(String, Int, String)] {
        guard !digits.isEmpty else { return [] }
        let q = [UInt8](digits.utf8)
        var out: [(String, Int, String)] = []
        var i = t9LowerBound(q)
        while i < t9Keys.count && t9Keys[i] == q {
            let ref = Int(t9Refs[i])
            let key = full.keyAt(ref)
            for (w, lv) in full.wordsAt(ref) { out.append((w, lv, key)) }
            i += 1
        }
        return out
    }

    /// 数字码前缀补全:每个更长同前缀码取首选词,返回 (词, 等级, 码长, 拼音key)。
    func t9PrefixWords(_ digits: String, _ limit: Int) -> [T9PrefixHit] {
        guard !digits.isEmpty else { return [] }
        let q = [UInt8](digits.utf8)
        var out: [T9PrefixHit] = []
        var i = t9LowerBound(q)
        while i < t9Keys.count && out.count < limit {
            let dk = t9Keys[i]
            if dk.count < q.count || !dk.prefix(q.count).elementsEqual(q) { break }
            if dk.count != q.count {
                let ref = Int(t9Refs[i])
                if let first = full.wordsAt(ref).first {
                    out.append(T9PrefixHit(word: first.0, level: first.1, keyDigitLen: dk.count, pinyinKey: full.keyAt(ref)))
                }
            }
            i += 1
        }
        return out
    }

    // 简拼
    func initialsExact(_ key: String) -> [(String, Int)] { initials.exact(key) }
    func initialsPrefix(_ prefix: String, _ limit: Int) -> [(String, Int, Int)] { initials.prefix(prefix, limit) }
    func initialsHasPrefix(_ prefix: String) -> Bool { initials.hasPrefix(prefix) }

    // 音节切分
    func splitSyllables(_ input: String) -> [String] {
        let chars = Array(input)
        var out: [String] = []
        var pos = 0
        let n = chars.count
        while pos < n {
            if chars[pos] == "'" { pos += 1; continue }
            var matched = -1
            let maxLen = min(maxSyllableLen, n - pos)
            var len = maxLen
            while len >= 1 {
                if syllables.contains(String(chars[pos ..< pos + len])) { matched = len; break }
                len -= 1
            }
            if matched > 0 { out.append(String(chars[pos ..< pos + matched])); pos += matched }
            else { out.append(String(chars[pos ..< n])); break }
        }
        return out
    }

    func displaySegmented(_ input: String) -> String { splitSyllables(input).joined(separator: "'") }
}
