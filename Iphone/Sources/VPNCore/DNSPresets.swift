import Foundation

/// Curated public DNS presets. Every entry uses well-known anycast
/// resolvers; the filter class groups them (no filter / security / ads /
/// family) and the description says exactly WHAT that resolver blocks.
/// Users tap one in the DNS settings screen (or keep typing their own —
/// the manual fields stay editable).
public struct DNSPreset: Equatable, Sendable, Identifiable {
    public enum Filter: String, Sendable, CaseIterable {
        /// No filtering — plain fast resolution.
        case none
        /// Blocks malicious/phishing domains.
        case malware
        /// Blocks ads, trackers and malware domains.
        case ads
        /// Blocks adult content (+ malware on most presets).
        case family
    }

    public let id: String
    public let name: String
    public let primary: String
    public let secondary: String
    public let filter: Filter
    /// What this resolver blocks (English).
    public let descriptionEN: String
    /// What this resolver blocks (Russian).
    public let descriptionRU: String

    public init(id: String, name: String, primary: String, secondary: String,
                filter: Filter, descriptionEN: String, descriptionRU: String) {
        self.id = id
        self.name = name
        self.primary = primary
        self.secondary = secondary
        self.filter = filter
        self.descriptionEN = descriptionEN
        self.descriptionRU = descriptionRU
    }

    /// True when the settings fields point at this exact preset.
    public func matches(primary: String, secondary: String) -> Bool {
        self.primary == primary.trimmingCharacters(in: .whitespaces)
            && self.secondary == secondary.trimmingCharacters(in: .whitespaces)
    }

    /// Localized blocking description (RU when requested, EN otherwise —
    /// mirrors the Copy system's English fallback for other languages).
    public func description(forRussian: Bool) -> String {
        forRussian ? descriptionRU : descriptionEN
    }
}

public enum DNSPresets {
    /// The curated catalog, grouped by filter class. Display order within
    /// each group: most widely used first.
    public static let all: [DNSPreset] = [
        // MARK: No filtering
        DNSPreset(id: "cloudflare", name: "Cloudflare", primary: "1.1.1.1", secondary: "1.0.0.1", filter: .none,
                  descriptionEN: "The fastest public resolver. No content filtering; query logs deleted after 24h.",
                  descriptionRU: "Самый быстрый публичный резолвер. Без фильтрации; логи запросов удаляются через 24 часа."),
        DNSPreset(id: "google", name: "Google Public DNS", primary: "8.8.8.8", secondary: "8.8.4.4", filter: .none,
                  descriptionEN: "Google's global anycast. No content filtering, standard Google privacy policy.",
                  descriptionRU: "Глобальный anycast от Google. Без фильтрации контента, стандартная политика конфиденциальности Google."),
        DNSPreset(id: "adguard-unfiltered", name: "AdGuard Unfiltered", primary: "94.140.14.140", secondary: "94.140.14.141", filter: .none,
                  descriptionEN: "AdGuard's plain resolver: no blocking at all, privacy-first, no DNS logs.",
                  descriptionRU: "Обычный резолвер AdGuard: никаких блокировок, приватность, логи DNS не ведутся."),
        DNSPreset(id: "yandex", name: "Yandex DNS", primary: "77.88.8.8", secondary: "77.88.8.1", filter: .none,
                  descriptionEN: "Fastest in Russia/CIS region. No filtering.",
                  descriptionRU: "Самый быстрый в России и СНГ. Без фильтрации."),
        DNSPreset(id: "dns-watch", name: "DNS.Watch", primary: "84.200.69.80", secondary: "84.200.70.40", filter: .none,
                  descriptionEN: "German, privacy-friendly, no filtering, no logs.",
                  descriptionRU: "Немецкий, дружелюбный к приватности, без фильтров и логов."),
        DNSPreset(id: "verisign", name: "Verisign", primary: "64.6.64.6", secondary: "64.6.65.6", filter: .none,
                  descriptionEN: "Stable US infrastructure. No filtering.",
                  descriptionRU: "Стабильная инфраструктура США. Без фильтрации."),
        DNSPreset(id: "level3", name: "Level3 / Lumen", primary: "4.2.2.1", secondary: "4.2.2.2", filter: .none,
                  descriptionEN: "Classic veteran resolver. No filtering.",
                  descriptionRU: "Классический ветеран среди резолверов. Без фильтрации."),

        // MARK: Security (malware / phishing)
        DNSPreset(id: "quad9", name: "Quad9", primary: "9.9.9.9", secondary: "149.112.112.112", filter: .malware,
                  descriptionEN: "Blocks malware, phishing and botnet command-and-control domains. Swiss non-profit; does not log IP addresses.",
                  descriptionRU: "Блокирует вредоносные, фишинговые домены и управляющие центры ботнетов. Швейцарский некоммерческий сервис; IP-адреса не логируются."),
        DNSPreset(id: "cloudflare-malware", name: "Cloudflare Security", primary: "1.1.1.2", secondary: "1.0.0.2", filter: .malware,
                  descriptionEN: "Cloudflare speed plus a blocklist of malware and phishing domains.",
                  descriptionRU: "Скорость Cloudflare плюс блок-лист вредоносных и фишинговых доменов."),
        DNSPreset(id: "dns0-zero", name: "dns0.eu ZERO", primary: "193.110.81.0", secondary: "185.253.5.0", filter: .malware,
                  descriptionEN: "EU non-profit. Blocks malware and phishing domains.",
                  descriptionRU: "Европейский некоммерческий сервис. Блокирует вирусные и фишинговые домены."),
        DNSPreset(id: "opendns", name: "OpenDNS (Cisco)", primary: "208.67.222.222", secondary: "208.67.220.220", filter: .malware,
                  descriptionEN: "Cisco's resolver. Blocks phishing and identity-theft sites.",
                  descriptionRU: "Резолвер Cisco. Блокирует фишинг и сайты для кражи личных данных."),
        DNSPreset(id: "comodo", name: "Comodo Secure DNS", primary: "8.26.56.26", secondary: "8.20.247.20", filter: .malware,
                  descriptionEN: "Blocks malicious and phishing domains.",
                  descriptionRU: "Блокирует вредоносные и фишинговые домены."),

        // MARK: Ad blocking
        DNSPreset(id: "adguard", name: "AdGuard DNS", primary: "94.140.14.14", secondary: "94.140.15.15", filter: .ads,
                  descriptionEN: "Blocks ads, trackers, analytics beacons and malware domains. Some sites may break (anti-adblock walls).",
                  descriptionRU: "Блокирует рекламу, трекеры, аналитические маячки и вредоносные домены. Некоторые сайты могут работать некорректно (анти-адблок)."),

        // MARK: Family safe
        DNSPreset(id: "cloudflare-family", name: "Cloudflare Family", primary: "1.1.1.3", secondary: "1.0.0.3", filter: .family,
                  descriptionEN: "Blocks adult (18+) content and malware domains.",
                  descriptionRU: "Блокирует контент 18+ и вредоносные домены."),
        DNSPreset(id: "adguard-family", name: "AdGuard Family", primary: "94.140.14.15", secondary: "94.140.15.16", filter: .family,
                  descriptionEN: "Blocks adult content, ads, trackers and malware; enforces safe search in engines.",
                  descriptionRU: "Блокирует контент 18+, рекламу, трекеры и вирусы; принудительно включает безопасный поиск."),
        DNSPreset(id: "cleanbrowsing-family", name: "CleanBrowsing Family", primary: "185.228.168.168", secondary: "185.228.169.168", filter: .family,
                  descriptionEN: "Strict mode: blocks adult content, malware and phishing; forces safe search on Google/Bing/Yandex.",
                  descriptionRU: "Строгий режим: блокирует контент 18+, вирусы и фишинг; принудительный безопасный поиск в Google/Bing/Яндексе."),
        DNSPreset(id: "cleanbrowsing-adult", name: "CleanBrowsing Adult", primary: "185.228.168.10", secondary: "185.228.169.11", filter: .family,
                  descriptionEN: "Blocks only adult (18+) sites; everything else is allowed.",
                  descriptionRU: "Блокирует только сайты 18+; всё остальное — без ограничений."),
        DNSPreset(id: "opendns-familyshield", name: "OpenDNS FamilyShield", primary: "208.67.222.123", secondary: "208.67.220.123", filter: .family,
                  descriptionEN: "Preconfigured: blocks adult content and phishing. Nothing to set up.",
                  descriptionRU: "Готовая настройка: блокирует контент 18+ и фишинг. Ничего настраивать не нужно."),
        DNSPreset(id: "yandex-family", name: "Yandex Family", primary: "77.88.8.88", secondary: "77.88.8.2", filter: .family,
                  descriptionEN: "Blocks adult content and suggestive pages; Russian infrastructure.",
                  descriptionRU: "Блокирует контент 18+ и «сомнительные» страницы; инфраструктура Яндекса."),
    ]

    /// Presets of one filter class (display order kept).
    public static func presets(matching filter: DNSPreset.Filter) -> [DNSPreset] {
        all.filter { $0.filter == filter }
    }
}
