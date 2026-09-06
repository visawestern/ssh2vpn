import Foundation

/// Curated public DNS presets. Every entry uses well-known anycast
/// resolvers. Each preset carries SEVERAL capability chips (what it blocks)
/// — e.g. family presets also block malware — and a longer localized
/// description available through the per-row "?" tooltip in the UI.
public struct DNSPreset: Equatable, Sendable, Identifiable {
    /// What a resolver blocks/does. One preset can carry several.
    public enum Chip: String, Sendable, CaseIterable {
        case noFilter
        case privacy
        case malware
        case phishing
        case ads
        case trackers
        case adult
        case safeSearch
    }

    public let id: String
    public let name: String
    public let primary: String
    public let secondary: String
    /// Everything this resolver blocks — rendered as separate chips.
    public let chips: [Chip]

    public init(id: String, name: String, primary: String, secondary: String, chips: [Chip]) {
        self.id = id
        self.name = name
        self.primary = primary
        self.secondary = secondary
        self.chips = chips
    }

    /// True when the settings fields point at this exact preset.
    public func matches(primary: String, secondary: String) -> Bool {
        self.primary == primary.trimmingCharacters(in: .whitespaces)
            && self.secondary == secondary.trimmingCharacters(in: .whitespaces)
    }
}

public enum DNSPresets {
    /// The curated catalog. Chip sets are cumulative where the underlying
    /// blocklists really are (family services block malware too, AdGuard
    /// blocks trackers too, ...).
    public static let all: [DNSPreset] = [
        // MARK: No filtering
        DNSPreset(id: "cloudflare", name: "Cloudflare", primary: "1.1.1.1", secondary: "1.0.0.1",
                  chips: [.noFilter, .privacy]),
        DNSPreset(id: "google", name: "Google Public DNS", primary: "8.8.8.8", secondary: "8.8.4.4",
                  chips: [.noFilter]),
        DNSPreset(id: "adguard-unfiltered", name: "AdGuard Unfiltered", primary: "94.140.14.140", secondary: "94.140.14.141",
                  chips: [.noFilter, .privacy]),
        DNSPreset(id: "yandex", name: "Yandex DNS", primary: "77.88.8.8", secondary: "77.88.8.1",
                  chips: [.noFilter]),
        DNSPreset(id: "dns-watch", name: "DNS.Watch", primary: "84.200.69.80", secondary: "84.200.70.40",
                  chips: [.noFilter, .privacy]),
        DNSPreset(id: "verisign", name: "Verisign", primary: "64.6.64.6", secondary: "64.6.65.6",
                  chips: [.noFilter]),
        DNSPreset(id: "level3", name: "Level3 / Lumen", primary: "4.2.2.1", secondary: "4.2.2.2",
                  chips: [.noFilter]),

        // MARK: Security (malware / phishing)
        DNSPreset(id: "quad9", name: "Quad9", primary: "9.9.9.9", secondary: "149.112.112.112",
                  chips: [.malware, .phishing]),
        DNSPreset(id: "cloudflare-malware", name: "Cloudflare Security", primary: "1.1.1.2", secondary: "1.0.0.2",
                  chips: [.malware, .phishing]),
        DNSPreset(id: "dns0-zero", name: "dns0.eu ZERO", primary: "193.110.81.0", secondary: "185.253.5.0",
                  chips: [.malware, .phishing]),
        DNSPreset(id: "opendns", name: "OpenDNS (Cisco)", primary: "208.67.222.222", secondary: "208.67.220.220",
                  chips: [.phishing]),
        DNSPreset(id: "comodo", name: "Comodo Secure DNS", primary: "8.26.56.26", secondary: "8.20.247.20",
                  chips: [.malware, .phishing]),

        // MARK: Ad blocking
        DNSPreset(id: "adguard", name: "AdGuard DNS", primary: "94.140.14.14", secondary: "94.140.15.15",
                  chips: [.ads, .trackers, .malware]),

        // MARK: Family safe
        DNSPreset(id: "cloudflare-family", name: "Cloudflare Family", primary: "1.1.1.3", secondary: "1.0.0.3",
                  chips: [.adult, .malware]),
        DNSPreset(id: "adguard-family", name: "AdGuard Family", primary: "94.140.14.15", secondary: "94.140.15.16",
                  chips: [.adult, .ads, .trackers, .malware, .safeSearch]),
        DNSPreset(id: "cleanbrowsing-family", name: "CleanBrowsing Family", primary: "185.228.168.168", secondary: "185.228.169.168",
                  chips: [.adult, .malware, .phishing, .safeSearch]),
        DNSPreset(id: "cleanbrowsing-adult", name: "CleanBrowsing Adult", primary: "185.228.168.10", secondary: "185.228.169.11",
                  chips: [.adult]),
        DNSPreset(id: "opendns-familyshield", name: "OpenDNS FamilyShield", primary: "208.67.222.123", secondary: "208.67.220.123",
                  chips: [.adult, .phishing]),
        DNSPreset(id: "yandex-family", name: "Yandex Family", primary: "77.88.8.88", secondary: "77.88.8.2",
                  chips: [.adult]),
    ]
}
