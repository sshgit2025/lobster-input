import Foundation

/// 将 App 主进程同步的热词写入键盘用户词典(App Group,与 [UserDictionary] 同域)。
enum HotwordDictionaryBridge {

    static let prefsKey = "ime_hotwords_cache"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard
    }

    static func persistHotwords(_ words: [String]) {
        let cleaned = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = Array(Set(cleaned))
        defaults.set(unique.joined(separator: "\n"), forKey: prefsKey)
    }

    static func readHotwords() -> [String] {
        guard let raw = defaults.string(forKey: prefsKey), !raw.isEmpty else { return [] }
        return raw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func importInto(_ userDict: UserDictionary, baseBoost: Int = 8) {
        for word in readHotwords() {
            for _ in 0..<baseBoost { userDict.learn(word) }
        }
    }
}
