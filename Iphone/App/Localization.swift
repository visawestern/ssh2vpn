import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"
    case spanish = "es"
    case german = "de"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt-BR"
    case japanese = "ja"
    case chinese = "zh-Hans"
    case korean = "ko"
    case arabic = "ar"
    case hindi = "hi"
    case thai = "th"
    case turkish = "tr"
    case polish = "pl"
    case dutch = "nl"
    case vietnamese = "vi"

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .english: "🇬🇧"
        case .russian: "🇷🇺"
        case .spanish: "🇪🇸"
        case .german: "🇩🇪"
        case .french: "🇫🇷"
        case .italian: "🇮🇹"
        case .portuguese: "🇧🇷"
        case .japanese: "🇯🇵"
        case .chinese: "🇨🇳"
        case .korean: "🇰🇷"
        case .arabic: "🇸🇦"
        case .hindi: "🇮🇳"
        case .thai: "🇹🇭"
        case .turkish: "🇹🇷"
        case .polish: "🇵🇱"
        case .dutch: "🇳🇱"
        case .vietnamese: "🇻🇳"
        }
    }

    var title: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .french: "Français"
        case .italian: "Italiano"
        case .portuguese: "Português"
        case .japanese: "日本語"
        case .chinese: "简体中文"
        case .korean: "한국어"
        case .arabic: "العربية"
        case .hindi: "हिन्दी"
        case .thai: "ไทย"
        case .turkish: "Türkçe"
        case .polish: "Polski"
        case .dutch: "Nederlands"
        case .vietnamese: "Tiếng Việt"
        }
    }
}

enum LanguageStore {
    private static let key = "selectedLanguage"
    static var current: AppLanguage? {
        get { UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: key) }
    }
}
