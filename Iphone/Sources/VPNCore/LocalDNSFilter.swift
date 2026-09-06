import Foundation

// MARK: - DNS wire format helpers (query name extraction + blocked reply)

/// Minimal DNS wire utilities: enough to read the question name from a
/// query and to synthesize a "blocked" answer without a full resolver.
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
            guard i + len <= message.count,
                  !message[i..<(i + len)].contains(where: { $0 == 0x2E }) else { return nil }
            let label = String(decoding: message[i..<(i + len)], as: UTF8.self)
            labels.append(label.lowercased())
            i += len
            guard labels.count <= 128 else { return nil }   // hostile deep name
        }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ".")
    }

    /// Synthesizes a "blocked" A response for the query: same id/question,
    /// RCODE=REFUSED (5), no answers. Refused makes clients fail fast
    /// instead of retrying NXDOMAIN variants (uBlock-style behavior uses
    /// 0.0.0.0; REFUSED is what most blockers moved to because 0.0.0.0 makes
    /// some stacks retry the connection for minutes).
    /// The reply is a raw UDP payload (no TCP length prefix).
    public static func refusedReply(to query: Data) -> Data? {
        guard query.count >= 12 else { return nil }
        var out = Data(query)
        out[2] = 0x80 // QR=1 response
        out[3] = 0x05 // RCODE 5 = REFUSED; Z/AD/CD stay zero
        // Zero the answer/authority/additional counts: mirror the question
        // section the client sent, no records at all.
        out[6] = 0; out[7] = 0
        out[8] = 0; out[9] = 0
        out[10] = 0; out[11] = 0
        return out
    }
}

// MARK: - Local blocklist (uBlock/hosts-style)

/// Local domain blocklist checked BEFORE any upstream query. Entries are
/// exact domains ("example.com") which also cover every subdomain
/// ("a.example.com" matches "example.com"), mirroring hosts-file semantics.
public struct LocalDNSFilter: Equatable, Sendable {
    /// Lowercased domains, no trailing dots. "example.com" blocks the
    /// domain itself and all subdomains.
    public private(set) var blockedDomains: Set<String>

    public init(blockedDomains: Set<String> = []) {
        self.blockedDomains = Set(blockedDomains.compactMap { Self.normalize($0) }.filter { !$0.isEmpty })
    }

    /// Parses hosts-file / uBlock-style lines: "example.com",
    /// "0.0.0.0 example.com", "||example.com^", "# comment", empty lines.
    public init(blocklistText: String) {
        var set = Set<String>()
        for rawLine in blocklistText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            var domain: String?
            if line.hasPrefix("||") {                       // ABP/uBlock syntax
                let body = String(line.dropFirst(2))
                domain = (body.split(separator: "^").first ?? body.split(separator: " ").first).map(String.init)
            } else {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                // Hosts line: "<ip> <domain> [# comment]" or just "<domain>".
                if parts.count >= 2, Self.looksLikeIP(String(parts[0])) {
                    domain = parts[1].split(separator: "#").first.map(String.init)
                } else if parts.count == 1 {
                    domain = parts[0].split(separator: "#").first.map(String.init)
                }
            }
            if let d = domain.flatMap(Self.normalize)?.nonEmpty {
                set.insert(d)
            }
        }
        self.blockedDomains = set
    }

    /// True when `domain` (any case, optional trailing dot) is blocked:
    /// exact match or any blocked ancestor covers its subdomains.
    public func isBlocked(_ domain: String) -> Bool {
        guard let d = Self.normalize(domain), !d.isEmpty else { return false }
        if blockedDomains.contains(d) { return true }
        // Ancestor walk: "a.b.example.com" -> "b.example.com" -> ...
        var parts = d.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            if blockedDomains.contains(parts.joined(separator: ".")) { return true }
        }
        return false
    }

    public var isEmpty: Bool { blockedDomains.isEmpty }

    public mutating func add(domain: String) {
        if let d = Self.normalize(domain), !d.isEmpty { blockedDomains.insert(d) }
    }

    public mutating func remove(domain: String) {
        if let d = Self.normalize(domain) { blockedDomains.remove(d) }
    }

    // MARK: - private

    private static func normalize(_ raw: String) -> String? {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while d.hasSuffix(".") { d.removeLast() }
        guard !d.isEmpty, d != "." else { return nil }
        // Sanity: only DNS-name characters, and at least one label.
        guard d.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        return d
    }

    private static func looksLikeIP(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - DNS response cache (TTL-aware)

/// Caches raw DNS responses per (query id ignored — key is the question
/// name + type byte tail) for their remaining TTL, capped. Repeat lookups
/// resolve in ~0ms without touching the upstream — that's the "optimal
/// time" part of local filtering: blocklists also make popular domains
/// effectively instant on the deny path.
public struct DNSCache: Sendable {
    public struct Entry: Sendable {
        let payload: Data      // raw UDP answer (no TCP length prefix)
        let expiresAt: Date
        var remainingTTL: TimeInterval {
            max(0, expiresAt.timeIntervalSinceNow)
        }
    }

    /// Max seconds we'll hold any entry regardless of the record TTL — a
    /// hard cap keeps moved domains from being stale for an hour.
    public static let maxTTL: TimeInterval = 300
    /// Entries below this TTL are dropped instead of stored (a 0/30s TTL
    /// CDN answer buys nothing and evicts useful ones).
    public static let minStoreTTL: UInt32 = 5

    private var entries: [String: Entry] = [:]
    public let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = max(16, capacity)
    }

    /// Cache key: question name + question type/class bytes.
    public static func key(for query: Data) -> String? {
        guard let name = DNSWire.questionName(from: query), query.count >= 17 else { return nil }
        // QTYPE (2B) + QCLASS (2B) follow the question name; find them.
        var i = 12
        while i < query.count, query[i] != 0 { i += Int(query[i]) + 1 }
        guard i + 5 <= query.count, query[i] == 0 else { return nil }
        let tail = query[(i + 1)..<(i + 5)]
        return name + ":" + tail.map { String(format: "%02x", $0) }.joined()
    }

    /// Stored answer for this query when still fresh; the payload's id is
    /// rewritten to the LIVE query's id before returning (a cached answer
    /// must answer the question it's being asked, not the old one).
    public func answer(for query: Data) -> Data? {
        guard let key = Self.key(for: query),
              let hit = entries[key], hit.remainingTTL > 0 else { return nil }
        return Self.rewriteID(in: hit.payload, to: query)
    }

    /// Stores `responsePayload` under `query`'s key for min(record TTL,
    /// maxTTL) seconds. The stored copy keeps the response's original id —
    /// `answer(for:)` rewrites it per live query.
    public mutating func store(query: Data, response responsePayload: Data) {
        guard let key = Self.key(for: query) else { return }
        guard let name = DNSWire.questionName(from: query), !name.isEmpty else { return }
        let ttl = Self.effectiveTTL(of: responsePayload, questionName: name)
        guard ttl >= Self.minStoreTTL else { return }
        evictIfNeeded()
        entries[key] = Entry(payload: responsePayload,
                            expiresAt: Date().addingTimeInterval(TimeInterval(min(ttl, UInt32(Self.maxTTL)))))
    }

    /// First A-record TTL found in the answer, capped; 0 when none parse.
    static func effectiveTTL(of response: Data, questionName: String) -> UInt32 {
        guard response.count >= 12 else { return 0 }
        let qdcount = UInt16(response[4]) << 8 | UInt16(response[5])
        var i = 12
        // Skip the question section first.
        for _ in 0..<qdcount {
            guard i < response.count else { return 0 }
            while i < response.count, response[i] != 0 { i += Int(response[i]) + 1 } // name (uncompressed assumed)
            i += 5 // null label + QTYPE + QCLASS
        }
        let ancount = UInt16(response[6]) << 8 | UInt16(response[7])
        for _ in 0..<ancount {
            guard i < response.count else { return 0 }
            // Name: possibly compressed (0xC0 pointer = 2 bytes).
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
            if type == 1 { return ttl } // first A record wins
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
        // Drop expired first; if still full, drop the soonest-to-expire.
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
