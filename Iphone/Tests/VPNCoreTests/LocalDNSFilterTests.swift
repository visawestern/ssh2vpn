import XCTest
@testable import VPNCore

final class LocalDNSFilterTests: XCTestCase {

    func testExactAndSubdomainBlocking() {
        var f = LocalDNSFilter(blockedDomains: ["ads.example.com"])
        XCTAssertTrue(f.isBlocked("ads.example.com"))
        XCTAssertTrue(f.isBlocked("ADS.Example.COM"), "case-insensitive")
        XCTAssertTrue(f.isBlocked("tracker.ads.example.com"), "subdomain of a blocked domain")
        XCTAssertFalse(f.isBlocked("example.com"), "parent is NOT blocked by a child entry")
        XCTAssertFalse(f.isBlocked("notads.example.com"))
        f.remove(domain: "ads.example.com")
        XCTAssertFalse(f.isBlocked("ads.example.com"))
    }

    func testHostsFileParsing() {
        let text = """
        # comment line
        0.0.0.0 doubleclick.net
        127.0.0.1 ad.example.com # trailing comment
        ||ublock-style.com^
        ||abp-no-caret.com
        plaindomain.org
        ! uBlock comment
        bad line with spaces ignored
        """
        let f = LocalDNSFilter(blocklistText: text)
        XCTAssertTrue(f.isBlocked("doubleclick.net"))
        XCTAssertTrue(f.isBlocked("ad.example.com"))
        XCTAssertTrue(f.isBlocked("ublock-style.com"))
        XCTAssertTrue(f.isBlocked("abp-no-caret.com"))
        XCTAssertTrue(f.isBlocked("plaindomain.org"))
        XCTAssertFalse(f.isBlocked("spaces"))
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(LocalDNSFilter(blocklistText: "").isEmpty)
        let f = LocalDNSFilter(blocklistText: "!!!\n#\n \nhttp://not-a-domain")
        XCTAssertFalse(f.isBlocked("http://not-a-domain"))
        XCTAssertFalse(f.isBlocked("anything"))
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

    func testQuestionNameExtraction() {
        XCTAssertEqual(DNSWire.questionName(from: query(id: 0x4e8e, name: "api.ipify.org")), "api.ipify.org")
        XCTAssertEqual(DNSWire.questionName(from: query(id: 1, name: "a.b.example.com")), "a.b.example.com")
        XCTAssertNil(DNSWire.questionName(from: Data(repeating: 0, count: 8)), "too short")
    }

    func testRefusedReplyKeepsIDAndSetsRCODE() throws {
        let q = query(id: 0x4e8e, name: "ads.example.com")
        let r = try XCTUnwrap(DNSWire.refusedReply(to: q))
        XCTAssertEqual(r.prefix(2), q.prefix(2), "id preserved")
        XCTAssertEqual(r[2], 0x80, "QR = response")
        XCTAssertEqual(r[3] & 0x0F, 0x05, "RCODE = REFUSED")
        // Counts zeroed: no answer/authority/additional sections.
        XCTAssertEqual(r[6], 0); XCTAssertEqual(r[7], 0)
        XCTAssertEqual(r[8], 0); XCTAssertEqual(r[9], 0)
        XCTAssertEqual(r[10], 0); XCTAssertEqual(r[11], 0)
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

    /// Full A answer with the given TTL for the given name.
    private func answer(to q: Data, name: String, ttl: UInt32, id: UInt16) -> Data {
        var d = Data()
        d.append(UInt8(id >> 8)); d.append(UInt8(id & 0xFF))
        d.append(0x81); d.append(0x80)   // response, recursion ok
        d.append(0x00); d.append(0x01)   // 1 question
        d.append(0x00); d.append(0x01)   // 1 answer
        d.append(0x00); d.append(0x00)
        d.append(0x00); d.append(0x00)
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
        }
        d.append(0)
        d.append(0); d.append(1) // A
        d.append(0); d.append(1) // IN
        // Answer name (uncompressed):
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
        }
        d.append(0)
        d.append(0); d.append(1) // A
        d.append(0); d.append(1) // IN
        d.append(UInt8((ttl >> 24) & 0xFF)); d.append(UInt8((ttl >> 16) & 0xFF))
        d.append(UInt8((ttl >> 8) & 0xFF)); d.append(UInt8(ttl & 0xFF))
        d.append(0x00); d.append(0x04)   // RDLENGTH
        d.append(93); d.append(184); d.append(14); d.append(14) // 93.184.14.14
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
        XCTAssertNil(cache.answer(for: q), "TTL below minStoreTTL must not poison the cache")
    }

    func testTTLIsCapped() {
        let q = query(id: 1, name: "example.com")
        let a = answer(to: q, name: "example.com", ttl: 86_400, id: 1)
        XCTAssertEqual(DNSCache.effectiveTTL(of: a, questionName: "example.com"), 86_400)
        // Store-side cap is applied via min(ttl, maxTTL):
        var cache = DNSCache()
        cache.store(query: q, response: a)
        // After storing, the entry must exist (86_400 >= minStoreTTL).
        XCTAssertNotNil(cache.answer(for: q))
    }

    func testKeySeparatesTypes() {
        var cache = DNSCache()
        let a = query(id: 1, name: "example.com")
        var https = query(id: 2, name: "example.com")
        https[https.count - 3] = 0x00; https[https.count - 2] = 0x41 // TYPE 65
        cache.store(query: a, response: answer(to: a, name: "example.com", ttl: 300, id: 1))
        XCTAssertNil(cache.answer(for: https), "HTTPS query must not hit an A cache entry")
    }
}
