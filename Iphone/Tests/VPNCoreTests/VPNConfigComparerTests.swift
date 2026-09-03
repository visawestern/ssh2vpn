import XCTest
@testable import VPNCore

/// Tests the "such config already exists?" check: before rewriting the system
/// VPN configuration on every connect, the app compares the live protocol
/// values with the desired ones and reuses the stored config when identical.
/// Pure dictionaries/strings here — no NetworkExtension, fully testable.
final class VPNConfigComparerTests: XCTestCase {

    private func snapshot(
        bundleID: String = "com.ssh2vpn.app.packet-tunnel",
        server: String = "1.2.3.4",
        enforceRoutes: Bool = true,
        isEnabled: Bool = true,
        config: [String: Any]? = nil
    ) -> VPNProtocolSnapshot {
        VPNProtocolSnapshot(
            providerBundleIdentifier: bundleID,
            serverAddress: server,
            enforceRoutes: enforceRoutes,
            isEnabled: isEnabled,
            providerConfiguration: config ?? [
                "host": "1.2.3.4",
                "port": 22,
                "username": "root",
                "password": "sekret"
            ]
        )
    }

    func testIdenticalSnapshotsMatch() {
        XCTAssertTrue(VPNConfigComparer.isSame(current: snapshot(), desired: snapshot()))
    }

    func testDifferentHostDoesNotMatch() {
        XCTAssertFalse(VPNConfigComparer.isSame(current: snapshot(), desired: snapshot(server: "9.9.9.9")))
    }

    func testDifferentBundleIDDoesNotMatch() {
        XCTAssertFalse(VPNConfigComparer.isSame(current: snapshot(), desired: snapshot(bundleID: "com.sshtunnel.app.packet-tunnel")))
    }

    func testDisabledManagerDoesNotMatch() {
        XCTAssertFalse(VPNConfigComparer.isSame(current: snapshot(isEnabled: false), desired: snapshot()))
    }

    func testDifferentPasswordDoesNotMatch() {
        var desired = snapshot()
        desired.providerConfiguration["password"] = "other"
        XCTAssertFalse(VPNConfigComparer.isSame(current: snapshot(), desired: desired))
    }

    func testAddedHostKeyDoesNotMatch() {
        var desired = snapshot()
        desired.providerConfiguration["hostKey"] = "AAAAB3"
        XCTAssertFalse(VPNConfigComparer.isSame(current: snapshot(), desired: desired))
    }

    func testDifferentDNSDoesNotMatch() {
        var withDNS = snapshot()
        withDNS.providerConfiguration["dnsServers"] = ["8.8.8.8"]
        XCTAssertFalse(VPNConfigComparer.isSame(current: snapshot(), desired: withDNS))
    }

    func testSameDNSMatches() {
        var a = snapshot()
        a.providerConfiguration["dnsServers"] = ["8.8.8.8", "1.1.1.1"]
        var b = snapshot()
        b.providerConfiguration["dnsServers"] = ["8.8.8.8", "1.1.1.1"]
        XCTAssertTrue(VPNConfigComparer.isSame(current: a, desired: b))
    }

    func testPlistRoundTripStillMatches() {
        // The stored side round-trips through preferences (plist): Ints become
        // NSNumbers, arrays NSArrays. Equality must survive that.
        let original = snapshot()
        let data = try! PropertyListSerialization.data(fromPropertyList: original.providerConfiguration, format: .binary, options: 0)
        let revived = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        var stored = snapshot()
        stored.providerConfiguration = revived
        XCTAssertTrue(VPNConfigComparer.isSame(current: stored, desired: original))
    }
}
