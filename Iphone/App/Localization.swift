import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
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
    // Russian is last on purpose: the app is aimed at an international
    // audience first (owner's decision, Sep 2026).
    case russian = "ru"

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

/// Display order for the language lists (first-launch overlay + settings
/// picker). Device language and IP-country language float to the top;
/// everything else keeps the enum order (Russian stays last by design).
enum LanguageOrdering {
    /// Country code (e.g. "TH", "DE") → the app language most likely wanted
    /// there. Only countries whose language the app actually ships.
    static func language(forCountry code: String) -> AppLanguage? {
        switch code.uppercased() {
        case "US", "GB", "AU", "CA", "NZ", "IE", "SG", "PH", "IN": return .english
        case "ES", "MX", "AR", "CL", "CO", "PE": return .spanish
        case "DE", "AT", "CH", "LI": return .german
        case "FR", "BE", "LU", "MC": return .french
        case "IT", "SM", "VA": return .italian
        case "BR", "PT": return .portuguese
        case "JP": return .japanese
        case "CN", "HK", "TW": return .chinese
        case "KR", "KP": return .korean
        case "SA", "AE", "EG", "QA", "KW", "OM", "BH", "JO": return .arabic
        case "IN": return .hindi
        case "TH": return .thai
        case "TR": return .turkish
        case "PL": return .polish
        case "NL": return .dutch
        case "VN": return .vietnamese
        case "RU", "BY", "KZ", "KG": return .russian
        default: return nil
        }
    }

    /// Matches a device language identifier ("pt-BR", "zh-Hans-CN", "en")
    /// against the app's languages. Longest-prefix wins so "pt-BR" beats
    /// a bare "pt" and "zh-Hans" is recognized before plain "zh".
    static func language(forDeviceIdentifier identifier: String) -> AppLanguage? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        var best: (AppLanguage, Int)?
        for language in AppLanguage.allCases {
            let raw = language.rawValue.lowercased()
            if normalized == raw {
                return language
            }
            if normalized.hasPrefix(raw + "-"), let b = best, b.1 >= raw.count { continue }
            if normalized.hasPrefix(raw + "-") || normalized.hasPrefix(raw) && !normalized.contains("-") {
                if raw.count > (best?.1 ?? 0) { best = (language, raw.count) }
            }
        }
        return best?.0
    }

    /// The list the pickers render: pinned entries first (device language,
    /// then IP-country language, no duplicates), then a divider, then the
    /// rest in enum order (Russian last).
    static func displayOrder(deviceLanguages: [String], ipCountry: String?) -> (pinned: [AppLanguage], rest: [AppLanguage]) {
        var pinned: [AppLanguage] = []
        for id in deviceLanguages {
            if let l = language(forDeviceIdentifier: id), !pinned.contains(l) {
                pinned.append(l)
                break
            }
        }
        if let code = ipCountry, let l = language(forCountry: code), !pinned.contains(l) {
            pinned.append(l)
        }
        let rest = AppLanguage.allCases.filter { !pinned.contains($0) }
        return (pinned, rest)
    }
}
