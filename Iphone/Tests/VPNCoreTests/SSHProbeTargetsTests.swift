import XCTest
@testable import VPNCore

final class SSHProbeTargetsTests: XCTestCase {

    func testUserDNSGoesFirst() {
        let targets = SSHProbeTargets.ordered(userDNS: ["9.9.9.9"])
        XCTAssertEqual(targets.first?.host, "9.9.9.9")
        XCTAssertEqual(targets.first?.port, 53)
    }

    func testDuplicatesRemovedKeepingFirstPosition() {
        // User DNS duplicating a default must not probe twice; user position wins.
        let targets = SSHProbeTargets.ordered(userDNS: ["8.8.8.8", "8.8.8.8", "  "])
        let keys = targets.map { "\($0.host):\($0.port)" }
        XCTAssertEqual(keys.filter { $0 == "8.8.8.8:53" }.count, 1, "no duplicate probe")
        XCTAssertEqual(targets.first?.host, "8.8.8.8", "user DNS keeps first position")
        XCTAssertEqual(targets.count, SSHProbeTargets.defaultPublicTargets.count)
        XCTAssertTrue(keys.contains("1.1.1.1:443"), "whitelist-only-80/443 networks need a :443-class target")
    }

    func testEmptyUserDNSFallsBackToDefaults() {
        let targets = SSHProbeTargets.ordered(userDNS: [])
        XCTAssertEqual(targets.count, SSHProbeTargets.defaultPublicTargets.count)
        XCTAssertEqual(targets.map(\.host), SSHProbeTargets.defaultPublicTargets.map(\.host))
    }

    func testDifferentClassesPresent() {
        let targets = SSHProbeTargets.ordered(userDNS: [])
        let ports = Set(targets.map(\.port))
        XCTAssertTrue(ports.contains(53) && ports.contains(443), "chain must span more than one port class")
        XCTAssertGreaterThanOrEqual(Set(targets.map(\.host)).count, 3, "chain must span several operators")
    }

    func testLocalhostFallbackIsLoopbackSSH() {
        XCTAssertEqual(SSHProbeTargets.localhostFallback.host, "127.0.0.1")
        XCTAssertEqual(SSHProbeTargets.localhostFallback.port, 22)
    }
}
