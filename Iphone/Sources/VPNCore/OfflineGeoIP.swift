import Foundation

/// On-device IP -> ISO country lookup. No network: the table is bundled in
/// `Resources/geoip.dat` (built by `scripts/build_geoip.py` from the five
/// RIR delegated-stats files) and consulted with longest-prefix-match.
///
/// Privacy: the server address never leaves the device for location
/// purposes — there is no GeoIP HTTP service to declare to App Review.
public enum OfflineGeoIP {

    // MARK: - Public API

    /// ISO-3166 country code (e.g. "DE") for a literal IPv4/IPv6 string.
    /// Returns nil for unparseable input or ranges not in the table.
    public static func countryCode(ipString: String) -> String? {
        guard let tables = tables else { return nil }
        let t = ipString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v4 = parseIPv4(t) {
            return tables.lookupV4(v4)
        }
        if let v6 = parseIPv6(t) {
            return tables.lookupV6(hi: v6.hi, lo: v6.lo)
        }
        return nil
    }

    /// ISO country code for a host: IP literals are looked up directly
    /// (no DNS, works offline); hostnames go through the SYSTEM resolver
    /// (`getaddrinfo` — local DNS, not a geo service) and then the table.
    /// Blocking (DNS) — call off the main thread.
    public static func countryCode(host: String) -> String? {
        let t = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !t.isEmpty else { return nil }
        if parseIPv4(t) != nil || parseIPv6(t) != nil {
            return countryCode(ipString: t)
        }
        guard let ep = try? SSHEndpointResolver.resolve(t) else { return nil }
        if let v4 = ep.ipv4.first { return countryCode(ipString: v4) }
        if let v6 = ep.ipv6.first { return countryCode(ipString: v6) }
        return nil
    }

    /// True when the string is an IP literal (v4 or v6, brackets allowed).
    public static func isIPAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return parseIPv4(t) != nil || parseIPv6(t) != nil
    }

    // MARK: - IPv4 parsing

    static func parseIPv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber) else { return nil }
            guard let b = UInt32(p), b <= 255 else { return nil }
            // Reject leading zeros ("01") to avoid octal ambiguity.
            if p.count > 1 && p.hasPrefix("0") { return nil }
            out = (out << 8) | b
        }
        return out
    }

    // MARK: - IPv6 parsing

    struct V6: Equatable { let hi: UInt64; let lo: UInt64 }

    /// Strict IPv6 parser with "::" compression. Returns network-order halves.
    static func parseIPv6(_ s: String) -> V6? {
        // Fast reject: only hex, colon, dot (v4-mapped tail).
        guard !s.isEmpty, s.contains(":") else { return nil }
        // Handle embedded IPv4 tail (::ffff:1.2.3.4).
        var addr = s
        var tail: UInt32?
        if let lastColon = s.lastIndex(of: ":") {
            let after = String(s[s.index(after: lastColon)...])
            if after.contains(".") {
                guard let v4 = parseIPv4(after) else { return nil }
                tail = v4
                addr = String(s[..<lastColon]) + ":0:0"
                if addr.hasPrefix(":") && !addr.hasPrefix("::") { return nil }
            }
        }
        let halves = addr.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            let comps = part.split(separator: ":")
            guard !comps.isEmpty else { return nil }
            var out = [UInt16]()
            for g in comps {
                guard !g.isEmpty, g.count <= 4,
                      let v = UInt16(g, radix: 16) else { return nil }
                out.append(v)
            }
            return out
        }
        guard let left = groups(halves[0]) else { return nil }
        var full: [UInt16]
        if halves.count == 2 {
            guard let right = groups(halves[1]) else { return nil }
            let missing = 8 - left.count - right.count
            guard missing >= 0 else { return nil }
            full = left + [UInt16](repeating: 0, count: missing) + right
        } else {
            full = left
        }
        guard full.count == 8 else { return nil }
        if tail != nil {
            full[6] = UInt16((tail! >> 16) & 0xFFFF)
            full[7] = UInt16(tail! & 0xFFFF)
        }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for i in 0..<4 { hi = (hi << 16) | UInt64(full[i]) }
        for i in 4..<8 { lo = (lo << 16) | UInt64(full[i]) }
        return V6(hi: hi, lo: lo)
    }

    // MARK: - Tables

    struct Tables: Sendable {
        /// key: (network << 6) | prefixlen  -> country index
        let v4: [Int64: Int]
        struct V6Key: Hashable, Sendable { let hi: UInt64; let lo: UInt64; let plen: UInt8 }
        let v6: [V6Key: Int]
        let countries: [String]

        func lookupV4(_ ip: UInt32) -> String? {
            for plen in stride(from: 32, through: 0, by: -1) {
                let mask: UInt32 = plen == 0 ? 0 : (~UInt32(0) << (32 - plen))
                let key = (Int64(ip & mask) << 6) | Int64(plen)
                if let ci = v4[key] { return countries[ci] }
            }
            return nil
        }

        func lookupV6(hi: UInt64, lo: UInt64) -> String? {
            for plenU in stride(from: 128, through: 0, by: -1) {
                let plen = UInt8(plenU)
                let (mhi, mlo) = mask128(plen)
                let key = V6Key(hi: hi & mhi, lo: lo & mlo, plen: plen)
                if let ci = v6[key] { return countries[ci] }
            }
            return nil
        }

        private func mask128(_ plen: UInt8) -> (UInt64, UInt64) {
            switch plen {
            case 0: return (0, 0)
            case 128: return (~UInt64(0), ~UInt64(0))
            case 65...127: return (~UInt64(0), ~UInt64(0) << (128 - plen))
            default: return (~UInt64(0) << (64 - plen), 0)
            }
        }
    }

    private static let tables: Tables? = Tables.load()

    /// Number of loaded prefixes (nil table -> nil). For diagnostics/tests.
    public static var loadedPrefixCount: Int? {
        guard let t = tables else { return nil }
        return t.v4.count + t.v6.count
    }
}

private extension OfflineGeoIP.Tables {
    static func load() -> OfflineGeoIP.Tables? {
        guard let url = Bundle.module.url(forResource: "geoip", withExtension: "dat") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let b = [UInt8](data)
        var off = 0
        func u32() -> UInt32? {
            guard off + 4 <= b.count else { return nil }
            let v = (UInt32(b[off]) << 24) | (UInt32(b[off + 1]) << 16)
                | (UInt32(b[off + 2]) << 8) | UInt32(b[off + 3])
            off += 4
            return v
        }
        func u16() -> UInt16? {
            guard off + 2 <= b.count else { return nil }
            let v = (UInt16(b[off]) << 8) | UInt16(b[off + 1])
            off += 2
            return v
        }
        func u8() -> UInt8? {
            guard off < b.count else { return nil }
            defer { off += 1 }
            return b[off]
        }
        func u64() -> UInt64? {
            guard off + 8 <= b.count else { return nil }
            var v: UInt64 = 0
            for i in 0 ..< 8 { v = (v << 8) | UInt64(b[off + i]) }
            off += 8
            return v
        }
        guard b.count >= 4, b[0] == 0x47, b[1] == 0x45, b[2] == 0x4F, b[3] == 0x31 else { return nil } // GEO1
        off = 4
        guard let c4 = u32(), c4 < 2_000_000 else { return nil }
        var v4 = [Int64: Int]()
        v4.reserveCapacity(Int(c4))
        for _ in 0 ..< c4 {
            guard let net = u32(), let plen = u8(), let ci = u16(), plen <= 32 else { return nil }
            v4[(Int64(net) << 6) | Int64(plen)] = Int(ci)
        }
        guard let c6 = u32(), c6 < 1_000_000 else { return nil }
        var v6 = [V6Key: Int]()
        v6.reserveCapacity(Int(c6))
        for _ in 0 ..< c6 {
            guard let hi = u64(), let lo = u64(), let plen = u8(), let ci = u16(), plen <= 128 else { return nil }
            v6[V6Key(hi: hi, lo: lo, plen: plen)] = Int(ci)
        }
        guard let cc = u16(), cc < 1000 else { return nil }
        var countries = [String]()
        countries.reserveCapacity(Int(cc))
        for _ in 0 ..< cc {
            guard off + 2 <= b.count else { return nil }
            let s = String(bytes: [b[off], b[off + 1]], encoding: .ascii)
            off += 2
            guard let s else { return nil }
            countries.append(s)
        }
        return OfflineGeoIP.Tables(v4: v4, v6: v6, countries: countries)
    }
}
