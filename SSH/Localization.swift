import Foundation

/// App 自己的语言设置（和系统语言分开，设置里可以随时切换）
nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en

    var id: String { rawValue }

    static let storageKey = "appLanguage"

    /// 当前选的语言（可能是"跟随系统"）
    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// 实际生效的语言：跟随系统时，系统是中文就用中文，否则用英文
    static var effective: AppLanguage {
        let selected = selected
        guard selected == .system else { return selected }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .zh : .en
    }

    /// 给日期等格式化用的 Locale
    static var locale: Locale {
        Locale(identifier: effective == .zh ? "zh_CN" : "en_US")
    }

    /// 语言选项在设置里显示的名字（每种语言用它自己的写法，方便认出来）
    var displayName: String {
        switch self {
        case .system: tr("跟随系统")
        case .zh: "中文"
        case .en: "English"
        }
    }
}

/// 翻译：参数是中文原文。选了英文就返回英文，没有对应翻译就原样返回中文。
/// 句子里的变量用 {0}、{1} 占位，例如 tr("已扫描 {0}/{1}", done, total)
nonisolated func tr(_ key: String, _ arguments: Any...) -> String {
    var text = key
    if AppLanguage.effective == .en, let english = EnglishStrings.table[key] {
        text = english
    }
    for (index, argument) in arguments.enumerated() {
        text = text.replacingOccurrences(of: "{\(index)}", with: "\(argument)")
    }
    return text
}
