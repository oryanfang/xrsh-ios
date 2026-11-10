import Foundation

/// App 自己的语言设置（和系统语言分开，设置里可以随时切换）
nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en, ja, ru

    var id: String { rawValue }

    static let storageKey = "appLanguage"

    /// 当前选的语言（可能是"跟随系统"）
    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// 实际生效的语言：跟随系统时，系统是中文、日语、俄语就用对应的，否则用英文
    static var effective: AppLanguage {
        let selected = selected
        guard selected == .system else { return selected }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") { return .zh }
        if preferred.hasPrefix("ja") { return .ja }
        if preferred.hasPrefix("ru") { return .ru }
        return .en
    }

    /// 给日期等格式化用的 Locale
    static var locale: Locale {
        switch effective {
        case .zh: Locale(identifier: "zh_CN")
        case .ja: Locale(identifier: "ja_JP")
        case .ru: Locale(identifier: "ru_RU")
        default: Locale(identifier: "en_US")
        }
    }

    /// 告诉 AI 用哪种语言回答
    var englishName: String {
        switch self {
        case .zh: "Chinese"
        case .ja: "Japanese"
        case .ru: "Russian"
        default: "English"
        }
    }

    /// 语言选项在设置里显示的名字（每种语言用它自己的写法，方便认出来）
    var displayName: String {
        switch self {
        case .system: tr("跟随系统")
        case .zh: "中文"
        case .en: "English"
        case .ja: "日本語"
        case .ru: "Русский"
        }
    }
}

/// 翻译：参数是中文原文。日语、俄语缺的句子先用英文，英文也没有就原样显示中文。
/// 句子里的变量用 {0}、{1} 占位，例如 tr("已扫描 {0}/{1}", done, total)
nonisolated func tr(_ key: String, _ arguments: Any...) -> String {
    var text = key
    switch AppLanguage.effective {
    case .en:
        text = EnglishStrings.table[key] ?? key
    case .ja:
        text = JapaneseStrings.table[key] ?? EnglishStrings.table[key] ?? key
    case .ru:
        text = RussianStrings.table[key] ?? EnglishStrings.table[key] ?? key
    default:
        break
    }
    for (index, argument) in arguments.enumerated() {
        text = text.replacingOccurrences(of: "{\(index)}", with: "\(argument)")
    }
    return text
}
