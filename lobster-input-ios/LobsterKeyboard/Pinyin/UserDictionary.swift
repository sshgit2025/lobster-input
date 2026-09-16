import Foundation

/// 用户个性化(纯用户学习,无需预置数据,越用越准):
///  - freq:   选词调频(单词频次),相同输入下选过的词显著提前。
///  - bigram: 选词路径(词A→词B 频次),用于"下一词"句子联想 + 记忆用户选择路径。
/// 均持久化于 App Group UserDefaults(防抖写入)。
final class UserDictionary {

    private var freq: [String: Int] = [:]
    private var bigram: [String: [String: Int]] = [:]
    /// 用户自造词(问题4:耗子尾汁类):拼音 key → (词 → 选中次数)。digits 由拼音派生,加载时重建。
    private var phrases: [String: [String: Int]] = [:]
    private var phraseDigits: [String: String] = [:]
    private let defaults = UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard
    private let freqKey = "ime_pinyin_user_freq"
    private let bigramKey = "ime_pinyin_user_bigram"
    private let phrasesKey = "ime_pinyin_user_phrases"
    private let maxFreq = 2000
    private let maxBigramKeys = 1500
    private let maxNext = 16
    private let maxPhraseKeys = 500
    private let maxPhrasePerKey = 4
    private let saveDelay: TimeInterval = 2
    private var freqSaveWork: DispatchWorkItem?
    private var bigramSaveWork: DispatchWorkItem?
    private var phraseSaveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "lobster.userdict.save")

    func load() {
        if let s = defaults.dictionary(forKey: freqKey) as? [String: Int] { freq = s }
        if let b = defaults.dictionary(forKey: bigramKey) as? [String: [String: Int]] { bigram = b }
        if let p = defaults.dictionary(forKey: phrasesKey) as? [String: [String: Int]] {
            phrases = p
            for py in p.keys { if let d = Self.toDigits(py) { phraseDigits[py] = d } }
        }
        HotwordDictionaryBridge.importInto(self)
    }

    private static func toDigits(_ pinyin: String) -> String? {
        var out = ""
        for c in pinyin {
            switch c {
            case "a", "b", "c": out.append("2")
            case "d", "e", "f": out.append("3")
            case "g", "h", "i": out.append("4")
            case "j", "k", "l": out.append("5")
            case "m", "n", "o": out.append("6")
            case "p", "q", "r", "s": out.append("7")
            case "t", "u", "v": out.append("8")
            case "w", "x", "y", "z": out.append("9")
            default: return nil
            }
        }
        return out
    }

    /// 学习自造词(引擎已做音节/长度护栏)。
    func learnPhrase(_ pinyin: String, _ digits: String, _ word: String) {
        var map = phrases[pinyin] ?? [:]
        map[word, default: 0] += 1
        if map.count > maxPhrasePerKey {
            let keep = map.sorted { $0.value > $1.value }.prefix(maxPhrasePerKey)
            map = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        phrases[pinyin] = map
        phraseDigits[pinyin] = digits
        if phrases.count > maxPhraseKeys {
            if let weakest = phrases.min(by: { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) })?.key, weakest != pinyin {
                phrases.removeValue(forKey: weakest)
                phraseDigits.removeValue(forKey: weakest)
            }
        }
        schedulePhraseSave()
    }

    /// 遍历全部自造词:(拼音, 数字码, 词, 次数)。候选生成用。
    func eachPhrase(_ action: (String, String, String, Int) -> Void) {
        for (py, map) in phrases {
            guard let d = phraseDigits[py] else { continue }
            for (w, c) in map { action(py, d, w, c) }
        }
    }

    func bonus(_ word: String) -> Int { freq[word] ?? 0 }

    func learn(_ word: String) {
        guard !word.isEmpty else { return }
        freq[word, default: 0] += 1
        if freq.count > maxFreq {
            let keep = freq.sorted { $0.value > $1.value }.prefix(maxFreq * 3 / 4)
            freq = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        scheduleFreqSave()
    }

    /// 记录词对 a→b。
    func learnPair(_ a: String, _ b: String) {
        guard !a.isEmpty, !b.isEmpty, a != b else { return }
        var m = bigram[a] ?? [:]
        m[b, default: 0] += 1
        if m.count > maxNext {
            let keep = m.sorted { $0.value > $1.value }.prefix(maxNext)
            m = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        bigram[a] = m
        if bigram.count > maxBigramKeys {
            if let weakest = bigram.min(by: { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) })?.key, weakest != a {
                bigram.removeValue(forKey: weakest)
            }
        }
        scheduleBigramSave()
    }

    /// 下一词联想:按用户历史频次降序。
    func nextWords(_ a: String) -> [String] {
        (bigram[a] ?? [:]).sorted { $0.value > $1.value }.map { $0.key }
    }

    /// 词对共现次数(整句 DP 的 bigram 转移加成用)。
    func pairCount(_ a: String, _ b: String) -> Int { bigram[a]?[b] ?? 0 }

    private func scheduleFreqSave() {
        freqSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushFreq() }
        freqSaveWork = work
        saveQueue.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    private func scheduleBigramSave() {
        bigramSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushBigram() }
        bigramSaveWork = work
        saveQueue.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    private func schedulePhraseSave() {
        phraseSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPhrases() }
        phraseSaveWork = work
        saveQueue.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    private func flushPhrases() {
        defaults.set(phrases, forKey: phrasesKey)
    }

    private func flushFreq() {
        defaults.set(freq, forKey: freqKey)
    }

    private func flushBigram() {
        defaults.set(bigram, forKey: bigramKey)
    }
}
