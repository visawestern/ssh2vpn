import Foundation

// MARK: - Structured blocklist/override rules

/// One local DNS rule. Block rules answer 0.0.0.0 (uBlock-style A record);
/// override rules resolve the domain to a user-chosen IPv4.
public struct DNSBlocklistEntry: Identifiable, Codable, Equatable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case block, override }

    public var id: UUID
    public var domain: String
    public var kind: Kind
    /// Target IPv4 (used by override rules; block rules imply 0.0.0.0).
    public var ip: String

    public init(id: UUID = UUID(), domain: String, kind: Kind, ip: String = "") {
        self.id = id
        self.domain = domain
        self.kind = kind
        self.ip = ip
    }

    // MARK: - List (de)serialization for the tunnel's providerConfiguration

    /// JSON-encodes the rules for travel through providerConfiguration
    /// (values there must be property-list types).
    public static func encodeList(_ entries: [DNSBlocklistEntry]) -> String? {
        guard let data = try? JSONEncoder().encode(entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeList(from json: String) -> [DNSBlocklistEntry] {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([DNSBlocklistEntry].self, from: data) else { return [] }
        return entries
    }
}

// MARK: - DNS wire format helpers

/// Minimal DNS wire utilities: enough to read the question name/type from a
/// query and to synthesize local answers (0.0.0.0 block, custom-IP override,
/// REFUSED) without a full resolver.
public enum DNSWire {
    /// The question name from a raw DNS message (payload without the
    /// length prefix used by DNS-over-TCP), lowercased, dot-joined.
    /// Nil when the message is too short or malformed.
    public static func questionName(from message: Data) -> String? {
        guard message.count >= 12 else { return nil }
        var labels: [String] = []
        var i = 12
        while i < message.count {
            let len = Int(message[i])
            guard len > 0 else { break }                    // root label
            i += 1
            guard i + len <= message.count else { return nil }
            let label = String(decoding: message[i..<(i + len)], as: UTF8.self)
            labels.append(label.lowercased())
            i += len
            guard labels.count <= 128 else { return nil }   // hostile deep name
        }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ".")
    }

    /// QTYPE of the question (1 = A, 28 = AAAA, 65 = HTTPS, ...).
    public static func questionType(from message: Data) -> UInt16? {
        guard message.count >= 12 else { return nil }
        var i = 12
        while i < message.count, message[i] != 0 { i += Int(message[i]) + 1 }
        guard i + 5 <= message.count, message[i] == 0 else { return nil }
        return UInt16(message[i + 1]) << 8 | UInt16(message[i + 2])
    }

    /// "1.2.3.4" -> [1,2,3,4]; nil when not a dotted-quad literal.
    public static func ipv4Bytes(_ string: String) -> [UInt8]? {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out = [UInt8]()
        for p in parts {
            guard let v = UInt8(p), p.count <= 3, p.allSatisfy(\.isNumber) else { return nil }
            out.append(v)
        }
        return out
    }

    /// Synthesizes an A-record answer for the query: same id + question,
    /// one A record with `ipv4`, TTL as given. Answers only make sense for
    /// QTYPE=A queries — the caller decides.
    public static func aRecordReply(to query: Data, ipv4: [UInt8], ttl: UInt32 = 300) -> Data? {
        guard query.count >= 12, ipv4.count == 4 else { return nil }
        // Find the end of the question section (null label + QTYPE + QCLASS).
        var i = 12
        while i < query.count, query[i] != 0 { i += Int(query[i]) + 1 }
        guard i + 5 <= query.count, query[i] == 0 else { return nil }
        let questionEnd = i + 5

        var out = Data()
        out.append(query[0]); out.append(query[1])          // id
        out.append(0x81); out.append(0x80)                  // QR=1, RD=1, RA=1
        out.append(0x00); out.append(0x01)                   // QDCOUNT 1
        out.append(0x00); out.append(0x01)                   // ANCOUNT 1
        out.append(0x00); out.append(0x00)                   // NSCOUNT 0
        out.append(0x00); out.append(0x00)                   // ARCOUNT 0
        out.append(contentsOf: query[12..<questionEnd])      // question verbatim
        // Answer: name pointer to offset 12, A, IN, TTL, RDLENGTH 4, address.
        out.append(0xC0); out.append(0x0C)
        out.append(0x00); out.append(0x01)
        out.append(0x00); out.append(0x01)
        out.append(UInt8((ttl >> 24) & 0xFF)); out.append(UInt8((ttl >> 16) & 0xFF))
        out.append(UInt8((ttl >> 8) & 0xFF)); out.append(UInt8(ttl & 0xFF))
        out.append(0x00); out.append(0x04)
        out.append(contentsOf: ipv4)
        return out
    }

    /// Synthesizes a "refused" response: same id/question, RCODE=REFUSED (5),
    /// no records. Used for non-A queries about locally handled domains —
    /// fail fast instead of inventing records of the wrong type.
    public static func refusedReply(to query: Data) -> Data? {
        guard query.count >= 12 else { return nil }
        var out = Data(query)
        out[2] = 0x80 // QR=1 response
        out[3] = 0x05 // RCODE 5 = REFUSED
        out[6] = 0; out[7] = 0
        out[8] = 0; out[9] = 0
        out[10] = 0; out[11] = 0
        return out
    }
}

// MARK: - Local blocklist / override engine

/// What the tunnel should do with a domain, all answered LOCALLY before any
/// upstream query is sent.
public enum LocalDNSAction: Equatable, Sendable {
    case none
    /// Answer A 0.0.0.0 (uBlock-style block).
    case blocked
    /// Answer A with this IPv4 (user override).
    case override(ip: String)
}

public struct LocalDNSFilter: Equatable, Sendable {
    /// Lowercased domains, no trailing dots. "example.com" blocks the
    /// domain itself and all subdomains.
    public private(set) var blockedDomains: Set<String>
    /// Exact-domain overrides: domain -> IPv4 (hosts-file mapping).
    public private(set) var overrides: [String: String]

    public init(blockedDomains: Set<String> = [], overrides: [String: String] = [:]) {
        self.blockedDomains = Set(blockedDomains.compactMap { Self.normalize($0) }.filter { !$0.isEmpty })
        var cleaned = [String: String]()
        for (key, value) in overrides {
            guard let d = Self.normalize(key), !d.isEmpty,
                  DNSWire.ipv4Bytes(value) != nil else { continue }
            cleaned[d] = value
        }
        self.overrides = cleaned
    }

    /// Builds the filter from structured rules (app settings -> tunnel).
    public init(entries: [DNSBlocklistEntry]) {
        var blocked = Set<String>()
        var overrides = [String: String]()
        for entry in entries {
            guard let d = Self.normalize(entry.domain), !d.isEmpty else { continue }
            switch entry.kind {
            case .block:
                blocked.insert(d)
            case .override:
                if DNSWire.ipv4Bytes(entry.ip) != nil { overrides[d] = entry.ip }
            }
        }
        self.init(blockedDomains: blocked, overrides: overrides)
    }

    /// Parses hosts-file / uBlock-style lines (legacy import + tests):
    /// "example.com", "0.0.0.0 example.com" (block), "1.2.3.4 example.com"
    /// (override), "||example.com^", comments (# or !).
    public init(blocklistText: String) {
        var blocked = Set<String>()
        var overrides = [String: String]()
        for rawLine in blocklistText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            var domain: String?
            var ip: String?
            if line.hasPrefix("||") {                       // ABP/uBlock syntax
                let body = String(line.dropFirst(2))
                domain = (body.split(separator: "^").first ?? body.split(separator: " ").first).map(String.init)
            } else {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2, DNSWire.ipv4Bytes(String(parts[0])) != nil {
                    ip = String(parts[0])
                    domain = parts[1].split(separator: "#").first.map(String.init)
                } else if parts.count == 1 {
                    domain = parts[0].split(separator: "#").first.map(String.init)
                }
            }
            if let d = domain.flatMap(Self.normalize)?.nonEmpty {
                if let ip, ip != "0.0.0.0", ip != "127.0.0.1" {
                    overrides[d] = ip   // hosts mapping to a real address
                } else {
                    blocked.insert(d)  // 0.0.0.0 / 127.0.0.1 / bare domain
                }
            }
        }
        self.init(blockedDomains: blocked, overrides: overrides)
    }

    /// The action for a domain (any case, optional trailing dot): override
    /// (exact match only) wins over block (exact + all subdomains).
    public func action(for domain: String) -> LocalDNSAction {
        guard let d = Self.normalize(domain), !d.isEmpty else { return .none }
        if let ip = overrides[d] { return .override(ip: ip) }
        if blockedDomains.contains(d) { return .blocked }
        // Ancestor walk: "a.b.example.com" -> "b.example.com" -> ...
        var parts = d.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            if blockedDomains.contains(parts.joined(separator: ".")) { return .blocked }
        }
        return .none
    }

    public var isEmpty: Bool { blockedDomains.isEmpty && overrides.isEmpty }

    public mutating func add(domain: String) {
        if let d = Self.normalize(domain), !d.isEmpty { blockedDomains.insert(d) }
    }

    public mutating func remove(domain: String) {
        if let d = Self.normalize(domain) {
            blockedDomains.remove(d)
            overrides.removeValue(forKey: d)
        }
    }

    /// Basic domain sanity for the Add-rule form: 2+ labels, allowed chars,
    /// TLD at least 2 letters, label lengths 1...63.
    public static func isValidDomain(_ s: String) -> Bool {
        guard let d = normalize(s), !d.isEmpty else { return false }
        let labels = d.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for (i, label) in labels.enumerated() {
            guard (1...63).contains(label.count) else { return false }
            guard label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return false }
            if i == labels.count - 1 {
                guard label.count >= 2, label.allSatisfy(\.isLetter) else { return false }
            }
        }
        return true
    }

    // MARK: - private

    private static func normalize(_ raw: String) -> String? {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while d.hasSuffix(".") { d.removeLast() }
        guard !d.isEmpty, d != "." else { return nil }
        guard d.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        return d
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - DNS response cache (TTL-aware)

/// Caches raw DNS responses per (question name + type) for their remaining
/// TTL, capped. Repeat lookups resolve in ~0ms without touching the
/// upstream. Locally answered rules (block/override) never enter here —
/// they are already instant and deterministic.
public struct DNSCache: Sendable {
    public struct Entry: Sendable {
        let payload: Data      // raw UDP answer (no TCP length prefix)
        let expiresAt: Date
        var remainingTTL: TimeInterval {
            max(0, expiresAt.timeIntervalSinceNow)
        }
    }

    /// Hard cap we'll hold any entry regardless of the record TTL — a moved
    /// domain must not stay stale for an hour.
    public static let maxTTL: TimeInterval = 300
    /// Entries below this TTL are dropped instead of stored.
    public static let minStoreTTL: UInt32 = 5

    private var entries: [String: Entry] = [:]
    public let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = max(16, capacity)
    }

    /// Cache key: question name + question type/class bytes.
    public static func key(for query: Data) -> String? {
        guard let name = DNSWire.questionName(from: query), query.count >= 17 else { return nil }
        var i = 12
        while i < query.count, query[i] != 0 { i += Int(query[i]) + 1 }
        guard i + 5 <= query.count, query[i] == 0 else { return nil }
        let tail = query[(i + 1)..<(i + 5)]
        return name + ":" + tail.map { String(format: "%02x", $0) }.joined()
    }

    /// Stored answer for this query when still fresh; the payload's id is
    /// rewritten to the LIVE query's id before returning.
    public func answer(for query: Data) -> Data? {
        guard let key = Self.key(for: query),
              let hit = entries[key], hit.remainingTTL > 0 else { return nil }
        return Self.rewriteID(in: hit.payload, to: query)
    }

    /// Stores `responsePayload` under `query`'s key for min(record TTL,
    /// maxTTL) seconds.
    public mutating func store(query: Data, response responsePayload: Data) {
        guard let key = Self.key(for: query) else { return }
        guard let name = DNSWire.questionName(from: query), !name.isEmpty else { return }
        let ttl = Self.effectiveTTL(of: responsePayload, questionName: name)
        guard ttl >= Self.minStoreTTL else { return }
        evictIfNeeded()
        entries[key] = Entry(payload: responsePayload,
                            expiresAt: Date().addingTimeInterval(TimeInterval(min(ttl, UInt32(Self.maxTTL)))))
    }

    /// First A-record TTL found in the answer; 0 when none parse.
    static func effectiveTTL(of response: Data, questionName: String) -> UInt32 {
        guard response.count >= 12 else { return 0 }
        let qdcount = UInt16(response[4]) << 8 | UInt16(response[5])
        var i = 12
        for _ in 0..<qdcount {
            guard i < response.count else { return 0 }
            while i < response.count, response[i] != 0 { i += Int(response[i]) + 1 }
            i += 5 // null label + QTYPE + QCLASS
        }
        let ancount = UInt16(response[6]) << 8 | UInt16(response[7])
        for _ in 0..<ancount {
            guard i < response.count else { return 0 }
            if response[i] & 0xC0 == 0xC0 { i += 2 } else {
                while i < response.count, response[i] != 0 { i += Int(response[i]) + 1 }
                i += 1
            }
            guard i + 10 <= response.count else { return 0 }
            let type = UInt16(response[i]) << 8 | UInt16(response[i + 1])
            let rdlength = Int(UInt16(response[i + 8]) << 8 | UInt16(response[i + 9]))
            let ttl = UInt32(response[i + 4]) << 24 | UInt32(response[i + 5]) << 16
                | UInt32(response[i + 6]) << 8 | UInt32(response[i + 7])
            i += 10 + rdlength
            if type == 1 { return ttl }
        }
        return 0
    }

    /// Copies a payload with the DNS id replaced by `query`'s id.
    static func rewriteID(in payload: Data, to query: Data) -> Data {
        guard payload.count >= 2, query.count >= 2 else { return payload }
        var out = Data(payload)
        out[0] = query[0]
        out[1] = query[1]
        return out
    }

    private mutating func evictIfNeeded() {
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now }
        if entries.count >= capacity {
            if let victim = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
                entries.removeValue(forKey: victim.key)
            }
        }
    }

    public var count: Int { entries.count }
}
