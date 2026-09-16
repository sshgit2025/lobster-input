import Foundation

/// 一个拼音候选词。matchedLen = 该候选消耗的输入字符数。
/// isSymbol:9 宫格 1 键的高频符号候选(选中按智能配对上屏,不写词典、不改联想链)。
/// isPunct:候选栏标点联想(2026-07-23),选中直接上屏(不配对)、不学习、不改联想链;
/// 与 isSymbol 严格隔离——不参与候选栏两侧收起契约、不触发 SmartPunctuation 配对。
struct PinyinCandidate {
    let word: String
    let matchedLen: Int
    let score: Int
    var isEmoji: Bool = false
    var pinyin: String = ""
    var isSymbol: Bool = false
    var isPunct: Bool = false
}

/// 拼音引擎(算法层)。排序参照业界(RIME/搜狗)分层(分区)策略:
///   整句 > 全拼精确字/词 > 简拼精确 > 全拼前缀联想 > 简拼前缀 > 部分匹配单字
/// 即"精确候选"整体优先于"前缀联想",每层内按 词频 + 整词词长 + 用户调频。
/// 打 426 先出 好/号/毫(精确),联想"好的"排其后;打 42633(haode)"好的"是精确整词→第1。
final class PinyinEngine {

    private let dict = PinyinDictionary()
    private let customDict = CustomDictionary()
    private let sentenceLm = SentenceLanguageModel()
    private let userDict = UserDictionary()
    private var fuzzy = PinyinFuzzy.Settings()
    private var loading = false
    private var loadListeners: [PinyinLoadListener] = []
    private let listenerLock = NSLock()

    private let levelW = 1_000
    private let lenW = 400
    private let layerSentence = 5_000_000
    private let layerExact = 4_000_000
    private let layerSentenceFull = 3_900_000    // 整句(全消耗但已有整词):居次
    private let layerSentencePartial = 1_800_000 // 整句(忽略尾字母):沉底于全消耗层
    private let penMiss = 8_000                  // 前缀补全每缺失字母罚分(≈8 个词频级)
    private let exactFullBonus = 60_000          // T9 全消耗精确词加成:同码时精确(要钱)必压补全(晚上)
    private let completionTop = 12               // T9 补全预测入池上限(业界:预测只置顶少量,防淹没单字)
    // 自定义词参与"补全预测"的最低词频等级:预测必须高置信(jieba 标定真实常用≥110 或精选热词 142);
    // 长尾词(base残余/ext默认55)只在"打全"时可达——防弱补全把部分消耗高频词(我想@woxiangch)挤出前排。
    private let customCompletionMinLv = 110
    // 2026-07 修「yi 打不出咦」:词库去除 30/key 构建截断后大音节(yi=137字)全量入库,
    // 100/120 会把锁定单音节的尾部单字再次截掉 → 200/300 + takeWithExactGuarantee 保证全量可达。
    static let candLimit = 200                   // 候选显示上限(40/60 会把中频单字如 尾@weizhi 截掉)
    private let t9Pool = 300                     // T9 结果缓存池大小
    private let phraseFreq = 200                 // 用户自造词基准词频级(高于最高静态词频,学过必出)
    private let layerFuzzy = 3_500_000
    private let layerCorrection = 1_500_000
    private let fuzzyComboCap = 24
    private let layerAbbr = 3_000_000
    private let layerPrefix = 2_000_000
    private let layerAbbrPrefix = 1_000_000
    private let layerSingle = 0
    private let userWeight = 20_000
    private let userCap = 20
    private let matchW = 1_000_000     // 9宫格逐词:消耗位数主导(长词优先)
    private let maxT9WordDigits = 9    // 单次成词最多数字位数(~3字词),封顶防超长串卡死
    private let assocBase = 10_000_000 // 句子联想分基准
    private let maxT9Seg = 13          // 8→13:让 逛一逛(12位)/吃火锅(9位) 等词库长短语参与整句
    private let maxT9Sentence = 64     // 整句联想最大数字位数(≈21字);记忆化后单步<1ms
    private let segPenalty = 300       // 显示切分分段惩罚
    private let sentPen = 380          // 整句每词惩罚(电池扫描最优,独立于显示切分)
    private let gapPen = 600           // 错键容忍:跳过一位"误触"的罚分(>最大成词净收益)
    private let sentTopK = 3           // 状态 DP 每位置/每段保留路径数
    private let bigramW = 200          // 用户 bigram 每次共现加成(封顶2次=400)

    var isReady: Bool { dict.isReady }

    func addLoadListener(_ listener: @escaping PinyinLoadListener) {
        listenerLock.lock()
        loadListeners.append(listener)
        listenerLock.unlock()
        if loading {
            notifyListeners(.loading, nil)
        } else if dict.isReady {
            notifyListeners(.ready, nil)
        }
    }

    func loadAsync() {
        if loading { return }
        loading = true
        notifyListeners(.loading, nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.dict.load()
            if self.dict.isReady {
                self.userDict.load()
                self.loading = false
                self.notifyListeners(.ready, nil)
                // 海量内置自定义词库(custom_dict v2,61 万词)READY 后异步挂载:
                // 不阻塞键盘可用,挂载前查询按空表返回;挂载完成后回主线程失效 T9 缓存
                // (缓存与引擎查询同在主线程使用,避免跨线程清缓存竞态)。
                self.customDict.load()
                // 整句语言模型(词/字 bigram)READY 后异步挂载:修"打对拼音出弱智句";
                // 挂载前 boundaryScore 返回 0(退化为原词频整句),挂载完失效 T9 缓存。
                self.sentenceLm.load()
                DispatchQueue.main.async { [weak self] in
                    self?.t9CacheKey = nil
                    self?.topWordsCache.removeAll(keepingCapacity: true)
                }
            } else {
                self.loading = false
                self.notifyListeners(.failed, MobileStrings.pinyinDictFailed())
            }
        }
    }

    private func notifyListeners(_ state: PinyinLoadState, _ detail: String?) {
        listenerLock.lock()
        let listeners = loadListeners
        listenerLock.unlock()
        DispatchQueue.main.async {
            for listener in listeners { listener(state, detail) }
        }
    }

    func displaySegmented(_ input: String) -> String { dict.displaySegmented(input) }
    func learn(_ word: String) { userDict.learn(word) }
    func setFuzzy(_ s: PinyinFuzzy.Settings) { fuzzy = s }

    private func userBonus(_ word: String) -> Int { min(userDict.bonus(word), userCap) * userWeight }
    private func lenBonus(_ word: String) -> Int { (min(word.count, 5) - 1) * lenW }
    private func layerScore(_ layer: Int, _ level: Int, _ word: String, penalty: Int = 0) -> Int {
        let freq: Int = level * levelW
        let lenB: Int = lenBonus(word)
        let bonus: Int = userBonus(word)
        return layer + freq + lenB - penalty + bonus
    }

    /// 句子联想:基于用户历史的"下一词"预测(纯用户学习,越用越准)。matchedLen=0(不消耗输入)。
    func associations(_ prev: String, limit: Int = 12) -> [PinyinCandidate] {
        // 用户自学习优先 + 内置 bigram 兜底(冷启动不为空),去重保序。
        var merged: [String] = []
        var seen = Set<String>()
        for w in userDict.nextWords(prev) + BuiltinPrediction.nextWords(prev) where seen.insert(w).inserted {
            merged.append(w)
        }
        return merged.prefix(limit).enumerated().map { PinyinCandidate(word: $1, matchedLen: 0, score: assocBase - $0) }
    }

    /// 记录用户选词路径:单词调频 + 词对(bigram)学习。
    func learnSequence(_ prev: String?, _ word: String) {
        userDict.learn(word)
        if let p = prev, !p.isEmpty { userDict.learnPair(p, word) }
        // 学习立刻生效:清 T9 结果缓存(bigram 影响整句),下次同串重算
        t9CacheKey = nil
    }

    /// 用户自造词学习(问题4:耗子尾汁类)。用户对同一拼音串逐词/逐字组合选完后,
    /// 由控制层把「整串拼音 + 组合出的词」学进用户词典;下次输入同拼音(26 键或 T9)直接出整词。
    /// 词库已有整词则跳过(调频已覆盖);拼音必须可完整切分(护栏,与自定义词同规则)。
    func learnPhrase(_ pinyin: String, _ word: String) {
        if pinyin.isEmpty || word.count < 2 || word.count > 8 { return }
        if !allValidSyllables(pinyin) { return }
        if dict.exactWords(pinyin).contains(where: { $0.0 == word }) { return }
        var digits = ""
        for c in pinyin {
            guard let d = letter2digit[c] else { return }
            digits.append(d)
        }
        userDict.learnPhrase(pinyin, digits, word)
        t9CacheKey = nil
    }

    // MARK: 全拼 + 简拼(26 键)
    /// 26 键候选(业界对齐排序,镜像安卓,已本地脚本电池验证:完整拼音错误率 26/30→1/30)。
    /// 总原则:**消耗全部已输入字母的候选 > 忽略尾部字母的候选**。
    ///  - 词层 = 整词精确 + 前缀补全(每缺失字母罚 penMiss):youmeiy→有没有、dianhu→电话。
    ///  - 整句只有消耗全部输入且无整词可覆盖时才置顶(修 nihao→"你哈哦" 压过 你好);
    ///    部分覆盖(如 youmeiy 的"有没")沉到所有全消耗层之下。
    ///  - 同词去重保最高分(避免 有没有 以不同 matchedLen 重复出现)。
    func candidates(_ input: String, limit: Int = PinyinEngine.candLimit) -> [PinyinCandidate] {
        guard dict.isReady else { return [] }
        let pinyin = input.filter { $0 != "'" }
        guard !pinyin.isEmpty else { return [] }
        let n = pinyin.count

        var merged: [String: PinyinCandidate] = [:]
        func push(_ word: String, _ matchedLen: Int, _ score: Int) {
            if word.isEmpty { return }
            if let old = merged[word], old.score >= score { return }
            merged[word] = PinyinCandidate(word: word, matchedLen: matchedLen, score: score)
        }

        // 词层:整词精确 + 前缀补全。高频补全(电话)可胜低频精确词(电弧),缺得越多罚越重。
        let exacts = dict.exactWords(pinyin)
        let prefixes = dict.prefixWords(pinyin, 400)
        // 自定义词(custom_dict v2):精确与主词库同层同权;前缀补全同罚分。
        let cExacts = customDict.exactWords(pinyin)
        let cPrefixes = n >= 2 ? customDict.prefixWords(pinyin, 200) : []
        // hasFullWord 计入自定义词:只有自定义词能整词覆盖时,整句不得抢 layerSentence 置顶。
        let hasFullWord = !exacts.isEmpty || !prefixes.isEmpty || !cExacts.isEmpty || !cPrefixes.isEmpty
        for (w, lv) in exacts { push(w, n, layerScore(layerExact, lv, w)) }
        for (w, lv, klen) in prefixes { push(w, klen, layerScore(layerExact, lv, w, penalty: (klen - n) * penMiss)) }
        for (w, lv) in cExacts { push(w, n, layerScore(layerExact, lv, w)) }
        // 低置信长尾词(lv<110)不做预测(打全才出):防弱补全把部分消耗高频词挤出前排
        for (w, lv, klen) in cPrefixes where lv >= customCompletionMinLv {
            push(w, klen, layerScore(layerExact, lv, w, penalty: (klen - n) * penMiss))
        }

        if let s = sentenceCandidate(pinyin) {
            let layer: Int
            if s.matchedLen >= n && !hasFullWord { layer = layerSentence }          // 长句无整词:整句置顶
            else if s.matchedLen >= n { layer = layerSentenceFull }                 // 有整词:整句居次
            else { layer = layerSentencePartial }                                   // 忽略尾字母:沉底于全消耗层
            push(s.word, s.matchedLen, layer + max(s.score, 0))
        }

        for (w, lv) in dict.initialsExact(pinyin) { push(w, n, layerScore(layerAbbr, lv, w)) }
        for (w, lv, klen) in dict.initialsPrefix(pinyin, 60) {
            push(w, klen, layerScore(layerAbbrPrefix, lv, w, penalty: (klen - n) * 15))
        }
        if let firstSyl = dict.splitSyllables(pinyin).first, firstSyl != pinyin, dict.isSyllable(firstSyl) {
            for (w, lv) in dict.exactWords(firstSyl) where w.count == 1 {
                push(w, firstSyl.count, layerScore(layerSingle, lv, w))
            }
        }
        fuzzyCandidates(pinyin) { w, lv in push(w, n, layerScore(layerFuzzy, lv, w)) }
        if merged.count < 3 { correctionCandidates(pinyin) { w, lv in push(w, n, layerScore(layerCorrection, lv, w)) } }
        // 用户自造词(耗子尾汁类,逐词组合学得):同自定义词规则,phraseFreq 保证学过必出。
        // 【用户选择记忆】自造词吃下整串输入 → 压过整句(layerSentence 基线,镜像 T9;
        // 曾 layerExact=4.2M < 整句 5M,学过的组合在 26 键仍被整句压住)。
        userDict.eachPhrase { ppy, _, word, cnt in
            let boost = min(cnt, 5) * levelW
            if ppy == pinyin {
                push(word, n, layerSentence + phraseFreq * levelW + boost + lenBonus(word))
            } else if pinyin.hasPrefix(ppy) {
                push(word, ppy.count, layerExact + phraseFreq * levelW + boost + lenBonus(word))
            } else if n >= 2 && ppy.hasPrefix(pinyin) {
                push(word, ppy.count, layerExact + phraseFreq * levelW + boost + lenBonus(word) - (ppy.count - n) * penMiss)
            }
        }
        // 分段兜底 + 字面兜底(对齐搜狗:候选栏永不空白)
        if merged.count < 2 { segmentedFallback(pinyin) { w, len, sc in push(w, len, sc) } }
        if merged.isEmpty { push(pinyin, n, layerSingle - 1) }
        let ranked = merged.values.sorted { $0.score > $1.score }
        // 【单字全量可达保底】打全拼音的精确候选绝不被联想潮水挤出(26 键无拼音选择器,
        // 候选列表是唯一通道;修「输入 a 打不出 锕」类生僻字不可达,本地脚本全音节扫描验证)。
        // 保底集并入自定义精确词:自定义词打全同样必可达。
        var exactSet = Set(exacts.map { $0.0 })
        for (w, _) in cExacts { exactSet.insert(w) }
        return takeWithExactGuarantee(ranked, limit, exactSet)
    }

    /// 取前 limit 个,但整串精确候选(打全拼音/数字码的字词)绝不被截出——单字全量可达保底。
    private func takeWithExactGuarantee(_ ranked: [PinyinCandidate], _ limit: Int, _ exactWords: Set<String>) -> [PinyinCandidate] {
        if ranked.count <= limit { return ranked }
        var out = Array(ranked[0..<limit])
        if !exactWords.isEmpty {
            for i in limit..<ranked.count where exactWords.contains(ranked[i].word) {
                out.append(ranked[i])
            }
        }
        return out
    }

    /// 整串数字码的精确候选词集合(锁定态按边界过滤)——全量可达保底用。
    private func t9ExactSet(_ digits: String, _ lockedSylls: [String]) -> Set<String> {
        var out = Set<String>()
        let lockedPinyin = Array(lockedSylls.joined())
        let bounds = lockedSylls.isEmpty ? Set<Int>() : lockedBounds(lockedSylls)
        for (w, _, key) in dict.t9ExactWords(digits) {
            if lockedSylls.isEmpty || lockedCompatible(w, key, 0, lockedPinyin, bounds) { out.insert(w) }
        }
        // 保底集并入自定义精确词:自定义词打全数字码同样必可达
        for (w, _, key) in customDict.t9ExactWords(digits) {
            if lockedSylls.isEmpty || lockedCompatible(w, key, 0, lockedPinyin, bounds) { out.insert(w) }
        }
        // 锁定态逐字组词通道:首锁定音节单字同样保底(锁 yi 必能点出 咦)
        if let first = lockedSylls.first {
            for (w, _) in dict.exactWords(first) { out.insert(w) }
        }
        return out
    }

    /// 分段兜底:沿最长合法音节前缀逐段出单字;遇非法位置把剩余作字母候选。只取前 2 段。
    private func segmentedFallback(_ pinyin: String, _ push: (String, Int, Int) -> Void) {
        let chars = Array(pinyin)
        var pos = 0, seg = 0
        while pos < chars.count && seg < 2 {
            let len = dict.longestSyllableAt(chars, pos)
            if len == 0 { push(String(chars[pos...]), chars.count, layerSingle - 2); return }
            let syl = String(chars[pos ..< pos + len])
            for (w, lv) in dict.exactWords(syl) where w.count == 1 {
                push(w, pos + len, layerScore(layerSingle, lv, w))
            }
            pos += len; seg += 1
        }
    }

    /// 模糊音候选(26 键全拼):整串能完整切成合法音节时,按开关派生等价音节组合查词。
    private func fuzzyCandidates(_ pinyin: String, _ push: (String, Int) -> Void) {
        guard fuzzy.anyFuzzy else { return }
        let syls = dict.splitSyllables(pinyin)
        if syls.isEmpty || syls.joined() != pinyin { return }
        if syls.contains(where: { !dict.isSyllable($0) }) { return }
        var combos: [String] = [""]
        for syl in syls {
            let vars = PinyinFuzzy.variants(syl, fuzzy)
            var next: [String] = []
            for c in combos {
                for v in vars {
                    if next.count >= fuzzyComboCap { break }
                    next.append(c + v)
                }
                if next.count >= fuzzyComboCap { break }
            }
            combos = next
            if combos.count >= fuzzyComboCap { break }
        }
        for key in combos where key != pinyin {
            for (w, lv) in dict.exactWords(key) { push(w, lv) }
        }
    }

    /// 容错纠错(26 键全拼):整串无法切分时,对最后一段做编辑距离≤1 还原。
    private func correctionCandidates(_ pinyin: String, _ push: (String, Int) -> Void) {
        guard fuzzy.correction, pinyin.count >= 2 else { return }
        let syls = dict.splitSyllables(pinyin)
        guard let last = syls.last, !dict.isSyllable(last) else { return }
        let prefix = String(pinyin.dropLast(last.count))
        for fixed in PinyinFuzzy.corrections(last, { dict.isSyllable($0) }) {
            for (w, lv) in dict.exactWords(prefix + fixed) { push(w, lv) }
        }
    }

    /// 整句候选(26 键,镜像安卓)。每词惩罚 segPenalty 逼最少词数,修碎拼垃圾("你哈哦"压过"你好");
    /// 末段允许前缀补全,尾部残音节也能进整句(youmeiy→有没+有),matchedLen==n 表示消耗全部输入。
    private func sentenceCandidate(_ input: String) -> PinyinCandidate? {
        let chars = Array(input)
        let n = chars.count
        if n < 2 { return nil }
        var dp = [Int](repeating: Int.min, count: n + 1)
        var from = [Int](repeating: -1, count: n + 1)
        var word = [String?](repeating: nil, count: n + 1)
        dp[0] = 0
        for i in 1...n {
            let lo = max(0, i - dict.maxSyllableLen * 4)
            for j in lo..<i {
                if dp[j] == Int.min { continue }
                let seg = String(chars[j..<i])
                var best = dict.bestWord(seg)
                // 自定义词参与切分成句(取两表更高词频者)
                if let cb = customDict.bestWord(seg), cb.1 > (best?.1 ?? Int.min) { best = cb }
                if best == nil && i == n && j > 0 {
                    // 尾段残音节:取最优前缀补全词(按缺失字母数微罚)参与整句
                    var comp: (String, Int)?
                    for (w, lv, klen) in dict.prefixWords(seg, 30) {
                        let adj = lv - (klen - (i - j)) * 8
                        if comp == nil || adj > comp!.1 { comp = (w, adj) }
                    }
                    best = comp
                }
                guard let b = best else { continue }
                let gain: Int = b.1 - segPenalty + min(userDict.bonus(b.0), userCap)
                if dp[j] + gain > dp[i] { dp[i] = dp[j] + gain; from[i] = j; word[i] = b.0 }
            }
        }
        var end = n
        while end > 0 && dp[end] == Int.min { end -= 1 }
        if end < 2 || from[end] < 0 { return nil }
        var parts: [String] = []
        var cur = end
        while cur > 0 && from[cur] >= 0 { parts.append(word[cur]!); cur = from[cur] }
        if cur != 0 || parts.count < 2 { return nil }
        return PinyinCandidate(word: parts.reversed().joined(), matchedLen: end, score: dp[end])
    }

    // MARK: 9 宫格 T9
    private let t9: [Character: String] = [
        "2": "abc", "3": "def", "4": "ghi", "5": "jkl",
        "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz"
    ]

    // MARK: 切分歧义根治(修 huanameduoqian 被当成 huan|a|me...,镜像安卓)
    // 业界标准:候选词拼音按"字→读音表"对齐切分(权威),不再用贪心最长/音节频率猜。
    private var alignCache: [String: [String]?] = [:]

    /// 把词的拼音 key 按字对齐切成音节(华纳+huana→[hua,na]、西安+xian→[xi,an])。
    /// 对不齐(生僻字/数据缺失)返回 nil,调用方回退贪心切分。
    func alignWordPinyin(_ word: String, _ key: String) -> [String]? {
        if word.isEmpty || key.isEmpty { return nil }
        let ck = word + "\u{1}" + key
        if let cached = alignCache[ck] { return cached }
        let wchars = Array(word)
        var result: [String]? = nil
        var acc: [String] = []
        func dfs(_ ci: Int, _ pos: String.Index) {
            if result != nil { return }
            if ci == wchars.count {
                if pos == key.endIndex { result = acc }
                return
            }
            for r in dict.readingsOf(wchars[ci]) {
                if key[pos...].hasPrefix(r) {
                    acc.append(r)
                    dfs(ci + 1, key.index(pos, offsetBy: r.count))
                    acc.removeLast()
                    if result != nil { return }
                }
            }
        }
        dfs(0, key.startIndex)
        if alignCache.count > 8000 { alignCache.removeAll(keepingCapacity: true) }
        alignCache[ck] = result
        return result
    }

    /// 锁定音节栈 → 边界位置集合(累积长度)。
    /// 【单键锁定修复】尾项若只是音节前缀而非完整音节(单键 3 点选 d/f、残拼锁 zh 类),
    /// 它只约束"读音从这些字母开始",不构成音节边界——候选读音可越过其末端继续铺开
    /// (锁 d 后 的@de 合法)。非尾项保持边界(已被后续点选确认)。
    private func lockedBounds(_ locked: [String]) -> Set<Int> {
        var bounds = Set<Int>(); var acc = 0
        for (i, s) in locked.enumerated() {
            acc += s.count
            if i == locked.count - 1 && !dict.isSyllable(s) { continue }
            bounds.insert(acc)
        }
        return bounds
    }

    /// 候选(word,key)从拼音位置 start 铺开,是否兼容锁定音节边界:
    /// ①与锁定拼音重叠部分逐字母一致;②候选在锁定区内结束必须停在音节边界;
    /// ③锁定区内部边界必须是候选字读音对齐后的边界(锁 hua 排除 换@huan)。
    private func lockedCompatible(_ word: String, _ key: String, _ start: Int, _ lockedPinyin: [Character], _ bounds: Set<Int>) -> Bool {
        let lockLen = lockedPinyin.count
        if start >= lockLen { return true }
        let kchars = Array(key)
        let end = start + kchars.count
        let p = min(end, lockLen)
        for i in 0 ..< (p - start) where kchars[i] != lockedPinyin[start + i] { return false }
        if end < lockLen && !bounds.contains(end) { return false }
        let inner = bounds.filter { $0 > start && $0 < end }
        if inner.isEmpty { return true }
        guard let aligned = alignWordPinyin(word, key) else { return true } // 生僻字对不齐:不强杀(宁多勿漏)
        var wb = Set<Int>(); var acc = start
        for s in aligned { acc += s.count; wb.insert(acc) }
        return inner.allSatisfy { wb.contains($0) }
    }

    /// 候选显示拼音:字对齐切分优先(华纳+huana→hua'na),失败回退贪心。
    func displaySplit(_ word: String, _ key: String) -> String {
        alignWordPinyin(word, key)?.joined(separator: "'") ?? splitKnownPinyin(key)
    }

    /// T9 候选(业界对齐,数字码索引直查,镜像安卓,已本地脚本电池验证)。
    /// 总原则与 26 键一致:**消耗全部输入的候选 > 忽略尾部输入的候选**。
    ///  - 词层 = 逐前缀精确词(数字码直查,根治 DFS 512 截断丢词:shangban 曾永远打不出"上班")
    ///    + 全消耗前缀补全(youmeiy→有没有、shaow→稍微,每缺失位罚 penMiss)。
    ///  - 全消耗精确词加 exactFullBonus:同码时精确词(要钱)永远压过补全词(晚上@wanshang)。
    ///  - 整句全覆盖时置顶,部分覆盖沉底(镜像 26 键分层)。
    /// lockedSylls:拼音选择器锁定音节栈(切分歧义根治)——词层/补全/整句全部按锁定
    /// 边界过滤(锁 hua 排除 换@huan),取代旧"锁定拼音串重查+贪心剩余段"路径。
    func candidatesT9(_ digits: String, limit: Int = PinyinEngine.candLimit, lockedSylls: [String] = []) -> [PinyinCandidate] {
        guard dict.isReady, !digits.isEmpty else { return [] }
        var merged: [String: PinyinCandidate] = [:]
        let lockedPinyin = Array(lockedSylls.joined())
        let bounds = lockedSylls.isEmpty ? Set<Int>() : lockedBounds(lockedSylls)
        func ok(_ word: String, _ key: String) -> Bool {
            lockedSylls.isEmpty || lockedCompatible(word, key, 0, lockedPinyin, bounds)
        }
        func put(_ word: String, _ matchedLen: Int, _ score: Int, _ pinyin: String = "") {
            if word.isEmpty { return }
            if let old = merged[word], old.score >= score { return }
            merged[word] = PinyinCandidate(word: word, matchedLen: matchedLen, score: score, pinyin: pinyin)
        }
        func consider(_ word: String, _ matchedLen: Int, _ base: Int, _ level: Int, _ pinyin: String) {
            put(word, matchedLen, matchedLen * matchW + base + level * levelW + lenBonus(word) + userBonus(word), pinyin)
        }
        let chars = Array(digits)
        let n = chars.count
        // 【单键锁定修复】锁定串已覆盖全部数字且尾项只是音节前缀(单键 3 锁 d/f、锁 zh 类):
        // 词层(L>=2)/补全(数字空间在共享键上扫不到目标声母)/锁定单字(须完整音节)全部无产出,
        // 旧实现落进绕过锁定的兜底 → "点了没反应"。此形态语义上等价于"26 键打了 d 这个前缀"
        // → 直接复用 26 键成熟预测通道(的/都/大),matchedLen=n:选词一次吃净全部数字与锁定栈。
        // 方案经 scratch-keyboard-verify/test_t9_prefix_lock.py 全量验证。
        if let lastLocked = lockedSylls.last, lockedPinyin.count >= n, !dict.isSyllable(lastLocked) {
            return candidates(lockedSylls.joined(), limit: limit).map {
                PinyinCandidate(word: $0.word, matchedLen: n, score: $0.score, pinyin: $0.pinyin)
            }
        }
        if n >= 4 {
            // 整句联想(带锁定约束+拼音回溯):全覆盖置顶;部分覆盖沉底(镜像 26 键原则)。
            // top-2 路径:次优整句降 1 个词频级参与排序(用户学习翻转 #1 后原整句变体不消失)。
            for (rank, item) in sentenceT9(digits, lockedSylls: lockedSylls).enumerated() {
                let (whole, cov, spy) = item
                let layer = cov >= n ? layerSentence : layerSentencePartial
                put(whole, cov, cov * matchW + layer - rank * levelW, spy)
            }
        }
        // 简拼(锁定态跳过:简拼词无完整读音,无法验证锁定边界)
        if lockedSylls.isEmpty && n <= maxT9WordDigits {
            for s in expandInitials(digits) {
                for (w, lv) in dict.initialsExact(s) { consider(w, n, layerAbbr, lv, "") }
            }
        }
        // 词层:逐前缀精确词(数字码索引直查,同码拼音全命中、无展开截断)。
        // 全消耗(L==n)加 exactFullBonus:同码时精确词永远压过下面的补全词。
        // 词层准入(主词库/自定义对称):L<=9 照旧;L==n(全消耗)不限长——打全整词
        // (第六章 10位/事业单位 11位/biang 14位)直接可排,不再只靠整句碰运气。
        let maxL = min(n, max(maxT9WordDigits, customDict.maxDigitLen))
        if maxL >= 2 {
            for L in 2...maxL {
                if L > maxT9WordDigits && L != n { continue }
                let bonus = L == n ? exactFullBonus : 0
                let seg = String(chars[0..<L])
                let mainHits = dict.t9ExactWords(seg)
                for (w, lv, key) in mainHits where ok(w, key) {
                    // 【用户选择记忆】全消耗且用户选过(调频>0)的词层基线提到整句之上——
                    // 对齐 RIME 动态调频/搜狗智能调频:用户显式选择 > 机器整句猜测(修 什么鬼/什么会 类)。
                    let layer = (L == n && userBonus(w) > 0) ? layerSentence : layerExact
                    put(w, L, L * matchW + layer + bonus + lv * levelW + lenBonus(w) + userBonus(w), key)
                }
                // 自定义词层(custom_dict v2):全消耗时——同码有主词库精确词 → 同层公平按词频竞争
                // (防 61 万词劫持常用短码,九宫格正向核心保护);无主词精确词 → layerSentence
                // (破防了/什么鬼 类新词不被整句垃圾压住;biang showcase 语义保留)。
                for (w, lv, key) in customDict.t9ExactWords(seg) where ok(w, key) {
                    let layer: Int
                    if L == n && userBonus(w) > 0 { layer = layerSentence }
                    else if L == n && mainHits.isEmpty { layer = layerSentence }
                    else { layer = layerExact }
                    put(w, L, L * matchW + layer + bonus + lv * levelW + lenBonus(w) + userBonus(w), key)
                }
            }
        }
        // 全消耗前缀补全(修"必须打全数字才出词"):数字码前缀直查,matchedLen=n 排在部分消耗词之上,
        // 缺失位数罚 penMiss(与 26 键同值)。youmeiy(9686349)→有没有、shaow(74269)→稍微。
        // 补全是"预测",业界只置顶少量(修 尾@weizhi 被淹没):按调整分只取 top completionTop 入池,
        // 避免几百个"位置信息"类补全词把逐字组词通道的单字(尾)挤出候选池。
        if n >= 2 && n <= maxT9WordDigits {
            var comps: [(adj: Int, word: String, key: String)] = []
            for hit in dict.t9PrefixWords(digits, 200) where ok(hit.word, hit.pinyinKey) {
                let adj = hit.level * levelW + lenBonus(hit.word) + userBonus(hit.word) - (hit.keyDigitLen - n) * penMiss
                comps.append((adj, hit.word, hit.pinyinKey))
            }
            // 自定义词补全并入统一 top-K 池(同罚分同量纲);低置信长尾词(lv<110)不做预测。
            for hit in customDict.t9PrefixWords(digits, 200) where hit.level >= customCompletionMinLv && ok(hit.word, hit.pinyinKey) {
                let adj = hit.level * levelW + lenBonus(hit.word) + userBonus(hit.word) - (hit.keyDigitLen - n) * penMiss
                comps.append((adj, hit.word, hit.pinyinKey))
            }
            comps.sort { $0.adj > $1.adj }
            for c in comps.prefix(completionTop) {
                put(c.word, n, n * matchW + layerExact + c.adj, c.key)
            }
        }
        // 用户自造词(耗子尾汁类,逐词组合学得):整词精确压过垃圾整句;前缀预测同词层罚分规则。
        userDict.eachPhrase { pinyin, pdigits, word, cnt in
            guard ok(word, pinyin) else { return }
            let boost = min(cnt, 5) * levelW
            if digits.hasPrefix(pdigits) {
                put(word, pdigits.count, pdigits.count * matchW + layerSentence + phraseFreq * levelW + boost + lenBonus(word), pinyin)
            } else if n >= 2 && pdigits.hasPrefix(digits) {
                let sc = n * matchW + layerExact + (phraseFreq + min(cnt, 5)) * levelW + lenBonus(word) - (pdigits.count - n) * penMiss
                put(word, n, sc, String(pinyin.prefix(n)))
            }
        }
        // 锁定态:首锁定音节单字置入(逐字组词通道:锁 hua 必能点出 花/话/华)
        if let first = lockedSylls.first {
            for (w, lv) in dict.exactWords(first) {
                put(w, first.count, first.count * matchW + layerSingle + lv * levelW + userBonus(w), first)
            }
        }
        // 永不空候选兜底:先取最长可成前缀的字/词
        if merged.isEmpty {
            var L2 = min(n, maxT9WordDigits)
            while L2 >= 1 {
                for (w, lv, key) in dict.t9ExactWords(String(chars[0..<L2])) { consider(w, L2, layerSingle, lv, key) }
                if !merged.isEmpty { break }
                L2 -= 1
            }
        }
        // 尾段半音节(如单个「9」):纯汉字续词(我/一/仪),绝不放裸字母
        // 【单键锁定修复】兜底同样尊重锁定过滤(77 锁 q 不得回吐 p/r/s 词)
        if merged.isEmpty { appendPartialChinese(digits, &merged, lockedSylls.isEmpty ? nil : ok) }
        let ranked = merged.values.sorted { $0.score > $1.score }
        // 【单字全量可达保底】整串数字码的精确候选(锁定过滤后)绝不被截出池
        return takeWithExactGuarantee(ranked, limit, t9ExactSet(digits, lockedSylls))
    }

    /// 尾段半音节的纯汉字续词:已切前缀词 +「前缀+尾段首数字字母」前缀词。绝不产出可上屏的裸字母。
    /// ok 非空时(锁定态)按锁定读音过滤(【单键锁定修复】)。
    private func appendPartialChinese(_ digits: String, _ merged: inout [String: PinyinCandidate], _ ok: ((String, String) -> Bool)? = nil) {
        let (segs, covered) = bestT9SegPartial(digits)
        let coveredPinyin = segs.joined()
        let chars = Array(digits)
        func put(_ w: String, _ mlen: Int, _ score: Int, _ py: String) {
            if w.isEmpty { return }
            if let ok, !ok(w, py) { return }
            if let old = merged[w], old.score >= score { return }
            merged[w] = PinyinCandidate(word: w, matchedLen: mlen, score: score, pinyin: py)
        }
        if !coveredPinyin.isEmpty {
            for (w, lv) in dict.exactWords(coveredPinyin) { put(w, covered, layerExact + lv*levelW + lenBonus(w) + userBonus(w), coveredPinyin) }
        }
        if covered < chars.count {
            for letter in t9[chars[covered]] ?? "" {
                let pre = coveredPinyin + String(letter)
                for (w, lv) in dict.exactWords(pre) { put(w, chars.count, layerAbbr + lv*levelW, pre) }
                for (w, lv, klen) in dict.prefixWords(pre, 30) { put(w, chars.count, layerPrefix + lv*levelW - (klen - pre.count)*15, pre) }
            }
        }
    }

    /**
     整句联想:top-K 状态 DP(每位置留 K 条不同末词路径,段内取 top-K 词)+ 用户 bigram 转移加成
     (learnPair 越用越准)+ 自定义词跳转 + 最远可达前缀。sentPen=380 电池扫描最优。
     已本地脚本验证:25 句电池无学习 14 全对(81%),学习后 19 全对(92%);热态单步 1.3ms。
     */
    /// 返回 (句子, 覆盖位数, 拼音key串)。拼音回溯:整句候选不再是"无读音黑箱"——显示拼音
    /// 跟随 #1 候选时,话那么多钱→hua'na'me'duo'qian(修 ne 幻觉:旧 bestT9SegPartial 按
    /// 音节频率瞎猜出词典中不存在的组合)。lockedSylls:锁定音节边界约束(锁 hua 排除跨界词)。
    private func sentenceT9(_ digits: String, lockedSylls: [String] = []) -> [(String, Int, String)] {
        let chars = Array(digits)
        let raw = chars.count
        if raw < 4 { return [] }
        let lockedPinyin = Array(lockedSylls.joined())
        let bounds = lockedSylls.isEmpty ? Set<Int>() : lockedBounds(lockedSylls)
        let n = min(raw, maxT9Sentence)
        // dp[i]: 末词 -> (score, j, prevWord, key)
        var dp = [[String: (Int, Int, String, String)]](repeating: [:], count: n + 1)
        dp[0][""] = (0, -1, "", "")
        for i in 1...n {
            var cand: [String: (Int, Int, String, String)] = [:]
            func relax(_ w: String, _ base: Int, _ j: Int, _ key: String) {
                // 锁定约束:词铺在拼音区间 [j, j+key.count);与锁定边界/字母冲突则弃
                if !lockedSylls.isEmpty && !lockedCompatible(w, key, j, lockedPinyin, bounds) { return }
                for (pw, st) in dp[j] {
                    var g = base
                    if !pw.isEmpty {
                        // 整句语言模型:跨词边界打分(词bigram 中心化 delta / 字bigram OOV veto)。
                        // 修"打对拼音出弱智句"(因为你搬过来→因为你包裹来);挂载前返回 0(退化原行为)。
                        g += sentenceLm.boundaryScore(pw, w)
                        let c = userDict.pairCount(pw, w)
                        if c > 0 { g += min(c, 2) * bigramW }
                    }
                    let sc = st.0 + g
                    if let old = cand[w], old.0 >= sc { continue }
                    cand[w] = (sc, j, pw, key)
                }
            }
            let lo = max(0, i - maxT9Seg)
            for j in lo..<i {
                if dp[j].isEmpty { continue }
                let segWords = topT9Words(String(chars[j..<i]))
                for (w, lv, key) in segWords { relax(w, lv - sentPen, j, key) }
                // 末段残段(i==n 且无精确词):前缀补全参与整句(youmeiy 的尾"y"→有、
                // woxiangchih 的尾"h"→吃喝),缺失位微罚(对齐 26 键 sentenceCandidate *8)。
                if i == n && j > 0 && segWords.isEmpty {
                    var comp: (String, Int, String)?
                    for hit in dict.t9PrefixWords(String(chars[j..<i]), 30) {
                        let adj = hit.level - (hit.keyDigitLen - (i - j)) * 8
                        if comp == nil || adj > comp!.1 { comp = (hit.word, adj, hit.pinyinKey) }
                    }
                    if let c = comp { relax(c.0, c.1 - sentPen, j, String(c.2.prefix(i - j))) }
                }
            }
            // 用户自造词跳转:学过的组合词(耗子尾汁)整句直达
            userDict.eachPhrase { ppy, pdigits, word, cnt in
                let len = pdigits.count
                if i >= len && !dp[i - len].isEmpty && String(chars[(i-len)..<i]) == pdigits {
                    relax(word, (phraseFreq + min(cnt, 5)) * levelW, i - len, ppy)
                }
            }
            // (custom_dict v2)自定义词已并入 topT9Words 词源以同量纲增益参与所有 span——
            // 废弃旧"freq*levelW 千倍跳转增益"(单词条 showcase 设计,海量词会摧毁整句评分体系)。
            // 【错键容忍,对齐 Gboard 插入错误解码】把第 i-1 位当"误触"跳过:状态原样前移
            // 一位、重罚 gapPen(>任何成词净收益,正常/残拼输入永不偏好跳过)。修「连敲错
            // 几个键后候选/拼音永久冻结」——垃圾段后的合法输入重新参与解码,
            // matchedLen 含跳过位 → 选词一次性吃掉误触数字。锁定前缀区内禁止跳过。
            if i - 1 >= lockedPinyin.count {
                for (pw, st) in dp[i - 1] {
                    let sc = st.0 - gapPen
                    if let old = cand[pw], old.0 >= sc { continue }
                    cand[pw] = (sc, st.1, st.2, st.3)
                }
            }
            if !cand.isEmpty {
                for (w, st) in cand.sorted(by: { $0.value.0 > $1.value.0 }).prefix(sentTopK) { dp[i][w] = st }
            }
        }
        var cov = 0
        var k = n
        while k >= 2 { if !dp[k].isEmpty { cov = k; break }; k -= 1 }
        if cov < 2 { return [] }
        // 【整句 top-2】输出最优+次优两条路径(dp 本就保留 sentTopK 状态):
        // 用户学习翻转 #1 后(什么鬼),原整句(什么会)仍作为次优候选可选(对齐搜狗整句变体)。
        var results: [(String, Int, String)] = []
        var seen = Set<String>()
        outer: for (endWord, _) in dp[cov].sorted(by: { $0.value.0 > $1.value.0 }).prefix(2) {
            var w = endWord
            var parts: [String] = []
            var keys: [String] = []
            var i = cov
            while i > 0 {
                guard let st = dp[i][w] else { continue outer }
                if !w.isEmpty { parts.append(w); keys.append(st.3) } // 空态载体(头部垃圾)不产出词
                i = st.1; w = st.2
            }
            if parts.isEmpty { continue }
            // 跳过位数 = 覆盖位数 - 各词拼音位数之和;有跳过时允许单词句
            // (77+你好:垃圾头+单词也要能出候选并吃掉垃圾),纯净路径仍要求 ≥2 词。
            let gaps = cov - keys.reduce(0) { $0 + $1.count }
            if parts.count < 2 && gaps <= 0 { continue }
            let whole = parts.reversed().joined()
            if !seen.insert(whole).inserted { continue }
            results.append((whole, cov, keys.reversed().joined()))
        }
        return results
    }

    // 段内 top-K 词(记忆化,带拼音 key 供整句回溯):top-1 会剪掉 买点/再 等同码次频词,
    // K=3 让 bigram 学习有路径可选。数字码索引直查:同码拼音全命中,长段无 DFS 截断。
    private var topWordsCache: [String: [(String, Int, String)]] = [:]
    private func topT9Words(_ seg: String) -> [(String, Int, String)] {
        if let c = topWordsCache[seg] { return c }
        var best: [String: (Int, String)] = [:]
        for (w, lv, key) in dict.t9ExactWords(seg) {
            if lv > (best[w]?.0 ?? -1) { best[w] = (lv, key) }
        }
        // 自定义词作为普通词参与整句(lv 与主词库同量纲)
        for (w, lv, key) in customDict.t9ExactWords(seg) {
            if lv > (best[w]?.0 ?? -1) { best[w] = (lv, key) }
        }
        let r = best.sorted { $0.value.0 > $1.value.0 }.prefix(sentTopK).map { ($0.key, $0.value.0, $0.value.1) }
        if topWordsCache.count > 8000 { topWordsCache.removeAll(keepingCapacity: true) }
        topWordsCache[seg] = r
        return r
    }

    /// 拼音键是否可完整切成合法音节(护栏:不合法则显示/联动会怪,拒绝入库)。
    private func allValidSyllables(_ pinyin: String) -> Bool {
        if pinyin.isEmpty { return false }
        let chars = Array(pinyin); var i = 0
        while i < chars.count {
            var matched = 0
            var L = min(dict.maxSyllableLen, chars.count - i)
            while L >= 1 { if dict.isSyllable(String(chars[i..<i+L])) { matched = L; break }; L -= 1 }
            if matched == 0 { return false }
            i += matched
        }
        return true
    }

    private func expandInitials(_ digits: String) -> [String] {
        let digitChars = Array(digits)
        var out: [String] = []
        var buf = [Character](repeating: " ", count: digitChars.count)
        func dfs(_ pos: Int) {
            if out.count >= 120 { return }
            if pos == digitChars.count { out.append(String(buf)); return }
            guard let letters = t9[digitChars[pos]] else { return }
            for c in letters {
                buf[pos] = c
                if dict.initialsHasPrefix(String(buf[0...pos])) { dfs(pos + 1) }
            }
        }
        dfs(0)
        return out
    }

    // 记忆化:短音节段跨按键/段内高频重复,缓存后长句整句/切分/候选单步<1ms。
    private var expandCache: [String: [String]] = [:]
    private func expandFullPinyin(_ digits: String) -> [String] {
        if let c = expandCache[digits] { return c }
        let r = expandFullPinyinRaw(digits)
        if expandCache.count > 4000 { expandCache.removeAll(keepingCapacity: true) }
        expandCache[digits] = r
        return r
    }

    private func expandFullPinyinRaw(_ digits: String) -> [String] {
        let digitChars = Array(digits)
        var out: [String] = []
        var buf = [Character](repeating: " ", count: digitChars.count)
        func dfs(_ pos: Int, _ sylStart: Int) {
            if out.count >= 512 { return }
            if pos == digitChars.count { out.append(String(buf)); return }
            guard let letters = t9[digitChars[pos]] else { return }
            for c in letters {
                buf[pos] = c
                let curSyl = String(buf[sylStart...pos])
                if dict.isSyllablePrefix(curSyl) {
                    dfs(pos + 1, sylStart)
                    if dict.isSyllable(curSyl) { dfs(pos + 1, pos + 1) }
                }
            }
        }
        dfs(0, 0)
        return out
    }

    // MARK: 完整九宫格:锁定段+待定段(与安卓同构,已本地脚本验证)
    /// 拼音选择器选项:整段完整音节全部保留、排最前(修「qiao 打不出来」:低频长音节被 limit
    /// 按频率截断,用户无从细化),短前导按(频率,段长)补足。
    func t9LeadingOptions(_ digits: String, maxSeg: Int = 3, limit: Int = 8) -> [String] {
        guard dict.isReady, !digits.isEmpty else { return [] }
        let chars = Array(digits)
        let fullLen = min(maxSeg, chars.count)
        var seen = Set<String>()
        var fulls: [(String, Int)] = []
        var shorts: [(String, Int, Int)] = []
        var L = fullLen
        while L >= 1 {
            for exp in expandFullPinyin(String(chars[0..<L])) where dict.isSyllable(exp) && seen.insert(exp).inserted {
                let lv = dict.exactWords(exp).first?.1 ?? -1
                if L == fullLen { fulls.append((exp, lv)) } else { shorts.append((exp, L, lv)) }
            }
            L -= 1
        }
        if let letters = t9[chars[0]] {
            for c in letters {
                let s = String(c)
                if dict.isSyllablePrefix(s) && seen.insert(s).inserted { shorts.append((s, 1, -2)) }
            }
        }
        fulls.sort { $0.1 > $1.1 }
        shorts.sort { $0.2 != $1.2 ? $0.2 > $1.2 : $0.1 > $1.1 }
        return Array((fulls.map { $0.0 } + shorts.map { $0.0 }).prefix(limit))
    }

    /// 锁定拼音前缀 + 待定段候选(只展开待定段前 maxSyllableLen 位)。
    func candidatesT9Locked(_ lockedPinyin: String, _ pending: String, limit: Int = PinyinEngine.candLimit) -> [PinyinCandidate] {
        guard dict.isReady else { return [] }
        // 待定段能完整切分 → 从「锁定拼音+最优待定拼音」用 26 键 candidates() 生成(与显示一一对应)
        if pending.isEmpty { return candidates(lockedPinyin, limit: limit) }
        if let seg = bestT9Seg(pending) { return candidates(lockedPinyin + seg.joined(), limit: limit) }
        var merged: [String: PinyinCandidate] = [:]
        func put(_ w: String, _ mlen: Int, _ score: Int) {
            if let old = merged[w], old.score >= score { return }
            merged[w] = PinyinCandidate(word: w, matchedLen: mlen, score: score)
        }
        if pending.isEmpty {
            for (w, lv) in dict.exactWords(lockedPinyin) { put(w, lockedPinyin.count, layerExact + lv*levelW + lenBonus(w) + userBonus(w)) }
            for (w, lv, klen) in dict.prefixWords(lockedPinyin, 100) { put(w, lockedPinyin.count, layerPrefix + lv*levelW - (klen - lockedPinyin.count)*15) }
        } else {
            let pchars = Array(pending)
            let win = String(pchars[0..<min(pchars.count, dict.maxSyllableLen)])
            for exp in expandFullPinyin(win) where dict.isSyllablePrefix(exp) {
                let key = lockedPinyin + exp
                for (w, lv) in dict.exactWords(key) { put(w, key.count, layerExact + lv*levelW + lenBonus(w) + userBonus(w)) }
                for (w, lv, klen) in dict.prefixWords(key, 100) { put(w, key.count, layerPrefix + lv*levelW - (klen - key.count)*15) }
            }
        }
        if merged.isEmpty { let base = lockedPinyin.isEmpty ? pending : lockedPinyin; if let f = base.first { put(String(f), 1, 0) } }
        return Array(merged.values.sorted { $0.score > $1.score }.prefix(limit))
    }

    private lazy var letter2digit: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (d, letters) in t9 { for c in letters { m[c] = d } }
        return m
    }()

    /// 音节字母串 → T9 数字串(逐音节删除退回待定数字)。
    func syllableToDigits(_ syl: String) -> String { String(syl.map { letter2digit[$0] ?? $0 }) }

    /// DP 切分,返回 (音节列表, 已完整切分的最长前缀长度)。covered==n 表示整串可切。
    private func bestT9SegPartial(_ digits: String) -> ([String], Int) {
        guard dict.isReady, !digits.isEmpty else { return ([], 0) }
        let chars = Array(digits)
        let n = chars.count
        var dp = [Int](repeating: Int.min, count: n + 1); dp[0] = 0
        var backLen = [Int](repeating: 0, count: n + 1)
        var backSyl = [String?](repeating: nil, count: n + 1)
        for i in 1...n {
            let maxL = min(dict.maxSyllableLen, i)
            for L in 1...maxL {
                if dp[i - L] == Int.min { continue }
                let seg = String(chars[(i - L)..<i])
                var bestSyl: String? = nil; var bestLv = -1
                for exp in expandFullPinyin(seg) where dict.isSyllable(exp) {
                    let lv = dict.exactWords(exp).first?.1 ?? 0
                    if lv > bestLv { bestLv = lv; bestSyl = exp }
                }
                guard let bs = bestSyl else { continue }
                let score = dp[i - L] + bestLv - segPenalty
                if score > dp[i] { dp[i] = score; backLen[i] = L; backSyl[i] = bs }
            }
        }
        var covered = 0
        for i in stride(from: n, through: 0, by: -1) where dp[i] != Int.min { covered = i; break }
        var parts: [String] = []; var i = covered
        while i > 0 { parts.append(backSyl[i]!); i -= backLen[i] }
        return (parts.reversed(), covered)
    }

    /// T9 最优拼音切分(整串可切时返回,否则 null)。
    func bestT9Seg(_ digits: String) -> [String]? {
        let (segs, covered) = bestT9SegPartial(digits)
        return (covered == digits.count && covered > 0) ? segs : nil
    }

    /// 某数字的默认拼音字母(残段显示用):取第一个合法音节前缀字母。
    private func defaultLetter(_ d: Character) -> Character {
        for c in t9[d] ?? "" where dict.isSyllablePrefix(String(c)) { return c }
        return t9[d]?.first ?? d
    }

    /// 把已知合法拼音贪心最长切分成音节(wanshan→wan'shan、ceshi→ce'shi)。
    private func splitKnownPinyin(_ py: String) -> String {
        if py.isEmpty { return py }
        let chars = Array(py); let n = chars.count
        var parts: [String] = []; var i = 0
        while i < n {
            var matched = 0
            var L = min(dict.maxSyllableLen, n - i)
            while L >= 1 {
                if dict.isSyllable(String(chars[i..<i+L])) { matched = L; break }
                L -= 1
            }
            if matched == 0 { parts.append(String(chars[i...])); break }
            parts.append(String(chars[i..<i+matched])); i += matched
        }
        return parts.joined(separator: "'")
    }

    // 小缓存:同一(数字串,锁定栈)的显示与候选复用同一次计算,避免重复;学习后整体失效。
    private var t9CacheKey: String?
    private var t9CacheVal: [PinyinCandidate] = []
    private func t9Compute(_ digits: String, _ lockedSylls: [String] = []) -> [PinyinCandidate] {
        let key = lockedSylls.isEmpty ? digits : digits + "\u{1}" + lockedSylls.joined(separator: "'")
        if key == t9CacheKey { return t9CacheVal }
        let r = candidatesT9(digits, limit: t9Pool, lockedSylls: lockedSylls)
        t9CacheKey = key; t9CacheVal = r
        return r
    }

    /// T9 候选(多展开算法,准确出多音节整词如 完善/要钱)。显示跟随 #1 候选读音。
    func candidatesForT9(_ digits: String, limit: Int = PinyinEngine.candLimit) -> [PinyinCandidate] {
        dict.isReady ? takeWithExactGuarantee(t9Compute(digits), limit, t9ExactSet(digits, [])) : []
    }

    /// T9 识别拼音显示串:跟随 #1 候选读音,按**字对齐**切分(华纳→hua'na 而非 huan'a,
    /// 话那么多钱→hua'na'me'duo'qian),保证与首候选严格对应且无幻觉音节。
    func t9DisplayPinyin(_ digits: String) -> String {
        guard dict.isReady, !digits.isEmpty else { return digits }
        if let top = t9Compute(digits).first, !top.pinyin.isEmpty { return displaySplit(top.word, top.pinyin) }
        let (segs, covered) = bestT9SegPartial(digits)
        var parts = segs
        let chars = Array(digits)
        for idx in covered..<chars.count { parts.append(String(defaultLetter(chars[idx]))) }
        return parts.joined(separator: "'")
    }

    /// 整句(作用于拼音串,与 sentenceT9 同款 segPenalty 抗碎切)。锁定态用:尊重锁定读音又不碎成单字。
    private func sentenceFromPinyin(_ pinyin: String) -> PinyinCandidate? {
        let chars = Array(pinyin); let n = chars.count
        if n < 2 { return nil }
        var dp = [Int](repeating: Int.min, count: n + 1); dp[0] = 0
        var from = [Int](repeating: -1, count: n + 1)
        var word = [String?](repeating: nil, count: n + 1)
        for i in 1...n {
            let lo = max(0, i - dict.maxSyllableLen * 4)
            for j in lo..<i {
                if dp[j] == Int.min { continue }
                guard let best = dict.bestWord(String(chars[j..<i])) else { continue }
                let gain = best.1 - segPenalty
                if dp[j] + gain > dp[i] { dp[i] = dp[j] + gain; from[i] = j; word[i] = best.0 }
            }
        }
        var end = n
        while end > 0 && dp[end] == Int.min { end -= 1 }
        if end < 2 || from[end] < 0 { return nil }
        var parts: [String] = []; var cur = end
        while cur > 0 && from[cur] >= 0 { parts.append(word[cur]!); cur = from[cur] }
        if cur != 0 || parts.count < 2 { return nil }
        return PinyinCandidate(word: parts.reversed().joined(), matchedLen: end, score: end * matchW + layerSentence, pinyin: String(chars[0..<end]))
    }

    /// 锁定态候选(切分歧义根治重写,镜像安卓):不再"锁定拼音串+贪心剩余段重查",而是在
    /// **数字空间全量检索**(与非锁定态同一通道 candidatesT9)+ 锁定音节边界过滤。
    /// 锁 hua 后:换@huan 被边界过滤掉,话那么多钱@hua... 保留 → 候选与用户点选意图一致。
    func candidatesForT9Filtered(_ digits: String, _ lockedPinyin: String, limit: Int = PinyinEngine.candLimit, lockedSylls: [String]? = nil) -> [PinyinCandidate] {
        if !dict.isReady { return [] }
        if lockedPinyin.isEmpty { return candidatesForT9(digits, limit: limit) }
        let locked = lockedSylls ?? greedySylls(lockedPinyin)
        let r = takeWithExactGuarantee(t9Compute(digits, locked), limit, t9ExactSet(digits, locked))
        // 极端情况(锁定边界过滤后全空):回退 26 键通道保证候选非空
        if r.isEmpty { return candidates(lockedPinyin, limit: limit) }
        return r
    }

    /// 贪心切音节(仅作旧调用降级;正常路径 Controller 直接传锁定栈)。
    private func greedySylls(_ py: String) -> [String] {
        let chars = Array(py); let n = chars.count
        var parts: [String] = []; var i = 0
        while i < n {
            var m = 0
            var L = min(dict.maxSyllableLen, n - i)
            while L >= 1 {
                if dict.isSyllable(String(chars[i..<i+L])) { m = L; break }
                L -= 1
            }
            if m == 0 { break }
            parts.append(String(chars[i..<i+m])); i += m
        }
        return parts
    }

    /// 识别拼音显示(带锁定):跟随过滤后 #1 候选读音(字对齐切分);无则锁定音节 + 剩余段部分显示。
    func t9DisplayFiltered(_ digits: String, _ lockedPinyin: String, lockedSylls: [String]? = nil) -> String {
        guard dict.isReady, !digits.isEmpty else { return digits }
        if lockedPinyin.isEmpty { return t9DisplayPinyin(digits) }
        let locked = lockedSylls ?? greedySylls(lockedPinyin)
        // 【单键锁定修复】全部数字都被锁定覆盖:组合区忠实显示用户点选(锁 d 显示 d,
        // 而非 #1 补全候选的完整读音 de——用户显式点选优先于机器预测)。
        if lockedPinyin.count >= digits.count { return locked.joined(separator: "'") }
        if let top = candidatesForT9Filtered(digits, lockedPinyin, limit: 1, lockedSylls: locked).first, !top.pinyin.isEmpty {
            return displaySplit(top.word, top.pinyin)
        }
        let dchars = Array(digits)
        let remain = lockedPinyin.count < digits.count ? String(dchars[lockedPinyin.count...]) : ""
        let remainDisp = remain.isEmpty ? "" : t9DisplayPinyin(remain)
        return [locked.joined(separator: "'"), remainDisp].filter { !$0.isEmpty }.joined(separator: "'")
    }

    /// 是否合法拼音音节(拼音选择器高亮判定用)。
    func isSyllable(_ s: String) -> Bool { dict.isSyllable(s) }

    /// 数字段最优切分的第一个音节(选择器高亮兜底)。
    func t9FirstSyllable(_ digits: String) -> String {
        guard dict.isReady, !digits.isEmpty else { return "" }
        if let f = bestT9SegPartial(digits).0.first { return f }
        return String(defaultLetter(Array(digits)[0]))
    }
}
