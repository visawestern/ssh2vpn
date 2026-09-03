import XCTest
@testable import VPNCore

/// Tests the pure helpers that let the app tell OUR tunnel apart from stale or
/// foreign VPN profiles, and that decode why the system stopped the tunnel.
/// Both feed diagnostics; neither touches the network.
final class TunnelOwnershipTests: XCTestCase {

    // MARK: - Legacy profile classification

    func testLegacyBundleIDIsStale() {
        XCTAssertTrue(TunnelOwnership.isStaleLegacy(bundleID: "com.sshtunnel.app.packet-tunnel"))
    }

    func testCurrentBundleIDIsNotStale() {
        XCTAssertFalse(TunnelOwnership.isStaleLegacy(bundleID: "com.ssh2vpn.app.packet-tunnel"))
    }

    func testNilBundleIDIsNotStale() {
        XCTAssertFalse(TunnelOwnership.isStaleLegacy(bundleID: nil))
    }

    func testForeignBundleIDIsNotStale() {
        XCTAssertFalse(TunnelOwnership.isStaleLegacy(bundleID: "com.example.other-vpn"))
    }

    // MARK: - Stop reason decoding (NEProviderStopReason raw values)

    func testStopReasonNone() {
        XCTAssertEqual(TunnelStopReason.text(forRawValue: 0), "none")
    }

    func testStopReasonUserInitiated() {
        XCTAssertEqual(TunnelStopReason.text(forRawValue: 1), "userInitiated")
    }

    func testStopReasonProviderFailed() {
        XCTAssertEqual(TunnelStopReason.text(forRawValue: 2), "providerFailed")
    }

    func testStopReasonSuperceded() {
        // Superceded = a newer start replaced this tunnel. Key suspect when a
        // retry stacks startVPNTunnel calls on top of a live attempt.
        XCTAssertEqual(TunnelStopReason.text(forRawValue: 11), "superceded")
    }

    func testStopReasonConfigurationFailed() {
        XCTAssertEqual(TunnelStopReason.text(forRawValue: 7), "configurationFailed")
    }

    func testStopReasonUnknownFallsBackToNumber() {
        XCTAssertEqual(TunnelStopReason.text(forRawValue: 99), "unknown(99)")
    }
}
