import XCTest
@testable import VPNCore

/// Tests the pure verdict logic of the post-connect self-test: given the IP
/// the traffic should egress from (the VPS) and the IP actually observed via
/// a known echo service, decide whether we go through the server or bypass it.
/// No networking here — the HTTP probing lives in the app target.
final class TunnelSelfTestTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeTrimsWhitespaceAndLowercases() {
        XCTAssertEqual(TunnelSelfTest.normalizeIP("  192.0.2.44\n"), "192.0.2.44")
    }

    func testNormalizeStripsIPv6Brackets() {
        XCTAssertEqual(TunnelSelfTest.normalizeIP("[2001:db8::1]"), "2001:db8::1")
    }

    // MARK: - verdict

    func testMatchingIPsMeansViaServer() {
        XCTAssertEqual(
            TunnelSelfTest.evaluate(expected: "192.250.228.44", observed: "192.250.228.44\n"),
            .viaServer
        )
    }

    func testDifferentIPMeansBypass() {
        XCTAssertEqual(
            TunnelSelfTest.evaluate(expected: "192.250.228.44", observed: "85.140.10.5"),
            .bypass(observed: "85.140.10.5")
        )
    }

    func testEmptyResponseIsUnparseable() {
        XCTAssertEqual(
            TunnelSelfTest.evaluate(expected: "192.250.228.44", observed: "   \n"),
            .unparseable(reason: "empty response")
        )
    }

    func testGarbageResponseIsUnparseable() {
        XCTAssertEqual(
            TunnelSelfTest.evaluate(expected: "192.250.228.44", observed: "<html>nope</html>"),
            .unparseable(reason: "not an IP literal")
        )
    }

    func testNilExpectedIsUnknown() {
        XCTAssertEqual(
            TunnelSelfTest.evaluate(expected: nil, observed: "85.140.10.5"),
            .unknownExpected
        )
    }

    // MARK: - expected IP picking

    func testLiteralIPv4HostIsUsedDirectly() {
        XCTAssertEqual(TunnelSelfTest.pickExpected(host: "192.250.228.44", resolvedIPv4: []), "192.250.228.44")
    }

    func testHostnameUsesResolvedIPv4() {
        XCTAssertEqual(TunnelSelfTest.pickExpected(host: "vps.example.com", resolvedIPv4: ["203.0.113.7"]), "203.0.113.7")
    }

    func testUnresolvableHostnameYieldsNil() {
        XCTAssertNil(TunnelSelfTest.pickExpected(host: "vps.example.com", resolvedIPv4: []))
    }

    // MARK: - server-reported egress (SSHExecCheck, no third party on-phone)

    func testParseFullReport() {
        let r = SSHExecCheck.parse("IP:192.250.228.44\nWEB:204\n")
        XCTAssertEqual(r.ip, "192.250.228.44")
        XCTAssertEqual(r.web, "204")
    }

    func testParseToleratesCRLFAndWhitespace() {
        let r = SSHExecCheck.parse("  IP: 1.2.3.4 \r\nWEB: none\r\n")
        XCTAssertEqual(r.ip, "1.2.3.4")
        XCTAssertEqual(r.web, "none")
    }

    func testParseEmptyMeansUnverified() {
        let r = SSHExecCheck.parse("")
        XCTAssertNil(r.ip)
        XCTAssertNil(r.web)
    }

    func testParseIgnoresExtraLines() {
        let r = SSHExecCheck.parse("some motd line\nIP:9.9.9.9\nanother\nWEB:204\n")
        XCTAssertEqual(r.ip, "9.9.9.9")
        XCTAssertEqual(r.web, "204")
    }

    func testBannerRecognition() {
        XCTAssertTrue(SSHExecCheck.looksLikeSSHBanner(Data("SSH-2.0-OpenSSH_9.6\r\n".utf8)))
        XCTAssertFalse(SSHExecCheck.looksLikeSSHBanner(Data("HTTP/1.1 200 OK\r\n".utf8)))
        XCTAssertFalse(SSHExecCheck.looksLikeSSHBanner(Data()))
    }
}
