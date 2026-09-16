import XCTest
@testable import VPNCore

final class OfflineGeoIPTests: XCTestCase {
    func testTableLoadsWithFullCoverage() {
        guard let count = OfflineGeoIP.loadedPrefixCount else {
            XCTFail("geoip.dat missing or corrupt — run scripts/build_geoip.py")
            return
        }
        XCTAssertGreaterThan(count, 200_000, "expected the full RIR table, got \(count)")
    }

    func testKnownIPv4Countries() {
        XCTAssertEqual(OfflineGeoIP.countryCode(ipString: "8.8.8.8"), "US")
        XCTAssertEqual(OfflineGeoIP.countryCode(ipString: "1.1.1.1"), "AU")
        XCTAssertEqual(OfflineGeoIP.countryCode(ipString: "77.88.8.8"), "RU")
        XCTAssertEqual(OfflineGeoIP.countryCode(ipString: "95.216.0.1"), "DE")
        // WHG SGP1 Singapore: inetnum says SG (override), registrant is GB.
        XCTAssertEqual(OfflineGeoIP.countryCode(ipString: "192.250.228.44"), "SG")
    }

    func testGarbageAndSpecialUseReturnNil() {
        XCTAssertNil(OfflineGeoIP.countryCode(ipString: ""))
        XCTAssertNil(OfflineGeoIP.countryCode(ipString: "not-an-ip"))
        XCTAssertNil(OfflineGeoIP.countryCode(ipString: "999.1.1.1"))
        XCTAssertNil(OfflineGeoIP.countryCode(ipString: "1.2.3"))
        XCTAssertNil(OfflineGeoIP.countryCode(ipString: "10.0.0.1"))
        XCTAssertNil(OfflineGeoIP.countryCode(ipString: "192.168.1.1"))
        XCTAssertNil(OfflineGeoIP.countryCode(ipString: "127.0.0.1"))
    }

    func testIPv4LeadingZerosRejected() {
        XCTAssertNil(OfflineGeoIP.countryCode(ipString: "008.008.008.008"))
    }

    func testKnownIPv6Countries() {
        // Google Public DNS over IPv6 — US.
        XCTAssertEqual(OfflineGeoIP.countryCode(ipString: "2001:4860:4860::8888"), "US")
        // Loopback / unspecified carry no country.
        XCTAssertNil(OfflineGeoIP.countryCode(ipString: "::1"))
    }

    func testIPv6ParserRoundTrips() {
        XCTAssertNotNil(OfflineGeoIP.parseIPv6("2001:db8::1"))
        XCTAssertNotNil(OfflineGeoIP.parseIPv6("::"))
        XCTAssertNotNil(OfflineGeoIP.parseIPv6("fe80::1"))
        XCTAssertNotNil(OfflineGeoIP.parseIPv6("2001:0db8:0000:0000:0000:0000:0000:0001"))
        XCTAssertNil(OfflineGeoIP.parseIPv6(":::"))
        XCTAssertNil(OfflineGeoIP.parseIPv6("12345::"))
        XCTAssertNil(OfflineGeoIP.parseIPv6("1:2:3:4:5:6:7:8:9"))
    }

    func testIsIPAddress() {
        XCTAssertTrue(OfflineGeoIP.isIPAddress("8.8.8.8"))
        XCTAssertTrue(OfflineGeoIP.isIPAddress("2001:4860:4860::8888"))
        XCTAssertTrue(OfflineGeoIP.isIPAddress("[2001:4860:4860::8888]"))
        XCTAssertFalse(OfflineGeoIP.isIPAddress("vps.example.com"))
        XCTAssertFalse(OfflineGeoIP.isIPAddress(""))
    }

    func testHostLookupAcceptsIPLiteralWithoutDNS() {
        XCTAssertEqual(OfflineGeoIP.countryCode(host: "8.8.8.8"), "US")
        XCTAssertNil(OfflineGeoIP.countryCode(host: ""))
        XCTAssertNil(OfflineGeoIP.countryCode(host: "vpn.invalid"))
    }

    func testCentroidsCoverTableCountries() {
        for code in ["US", "DE", "RU", "GB", "AU", "NL", "FR", "SG", "JP", "BR"] {
            XCTAssertNotNil(CountryCentroids.coordinate(for: code), "missing centroid for \(code)")
        }
        XCTAssertNil(CountryCentroids.coordinate(for: "XX"))
        XCTAssertNil(CountryCentroids.coordinate(for: ""))
        // Case-insensitive.
        XCTAssertNotNil(CountryCentroids.coordinate(for: "de"))
    }
}
