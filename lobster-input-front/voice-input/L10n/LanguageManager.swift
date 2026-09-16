/// LanguageManager.swift
/// App 内语言切换管理器，支持运行时切换，所有 UI 自动响应。
import SwiftUI
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case zh = "zh"
    case zhHant = "zh-Hant"
    case yue = "yue"
    case en = "en"
    case ru = "ru"
    case ko = "ko"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zh:     return "简体中文"
        case .zhHant: return "繁體中文"
        case .yue:    return "粵語（廣東省版）"
        case .en:     return "English"
        case .ru:     return "Русский"
        case .ko:     return "한국어"
        }
    }

    /// 对应的 Locale，用于日期格式化等本地化操作
    var locale: Locale {
        switch self {
        case .zh:     return Locale(identifier: "zh_CN")
        case .zhHant: return Locale(identifier: "zh_TW")
        case .yue:    return Locale(identifier: "zh_HK")
        case .en:     return Locale(identifier: "en_US")
        case .ru:     return Locale(identifier: "ru_RU")
        case .ko:     return Locale(identifier: "ko_KR")
        }
    }
}

final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var current: AppLanguage {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "app_language")
        }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "app_language"),
           let lang = AppLanguage(rawValue: saved) {
            self.current = lang
        } else {
            self.current = Self.detectSystemLanguage()
            UserDefaults.standard.set(self.current.rawValue, forKey: "app_language")
        }
    }

    /// 检测系统首选语言，匹配 App 支持的语言列表；不匹配则回退英语
    private static func detectSystemLanguage() -> AppLanguage {
        for preferred in Locale.preferredLanguages {
            let lower = preferred.lowercased()
            if lower.hasPrefix("yue") {
                return .yue
            }
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") {
                return .zhHant
            }
            if lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
                return .yue
            }
            if lower.hasPrefix("zh") {
                return .zh
            }
            if lower.hasPrefix("ko") {
                return .ko
            }
            if lower.hasPrefix("ru") {
                return .ru
            }
            if lower.hasPrefix("en") {
                return .en
            }
        }
        return .en
    }
}
