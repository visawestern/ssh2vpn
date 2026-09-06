import Foundation

/// Curated public DNS presets. Every entry uses well-known, reliable
/// anycast resolvers; the "filter" describes what that resolver blocks.
/// Users tap one in the DNS settings screen (or keep typing their own —
/// the manual fields stay editable).
public struct DNSPreset: Equatable, Sendable, Identifiable {
    public enum Filter: String, Sendable {
        /// No filtering — plain fast resolution.
        case none
        /// Blocks malicious/phishing domains.
        case malware
        /// Blocks ads, trackers and malware domains.
        case ads
        /// Blocks adult content + malware (safe for kids).
        case family
    }

    public let id: String
    public let name: String
    public let primary: String
    public let secondary: String
    public let filter: Filter

    public init(id: String, name: String, primary: String, secondary: String, filter: Filter) {
        self.id = id
        self.name = name
        self.primary = primary
        self.secondary = secondary
        self.filter = filter
    }

    /// True when the settings fields point at this exact preset.
    public func matches(primary: String, secondary: String) -> Bool {
        self.primary == primary.trimmingCharacters(in: .whitespaces)
            && self.secondary == secondary.trimmingCharacters(in: .whitespaces)
    }
}

public enum DNSPresets {
    /// The curated catalog (order = display order: unfiltered first, then
    /// increasingly strict filtering).
    public static let all: [DNSPreset] = [
        DNSPreset(id: "cloudflare", name: "Cloudflare", primary: "1.1.1.1", secondary: "1.0.0.1", filter: .none),
        DNSPreset(id: "google", name: "Google", primary: "8.8.8.8", secondary: "8.8.4.4", filter: .none),
        DNSPreset(id: "quad9", name: "Quad9", primary: "9.9.9.9", secondary: "149.112.112.112", filter: .malware),
        DNSPreset(id: "cloudflare-malware", name: "Cloudflare Malware", primary: "1.1.1.2", secondary: "1.0.0.2", filter: .malware),
        DNSPreset(id: "adguard", name: "AdGuard DNS", primary: "94.140.14.14", secondary: "94.140.15.15", filter: .ads),
        DNSPreset(id: "cloudflare-family", name: "Cloudflare Family", primary: "1.1.1.3", secondary: "1.0.0.3", filter: .family),
        DNSPreset(id: "cleanbrowsing-family", name: "CleanBrowsing Family", primary: "185.228.168.168", secondary: "185.228.169.168", filter: .family),
        DNSPreset(id: "opendns-familyshield", name: "OpenDNS FamilyShield", primary: "208.67.222.123", secondary: "208.67.220.123", filter: .family),
    ]
}
