import XCTest
@testable import VPNCore

final class LocalDNSFilterTests: XCTestCase {

    func testSubtreeBlocking() {
        var f = LocalDNSFilter(entries: [DNSBlocklistEntry(domain: "ads.example.com", kind: .block)])
        XCTAssertEqual(f.action(for: "ads.example.com"), .blocked)
        XCTAssertEqual(f.action(for: "ADS.Example.COM"), .blocked, "case-insensitive")
        XCTAssertEqual(f.action(for: "tracker.ads.example.com"), .blocked, "subdomain of a blocked domain")
        XCTAssertEqual(f.action(for: "example.com"), .none, "parent is NOT blocked by a child entry")
        XCTAssertEqual(f.action(for: "notads.example.com"), .none)
        f.remove(domain: "ads.example.com")
        XCTAssertEqual(f.action(for: "ads.example.com"), .none)
    }

    func testExactOnlyBlocking() {
        let f = LocalDNSFilter(entries: [
            DNSBlocklistEntry(domain: "ads.example.com", kind: .block, includeSubdomains: false),
        ])
        XCTAssertEqual(f.action(for: "ads.example.com"), .blocked, "exact domain is blocked")
        XCTAssertEqual(f.action(for: "tracker.ads.example.com"), .none, "subdomain is NOT blocked")
        XCTAssertEqual(f.action(for: "example.com"), .none)
    }

    func testOverrideWinsOverBlockAndIsExact() {
        let f = LocalDNSFilter(entries: [
            DNSBlocklistEntry(domain: "example.com", kind: .block),
            DNSBlocklistEntry(domain: "api.example.com", kind: .override, ip: "10.0.0.5"),
        ])
        XCTAssertEqual(f.action(for: "example.com"), .blocked)
        XCTAssertEqual(f.action(for: "api.example.com"), .override(ip: "10.0.0.5"), "exact override wins over the parent block")
        XCTAssertEqual(f.action(for: "sub.api.example.com"), .override(ip: "10.0.0.5"),
                       "subtree override (default) covers subdomains")
    }

    func testSubtreeOverrideAppliesToSubdomains() {
        let f = LocalDNSFilter(entries: [
            DNSBlocklistEntry(domain: "corp.example.com", kind: .override, ip: "10.0.0.9"),
        ])
        XCTAssertEqual(f.action(for: "corp.example.com"), .override(ip: "10.0.0.9"))
        XCTAssertEqual(f.action(for: "vpn.corp.example.com"), .override(ip: "10.0.0.9"))
    }

    func testExactOverrideBeatsSubtreeOverride() {
        let f = LocalDNSFilter(entries: [
            DNSBlocklistEntry(domain: "corp.example.com", kind: .override, ip: "10.0.0.9"),
            DNSBlocklistEntry(domain: "special.corp.example.com", kind: .override, ip: "10.9.9.9", includeSubdomains: false),
        ])
        XCTAssertEqual(f.action(for: "special.corp.example.com"), .override(ip: "10.9.9.9"), "more specific exact rule wins")
        XCTAssertEqual(f.action(for: "other.corp.example.com"), .override(ip: "10.0.0.9"))
    }

    func testStructuredRulesRoundTripThroughFilter() {
        let entries = [
            DNSBlocklistEntry(domain: "DoubleClick.NET ", kind: .block),
            DNSBlocklistEntry(domain: "home.lan", kind: .override, ip: "192.168.1.10"),
            DNSBlocklistEntry(domain: "only.exact.lan", kind: .block, includeSubdomains: false),
            DNSBlocklistEntry(domain: "bad-ip.lan", kind: .override, ip: "not-an-ip"),
        ]
        let f = LocalDNSFilter(entries: entries)
        XCTAssertEqual(f.action(for: "doubleclick.net"), .blocked)
        XCTAssertEqual(f.action(for: "www.doubleclick.net"), .blocked)
        XCTAssertEqual(f.action(for: "home.lan"), .override(ip: "192.168.1.10"))
        XCTAssertEqual(f.action(for: "only.exact.lan"), .blocked)
        XCTAssertEqual(f.action(for: "sub.only.exact.lan"), .none)
        XCTAssertEqual(f.action(for: "bad-ip.lan"), .none, "override with invalid IP is dropped")
    }

    func testHostsTextParsingStillSupported() {
        let text = """
        # comment line
        0.0.0.0 doubleclick.net
        1.2.3.4 home.example # override + trailing comment
        ||ublock-style.com^
        plaindomain.org
        ! uBlock comment
        """
        let f = LocalDNSFilter(blocklistText: text)
        XCTAssertEqual(f.action(for: "doubleclick.net"), .blocked)
        XCTAssertEqual(f.action(for: "home.example"), .override(ip: "1.2.3.4"))
        XCTAssertEqual(f.action(for: "ublock-style.com"), .blocked)
        XCTAssertEqual(f.action(for: "plaindomain.org"), .blocked)
    }

    func testDomainValidation() {
        XCTAssertTrue(LocalDNSFilter.isValidDomain("example.com"))
        XCTAssertTrue(LocalDNSFilter.isValidDomain("a.b.example.co.uk"))
        XCTAssertFalse(LocalDNSFilter.isValidDomain("example"), "no TLD")
        XCTAssertFalse(LocalDNSFilter.isValidDomain("ex.c"), "TLD too short")
        XCTAssertFalse(LocalDNSFilter.isValidDomain("bad_domain!.com"))
        XCTAssertFalse(LocalDNSFilter.isValidDomain(""))
    }

    func testEntryListJSONRoundTrip() {
        let entries = [
            DNSBlocklistEntry(domain: "ads.net", kind: .block),
            DNSBlocklistEntry(domain: "home.lan", kind: .override, ip: "10.1.2.3"),
            DNSBlocklistEntry(domain: "exact.org", kind: .block, includeSubdomains: false),
        ]
        let json = DNSBlocklistEntry.encodeList(entries)
        XCTAssertNotNil(json)
        let decoded = DNSBlocklistEntry.decodeList(from: json!)
        XCTAssertEqual(decoded, entries)
        XCTAssertEqual(DNSBlocklistEntry.decodeList(from: "garbage"), [])
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(LocalDNSFilter(blocklistText: "").isEmpty)
        let f = LocalDNSFilter(blocklistText: "!!!\n#\n \nhttp://not-a-domain")
        XCTAssertEqual(f.action(for: "http://not-a-domain"), .none)
        XCTAssertEqual(f.action(for: "anything"), .none)
    }
}

// MARK: - DNS wire tests

final class DNSWireTests: XCTestCase {

    /// Builds "id flags qdcount=1 <name> QTYPE QCLASS" minimal query.
    private func query(id: UInt16, name: String, qtype: UInt16 = 1) -> Data {
        var d = Data()
        d.append(UInt8(id >> 8)); d.append(UInt8(id & 0xFF))
        d.append(0x01); d.append(0x00)   // flags: recursion desired
        d.append(0x00); d.append(0x01)   // QDCOUNT 1
        d.append(0x00); d.append(0x00)   // ANCOUNT
        d.append(0x00); d.append(0x00)   // NSCOUNT
        d.append(0x00); d.append(0x00)   // ARCOUNT
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            d.append(UInt8(bytes.count))
            d.append(contentsOf: bytes)
        }
        d.append(0)
        d.append(UInt8(qtype >> 8)); d.append(UInt8(qtype & 0xFF))
        d.append(0x00); d.append(0x01)   // IN
        return d
    }

    func testQuestionNameAndTypeExtraction() {
        let q = query(id: 0x4e8e, name: "api.ipify.org")
        XCTAssertEqual(DNSWire.questionName(from: q), "api.ipify.org")
        XCTAssertEqual(DNSWire.questionType(from: q), 1)
        let https = query(id: 2, name: "x.org", qtype: 65)
        XCTAssertEqual(DNSWire.questionType(from: https), 65)
        XCTAssertNil(DNSWire.questionName(from: Data(repeating: 0, count: 8)), "too short")
    }

    func testARecordReplyForBlock() throws {
        let q = query(id: 0x4e8e, name: "ads.example.com")
        let r = try XCTUnwrap(DNSWire.aRecordReply(to: q, ipv4: [0, 0, 0, 0]))
        XCTAssertEqual(r[0], q[0]); XCTAssertEqual(r[1], q[1], "id preserved")
        XCTAssertEqual(r[2], 0x81, "QR=1 response")
        XCTAssertEqual(r[6], 0); XCTAssertEqual(r[7], 1, "ANCOUNT = 1")
        XCTAssertEqual(r.suffix(4), Data([0, 0, 0, 0]), "block address is 0.0.0.0")
    }

    func testARecordReplyCarriesChosenIP() throws {
        let q = query(id: 0x1111, name: "home.lan")
        let r = try XCTUnwrap(DNSWire.aRecordReply(to: q, ipv4: [10, 1, 2, 3]))
        XCTAssertEqual(r.suffix(4), Data([10, 1, 2, 3]), "override address")
    }

    func testRefusedReplyKeepsIDAndSetsRCODE() throws {
        let q = query(id: 0x4e8e, name: "ads.example.com", qtype: 28) // AAAA about a blocked name
        let r = try XCTUnwrap(DNSWire.refusedReply(to: q))
        XCTAssertEqual(r.prefix(2), q.prefix(2), "id preserved")
        XCTAssertEqual(r[2], 0x80, "QR = response")
        XCTAssertEqual(r[3] & 0x0F, 0x05, "RCODE = REFUSED")
    }

    func testIPv4BytesParsing() {
        XCTAssertEqual(DNSWire.ipv4Bytes("1.2.3.4"), [1, 2, 3, 4])
        XCTAssertEqual(DNSWire.ipv4Bytes(" 10.0.0.1 "), [10, 0, 0, 1])
        XCTAssertNil(DNSWire.ipv4Bytes("1.2.3"))
        XCTAssertNil(DNSWire.ipv4Bytes("1.2.3.256"))
        XCTAssertNil(DNSWire.ipv4Bytes("dns.google"))
    }
}

// MARK: - DNS cache tests

final class DNSCacheTests: XCTestCase {

    private func query(id: UInt16, name: String) -> Data {
        var d = Data()
        d.append(UInt8(id >> 8)); d.append(UInt8(id & 0xFF))
        d.append(0x01); d.append(0x00)
        d.append(0x00); d.append(0x01)
        d.append(0); d.append(0); d.append(0); d.append(0); d.append(0); d.append(0)
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
        }
        d.append(0)
        d.append(0); d.append(1) // A
        d.append(0); d.append(1) // IN
        return d
    }

    private func answer(to q: Data, name: String, ttl: UInt32, id: UInt16) -> Data {
        var d = Data()
        d.append(UInt8(id >> 8)); d.append(UInt8(id & 0xFF))
        d.append(0x81); d.append(0x80)
        d.append(0x00); d.append(0x01)
        d.append(0x00); d.append(0x01)
        d.append(0x00); d.append(0x00)
        d.append(0x00); d.append(0x00)
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
        }
        d.append(0)
        d.append(0); d.append(1)
        d.append(0); d.append(1)
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
        }
        d.append(0)
        d.append(0); d.append(1) // A
        d.append(0); d.append(1) // IN
        d.append(UInt8((ttl >> 24) & 0xFF)); d.append(UInt8((ttl >> 16) & 0xFF))
        d.append(UInt8((ttl >> 8) & 0xFF)); d.append(UInt8(ttl & 0xFF))
        d.append(0x00); d.append(0x04)
        d.append(93); d.append(184); d.append(14); d.append(14)
        return d
    }

    func testStoreAndHitRewritesID() {
        var cache = DNSCache()
        let q1 = query(id: 0x1111, name: "example.com")
        let q2 = query(id: 0x2222, name: "example.com")
        cache.store(query: q1, response: answer(to: q1, name: "example.com", ttl: 300, id: 0x1111))
        let hit = cache.answer(for: q2)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.prefix(2), q2.prefix(2), "cached answer carries the LIVE query id")
        XCTAssertEqual(hit?.suffix(4), Data([93, 184, 14, 14]))
    }

    func testLowTTLNotStored() {
        var cache = DNSCache()
        let q = query(id: 1, name: "short.com")
        cache.store(query: q, response: answer(to: q, name: "short.com", ttl: 2, id: 1))
        XCTAssertNil(cache.answer(for: q))
    }

    func testKeySeparatesTypes() {
        var cache = DNSCache()
        let a = query(id: 1, name: "example.com")
        var https = query(id: 2, name: "example.com")
        https[https.count - 3] = 0x00; https[https.count - 2] = 0x41 // TYPE 65
        cache.store(query: a, response: answer(to: a, name: "example.com", ttl: 300, id: 1))
        XCTAssertNil(cache.answer(for: https))
    }
}
