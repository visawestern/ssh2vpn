import XCTest
@testable import VPNCore

final class VPNConfigurationBuilderTests: XCTestCase {

    // MARK: - Happy path

    func testBuildProducesValidConfiguration() throws {
        let config = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(
                host: "203.0.113.10", port: 22, username: "root",
                password: "sekret", hostKey: "AAAAB3NzaC1yc2E..."
            ),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )

        XCTAssertEqual(config.providerBundleIdentifier, "com.sshtunnel.app.packet-tunnel")
        XCTAssertEqual(config.serverAddress, "203.0.113.10")
        XCTAssertEqual(config.providerConfiguration["host"] as? String, "203.0.113.10")
        XCTAssertEqual(config.providerConfiguration["port"] as? Int, 22)
        XCTAssertEqual(config.providerConfiguration["username"] as? String, "root")
        XCTAssertEqual(config.providerConfiguration["hostKey"] as? String, "AAAAB3NzaC1yc2E...")
    }

    // MARK: - includeAllNetworks MUST be off (route conflict fix)

    func testIncludeAllNetworksIsOff() throws {
        let config = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        XCTAssertFalse(config.includeAllNetworks, "includeAllNetworks must be OFF so PacketTunnelProvider can install its own routes")
    }

    func testEnforceRoutesIsOn() throws {
        let config = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        XCTAssertTrue(config.enforceRoutes)
    }

    // MARK: - DNS passthrough

    func testDNSServersPassedThroughWhenPresent() throws {
        let config = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(
                host: "203.0.113.10", port: 22, username: "root", password: "x",
                dnsServers: ["1.1.1.1", "8.8.8.8"]
            ),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        let dns = config.providerConfiguration["dnsServers"] as? [String]
        XCTAssertEqual(dns, ["1.1.1.1", "8.8.8.8"])
    }

    func testDNSServersAbsentWhenEmpty() throws {
        let config = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        XCTAssertNil(config.providerConfiguration["dnsServers"])
    }

    // MARK: - HostKey optional

    func testHostKeyAbsentWhenEmpty() throws {
        let config = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        XCTAssertNil(config.providerConfiguration["hostKey"])
    }

    // MARK: - Host trimming

    func testHostIsTrimmedOfWhitespace() throws {
        let config = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "  203.0.113.10  ", port: 22, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        XCTAssertEqual(config.serverAddress, "203.0.113.10")
        XCTAssertEqual(config.providerConfiguration["host"] as? String, "203.0.113.10")
    }

    // MARK: - Validation edge cases

    func testEmptyHostThrows() {
        XCTAssertThrowsError(
            try VPNConfigurationBuilder.build(
                profile: VPNProfileInput(host: "", port: 22, username: "root", password: "x"),
                providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
            )
        ) { error in
            XCTAssertEqual(error as? VPNConfigurationError, .emptyHost)
        }
    }

    func testWhitespaceOnlyHostThrows() {
        XCTAssertThrowsError(
            try VPNConfigurationBuilder.build(
                profile: VPNProfileInput(host: "   \n ", port: 22, username: "root", password: "x"),
                providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
            )
        ) { error in
            XCTAssertEqual(error as? VPNConfigurationError, .emptyHost)
        }
    }

    func testPortTooSmallThrows() {
        XCTAssertThrowsError(
            try VPNConfigurationBuilder.build(
                profile: VPNProfileInput(host: "203.0.113.10", port: 0, username: "root", password: "x"),
                providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
            )
        ) { error in
            XCTAssertEqual(error as? VPNConfigurationError, .invalidPort)
        }
    }

    func testPortTooLargeThrows() {
        XCTAssertThrowsError(
            try VPNConfigurationBuilder.build(
                profile: VPNProfileInput(host: "203.0.113.10", port: 65536, username: "root", password: "x"),
                providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
            )
        ) { error in
            XCTAssertEqual(error as? VPNConfigurationError, .invalidPort)
        }
    }

    func testNegativePortThrows() {
        XCTAssertThrowsError(
            try VPNConfigurationBuilder.build(
                profile: VPNProfileInput(host: "203.0.113.10", port: -1, username: "root", password: "x"),
                providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
            )
        ) { error in
            XCTAssertEqual(error as? VPNConfigurationError, .invalidPort)
        }
    }

    func testMissingCredentialsThrows() {
        XCTAssertThrowsError(
            try VPNConfigurationBuilder.build(
                profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root"),
                providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
            )
        ) { error in
            XCTAssertEqual(error as? VPNConfigurationError, .missingCredentials)
        }
    }

    func testPrivateKeyCountsAsCredential() throws {
        _ = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", privateKey: "sk-ssh-ed25519 AAA..."),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
    }

    func testWhitespaceOnlyPrivateKeyDoesNotCount() {
        XCTAssertThrowsError(
            try VPNConfigurationBuilder.build(
                profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", privateKey: "   "),
                providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
            )
        ) { error in
            XCTAssertEqual(error as? VPNConfigurationError, .missingCredentials)
        }
    }

    func testEmptyBundleIdentifierThrows() {
        XCTAssertThrowsError(
            try VPNConfigurationBuilder.build(
                profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", password: "x"),
                providerBundleIdentifier: "  "
            )
        ) { error in
            XCTAssertEqual(error as? VPNConfigurationError, .emptyProviderBundleIdentifier)
        }
    }

    // MARK: - Equatable semantics

    func testConfigurationsAreEquatable() throws {
        let a = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        let b = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        XCTAssertEqual(a, b)
    }

    func testChangingPortChangesEquality() throws {
        let a = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        let b = try VPNConfigurationBuilder.build(
            profile: VPNProfileInput(host: "203.0.113.10", port: 2222, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        )
        XCTAssertNotEqual(a, b)
    }
}
