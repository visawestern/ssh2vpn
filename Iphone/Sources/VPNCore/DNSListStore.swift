import Foundation

/// A curated remote hosts list (AdAway-style): a well-known public URL that
/// ships thousands of block domains as a plain hosts file. The user subscribes
/// to lists; the app downloads, parses and merges them into the tunnel's local
/// DNS filter — on top of the user's own hand-written rules.
public struct DNSListSource: Identifiable, Codable, Equatable, Sendable, Hashable {
    public enum Category: String, Codable, Sendable {
        case ads, privacy, malware, regional, general
    }

    public let id: String
    /// Short display identifier (stable, ASCII — localized names live in Copy).
    public let name: String
    /// Where the hosts file is fetched from.
    public let url: String
    public let category: Category
    /// Rough entry count shown before subscribing (from the shipped snapshot).
    public let entryCount: Int

    public init(id: String, name: String, url: String, category: Category, entryCount: Int) {
        self.id = id
        self.name = name
        self.url = url
        self.category = category
        self.entryCount = entryCount
    }
}

/// The catalog of curated lists shipped with the app. URLs are the canonical
/// download endpoints used by AdAway and its community for years — HTTPS,
/// plaintext hosts format, no auth.
public enum DNSListCatalog {
    public static let all: [DNSListSource] = [
        // — General / multipurpose —
        DNSListSource(id: "adaway", name: "AdAway Default",
                      url: "https://adaway.org/hosts.txt",
                      category: .general, entryCount: 9500),
        DNSListSource(id: "yoyo", name: "pgl.yoyo.org",
                      url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext",
                      category: .ads, entryCount: 3600),
        DNSListSource(id: "stevenblack", name: "StevenBlack Unified",
                      url: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
                      category: .general, entryCount: 120000),
        DNSListSource(id: "mvps", name: "MVPS Hosts",
                      url: "https://winhelp2002.mvps.org/hosts.txt",
                      category: .ads, entryCount: 12000),
        // — Tracking / privacy —
        DNSListSource(id: "easyprivacy-nsfw-placeholder", name: "EasyList Tracker Sites",
                      url: "https://raw.githubusercontent.com/lightswitch05/hosts/master/tracking-aggressive-extended/list.txt",
                      category: .privacy, entryCount: 13000),
        DNSListSource(id: "someonewhocares", name: "Somebody Who Cares",
                      url: "https://someonewhocares.org/hosts/hosts",
                      category: .privacy, entryCount: 14000),
        // — Malware / phishing —
        DNSListSource(id: "urlhaus", name: "URLhaus Abuse.ch",
                      url: "https://urlhaus.abuse.ch/downloads/hostfile/",
                      category: .malware, entryCount: 2000),
        DNSListSource(id: "shadowwhocares-phishing", name: "Phishing Army",
                      url: "https://phishing.army/download/phishing_army_blocklist_extended.txt",
                      category: .malware, entryCount: 40000),
        // — Regional (RU/CIS audience of this app) —
        DNSListSource(id: "ruadlist-500", name: "500 RU Ad Servers",
                      url: "https://raw.githubusercontent.com/durak/stringer/master/hostlists/ruadlist-500.txt",
                      category: .regional, entryCount: 500),
        DNSListSource(id: "disconnect-tracking", name: "Disconnect Tracking",
                      url: "https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt",
                      category: .privacy, entryCount: 2800),
        DNSListSource(id: "disconnect-ads", name: "Disconnect Ads",
                      url: "https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt",
                      category: .ads, entryCount: 2900),
    ]

    public static func source(id: String) -> DNSListSource? {
        all.first { $0.id == id }
    }
}

/// One subscribed list's persisted state.
public struct SubscribedDNSList: Codable, Equatable, Sendable {
    public let sourceID: String
    /// When the list was last successfully refreshed.
    public let updatedAt: Date
    /// Parsed block domains from the download (normalized, lowercased).
    public let domains: [String]

    public init(sourceID: String, updatedAt: Date = Date(), domains: [String]) {
        self.sourceID = sourceID
        self.updatedAt = updatedAt
        self.domains = domains
    }
}

/// Pure parsing + persistence for curated subscriptions. Download itself is
/// UI-side (URLSession); everything here is deterministic and unit-testable.
public enum DNSListStore {
    public static let storageKey = "vpn.dns.subscribedLists"

    // MARK: - Parsing

    /// Parses a downloaded hosts file into normalized block domains.
    /// Accepts every classic layout:
    ///   "0.0.0.0 ads.example.com", "127.0.0.1 ads.example.com",
    ///   bare "ads.example.com" lines, "||example.com^" uBlock syntax,
    ///   and strips "# comment" / "! comment" lines.
    /// Domains pointing at 0.0.0.0/127.0.0.1 are BLOCKS; anything else is
    /// dropped (a curated list never carries legitimate overrides).
    public static func parseHosts(_ text: String, maxEntries: Int = 200_000) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(min(4096, maxEntries))
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard out.count < maxEntries else { break }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            var domain: String?
            if line.hasPrefix("||") {
                let body = String(line.dropFirst(2))
                domain = body.split(separator: "^").first.map(String.init) ?? body.split(separator: " ").first.map(String.init)
            } else if line.hasPrefix("0.0.0.0 ") || line.hasPrefix("127.0.0.1 ") {
                domain = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first
                    .flatMap { $0.split(separator: "#").first.map(String.init) }
            } else {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count == 1, DNSWire.ipv4Bytes(String(parts[0])) == nil {
                    domain = parts[0].split(separator: "#").first.map(String.init)
                } else if parts.count >= 2, DNSWire.ipv4Bytes(String(parts[0])) != nil,
                          DNSWire.ipv4Bytes(String(parts[0])) == [0, 0, 0, 0] || DNSWire.ipv4Bytes(String(parts[0])) == [127, 0, 0, 1] {
                    domain = parts[1].split(separator: "#").first.map(String.init)
                }
            }
            if let d = domain.flatMap(LocalDNSFilter.normalizedDomain)?.nonEmpty,
               d != "localhost", d != "localhost.localdomain", d != "ip6-localhost" {
                if seen.insert(d).inserted { out.append(d) }
            }
        }
        return out
    }

    /// Parses a hosts file into editable custom RULES (unlike `parseHosts`,
    /// which flattens everything to block domains): "1.2.3.4 example.com"
    /// becomes an override, "0.0.0.0/bare/||domain" a block. A trailing
    /// "#!" comment marks an exact-domain rule (no subdomains) — the same
    /// marker `hostsText` writes on export, so round-trips keep scope.
    public static func parseHostsEntries(_ text: String, maxEntries: Int = 100_000) -> [DNSBlocklistEntry] {
        var out: [DNSBlocklistEntry] = []
        var seen = Set<String>()
        out.reserveCapacity(1024)
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard out.count < maxEntries else { break }
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            var exact = false
            if let hash = line.firstIndex(of: "#") {
                let comment = String(line[line.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
                exact = comment == "!"
                line = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
            }
            var domain: String?
            var ip: String?
            if line.hasPrefix("||") {
                let body = String(line.dropFirst(2))
                domain = body.split(separator: "^").first.map(String.init) ?? body.split(separator: " ").first.map(String.init)
            } else {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                if parts.count == 1 {
                    domain = parts[0]
                } else if parts.count >= 2, DNSWire.ipv4Bytes(parts[0]) != nil {
                    domain = parts[1]
                    let head = parts[0]
                    if head != "0.0.0.0" && head != "127.0.0.1" { ip = head }
                }
            }
            guard let d = domain.flatMap(LocalDNSFilter.normalizedDomain)?.nonEmpty,
                  d != "localhost", d != "ip6-localhost", !seen.contains(d) else { continue }
            seen.insert(d)
            if let ip, DNSWire.ipv4Bytes(ip) != nil {
                out.append(DNSBlocklistEntry(domain: d, kind: .override, ip: ip, includeSubdomains: !exact))
            } else {
                out.append(DNSBlocklistEntry(domain: d, kind: .block, ip: "", includeSubdomains: !exact))
            }
        }
        return out
    }

    /// Serializes custom rules back to hosts format (with the "#!" scope
    /// marker). The result is a VALID hosts file for any other tool too.
    public static func hostsText(for rules: [DNSBlocklistEntry]) -> String {
        var lines = [
            "# SSH2VPN DNS filter",
            "# 0.0.0.0 domain        -> block (answers 0.0.0.0)",
            "# IP domain             -> override (answers IP)",
            "# Trailing \"#!\" comment -> exact domain only (no subdomains)",
        ]
        for r in rules {
            let suffix = r.includeSubdomains ? "" : " #!"
            switch r.kind {
            case .block: lines.append("0.0.0.0 \(r.domain)\(suffix)")
            case .override: lines.append("\(r.ip) \(r.domain)\(suffix)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Subscription persistence ( UserDefaults JSON )

    public static func load(container: UserDefaults = .standard) -> [SubscribedDNSList] {
        guard let data = container.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([SubscribedDNSList].self, from: data)) ?? []
    }

    public static func save(_ lists: [SubscribedDNSList], container: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(lists) else { return }
        container.set(data, forKey: storageKey)
    }

    /// All block domains across every subscribed list (deduped, order-stable).
    public static func mergedDomains(_ lists: [SubscribedDNSList]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for list in lists {
            for d in list.domains {
                if seen.insert(d).inserted { out.append(d) }
            }
        }
        return out
    }

    /// Subscribed list IDs as a set (fast UI membership checks).
    public static func subscribedIDs(_ lists: [SubscribedDNSList]) -> Set<String> {
        Set(lists.map(\.sourceID))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
