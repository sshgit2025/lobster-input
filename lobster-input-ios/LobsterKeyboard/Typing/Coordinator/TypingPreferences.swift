import Foundation

/// 打字键盘用户偏好(中/英、布局、是否记住键盘模式)。
final class TypingPreferences {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard) {
        self.defaults = defaults
    }

    var chineseMode: Bool {
        get {
            if defaults.object(forKey: Keys.chinese) == nil { return true }
            return defaults.bool(forKey: Keys.chinese)
        }
        set { defaults.set(newValue, forKey: Keys.chinese) }
    }

    var nineGrid: Bool {
        get { defaults.bool(forKey: Keys.nineGrid) }
        set { defaults.set(newValue, forKey: Keys.nineGrid) }
    }

    /// 输入语种 code(zh/en/ru/ko)。缺省从旧 chineseMode 偏好推导(平滑升级)。
    var inputLang: String {
        get { defaults.string(forKey: Keys.inputLang) ?? (chineseMode ? "zh" : "en") }
        set { defaults.set(newValue, forKey: Keys.inputLang) }
    }

    /// 上次已知的 App 界面语言组(zhen/ru/ko),用于跨组切换检测。
    var langGroup: String? {
        get { defaults.string(forKey: Keys.langGroup) }
        set { defaults.set(newValue, forKey: Keys.langGroup) }
    }

    /// 跨输入框是否保持键盘模式(默认 false:每次聚焦回语音)。
    var rememberTypingMode: Bool {
        get { defaults.bool(forKey: Keys.rememberMode) }
        set { defaults.set(newValue, forKey: Keys.rememberMode) }
    }

    /// 记住上次是语音还是键盘模式(默认 false=语音;手动切换后持久化,下次拉起恢复)。
    var lastModeKeyboard: Bool {
        get { defaults.bool(forKey: Keys.lastModeKeyboard) }
        set { defaults.set(newValue, forKey: Keys.lastModeKeyboard) }
    }

    /// 最近使用符号(最多 16,最新在前;键盘/语音符号板共用)。
    func recentSymbols() -> [String] {
        defaults.stringArray(forKey: Keys.recentSymbols) ?? []
    }

    func recordRecentSymbol(_ symbol: String) {
        guard !symbol.isEmpty else { return }
        var list = recentSymbols()
        list.removeAll { $0 == symbol }
        list.insert(symbol, at: 0)
        if list.count > 16 { list = Array(list.prefix(16)) }
        defaults.set(list, forKey: Keys.recentSymbols)
    }

    /// 由模糊音/纠错开关组装引擎配置。键名与安卓一致(App Group 共享,App 设置页写入)。
    func fuzzySettings() -> PinyinFuzzy.Settings {
        func f(_ k: String) -> Bool { defaults.bool(forKey: k) }
        return PinyinFuzzy.Settings(
            zZh: f(Keys.fuzzyZZh), cCh: f(Keys.fuzzyCCh), sSh: f(Keys.fuzzySSh),
            lN: f(Keys.fuzzyLN), fH: f(Keys.fuzzyFH), rL: f(Keys.fuzzyRL),
            anAng: f(Keys.fuzzyAnAng), enEng: f(Keys.fuzzyEnEng), inIng: f(Keys.fuzzyInIng),
            // 纠错默认开(候选不足时才兜底,不污染正常输入)
            correction: defaults.object(forKey: Keys.correction) == nil ? true : defaults.bool(forKey: Keys.correction)
        )
    }

    private enum Keys {
        static let chinese = "ime_typing_chinese_mode"
        static let inputLang = "ime_typing_input_lang"
        static let langGroup = "ime_typing_lang_group"
        static let nineGrid = "ime_typing_ninegrid"
        static let rememberMode = "ime_typing_remember_mode"
        static let lastModeKeyboard = "ime_typing_last_mode_keyboard"
        static let recentSymbols = "ime_recent_symbol"
        static let fuzzyZZh = "ime_fuzzy_zzh"
        static let fuzzyCCh = "ime_fuzzy_cch"
        static let fuzzySSh = "ime_fuzzy_ssh"
        static let fuzzyLN = "ime_fuzzy_ln"
        static let fuzzyFH = "ime_fuzzy_fh"
        static let fuzzyRL = "ime_fuzzy_rl"
        static let fuzzyAnAng = "ime_fuzzy_anang"
        static let fuzzyEnEng = "ime_fuzzy_eneng"
        static let fuzzyInIng = "ime_fuzzy_ining"
        static let correction = "ime_fuzzy_correction"
    }
}
