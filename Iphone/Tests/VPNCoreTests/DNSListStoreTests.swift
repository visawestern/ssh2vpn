import XCTest
@testable import VPNCore

final class DNSListStoreTests: XCTestCase {
    func testCatalogShippedWithEntries() {
        XCTAssertFalse(DNSListCatalog.all.isEmpty)
        // Every catalog entry has an HTTPS URL and a plausible entry count.
        for source in DNSListCatalog.all {
            XCTAssertTrue(source.url.hasPrefix("https://"), "insecure URL in \(source.id)")
            XCTAssertGreaterThan(source.entryCount, 0)
        }
        // Stable unique ids.
        XCTAssertEqual(Set(DNSListCatalog.all.map(\.id)).count, DNSListCatalog.all.count)
    }

    func testParseHostsClassicLayouts() {
        let text = """
        # Title: test list
        127.0.0.1 localhost
        0.0.0.0 ads.example.com
        0.0.0.0 tracker.example.com # inline comment
        ||ublock.example.com^
        bare.example.com
        192.168.1.1 not-a-block.example.com
        ! bang comment
        0.0.0.0 ads.example.com
        """
        let domains = DNSListStore.parseHosts(text)
        XCTAssertEqual(domains, ["ads.example.com", "tracker.example.com",
                                  "ublock.example.com", "bare.example.com"])
    }

    func testParseHostsDedupesAndIgnoresLocalhost() {
        let text = """
        0.0.0.0 a.example.com
        0.0.0.0 a.example.com
        127.0.0.1 localhost
        0.0.0.0 localhost
        """
        XCTAssertEqual(DNSListStore.parseHosts(text), ["a.example.com"])
    }

    func testParseHostsCap() {
        var lines: [String] = ["0.0.0.0 base.example.com"]
        for i in 0..<50 { lines.append("0.0.0.0 cap\(i).example.com") }
        let capped = DNSListStore.parseHosts(lines.joined(separator: "\n"), maxEntries: 10)
        XCTAssertEqual(capped.count, 10)
    }

    func testMergedDomainsAcrossLists() {
        let a = SubscribedDNSList(sourceID: "a", domains: ["x.example.com", "y.example.com"])
        let b = SubscribedDNSList(sourceID: "b", domains: ["y.example.com", "z.example.com"])
        XCTAssertEqual(DNSListStore.mergedDomains([a, b]), ["x.example.com", "y.example.com", "z.example.com"])
        XCTAssertEqual(DNSListStore.subscribedIDs([a, b]), ["a", "b"])
    }

    func testRoundTripPersistence() throws {
        let defaults = UserDefaults(suiteName: "DNSListStoreTests")!
        defer { defaults.removePersistentDomain(forName: "DNSListStoreTests") }
        let lists = [SubscribedDNSList(sourceID: "yoyo", domains: ["ads.example.com"])]
        DNSListStore.save(lists, container: defaults)
        XCTAssertEqual(DNSListStore.load(container: defaults), lists)
        DNSListStore.save([], container: defaults)
        XCTAssertTrue(DNSListStore.load(container: defaults).isEmpty)
    }

    func testCuratedDomainsFeedLocalFilter() {
        // The end-to-end contract: parsed curated domains block lookups through
        // the SAME LocalDNSFilter the custom rules use (subtree semantics).
        let domains = DNSListStore.parseHosts("0.0.0.0 ads.example.com\n0.0.0.0 cdn.ads.example.com")
        let filter = LocalDNSFilter(blocklistText: domains.map { "||\($0)^" }.joined(separator: "\n"))
        XCTAssertEqual(filter.action(for: "ads.example.com"), .blocked)
        XCTAssertEqual(filter.action(for: "deep.cdn.ads.example.com"), .blocked)
        XCTAssertEqual(filter.action(for: "ok.example.org"), .none)
    }

    /// Entry equality ignoring the random UUID (id is per-instance).
    private func assertEntry(_ e: DNSBlocklistEntry, domain: String, kind: DNSBlocklistEntry.Kind,
                             ip: String = "", subdomains: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(e.domain, domain, file: file, line: line)
        XCTAssertEqual(e.kind, kind, file: file, line: line)
        XCTAssertEqual(e.ip, ip, file: file, line: line)
        XCTAssertEqual(e.includeSubdomains, subdomains, file: file, line: line)
    }

    func testParseHostsEntriesKeepsScopeAndOverrides() {
        let text = """
        # SSH2VPN DNS filter
        0.0.0.0 ads.example.com
        0.0.0.0 exact.example.com #!
        192.168.1.10 home.example.com
        10.0.0.5 exact-ip.example.com #!
        ||ublock.example.com^
        """
        let entries = DNSListStore.parseHostsEntries(text)
        XCTAssertEqual(entries.count, 5)
        assertEntry(entries[0], domain: "ads.example.com", kind: .block, subdomains: true)
        assertEntry(entries[1], domain: "exact.example.com", kind: .block, subdomains: false)
        assertEntry(entries[2], domain: "home.example.com", kind: .override, ip: "192.168.1.10", subdomains: true)
        assertEntry(entries[3], domain: "exact-ip.example.com", kind: .override, ip: "10.0.0.5", subdomains: false)
        assertEntry(entries[4], domain: "ublock.example.com", kind: .block, subdomains: true)
    }

    func testHostsTextRoundTripPreservesRules() {
        let rules = [
            DNSBlocklistEntry(domain: "ads.example.com", kind: .block),
            DNSBlocklistEntry(domain: "exact.example.com", kind: .block, includeSubdomains: false),
            DNSBlocklistEntry(domain: "home.example.com", kind: .override, ip: "192.168.1.10"),
            DNSBlocklistEntry(domain: "exact-ip.example.com", kind: .override, ip: "10.0.0.5", includeSubdomains: false),
        ]
        let text = DNSListStore.hostsText(for: rules)
        let back = DNSListStore.parseHostsEntries(text)
        XCTAssertEqual(back.count, rules.count)
        for (parsed, original) in zip(back, rules) {
            assertEntry(parsed, domain: original.domain, kind: original.kind,
                        ip: original.ip, subdomains: original.includeSubdomains)
        }
        // And the plain hosts file is semantically valid for other tools:
        // blocks resolve to 0.0.0.0 through the legacy parser too.
        let domains = DNSListStore.parseHosts(text)
        XCTAssertTrue(domains.contains("ads.example.com"))
        XCTAssertTrue(domains.contains("exact.example.com"))
    }
}
