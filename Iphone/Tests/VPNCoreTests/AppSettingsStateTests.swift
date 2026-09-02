import XCTest
@testable import VPNCore

final class AppSettingsStateTests: XCTestCase {

    // MARK: - Defaults

    func testDefaults() {
        let s = AppSettingsState()
        XCTAssertEqual(s.protocolName, "SSH2")
        XCTAssertEqual(s.useCustomDNS, false)
        XCTAssertEqual(s.primaryDNS, "1.1.1.1")
        XCTAssertEqual(s.secondaryDNS, "8.8.8.8")
        XCTAssertEqual(s.killSwitch, true)
        XCTAssertEqual(s.connectOnDemand, false)
        XCTAssertEqual(s.enableLogging, false)
    }

    // MARK: - resolvedDNSServers

    func testResolvedDNSIsEmptyWhenCustomDisabled() {
        let s = AppSettingsState(useCustomDNS: false, primaryDNS: "9.9.9.9", secondaryDNS: "1.1.1.1")
        XCTAssertEqual(s.resolvedDNSServers, [])
    }

    func testResolvedDNSIncludesBothWhenEnabled() {
        let s = AppSettingsState(useCustomDNS: true, primaryDNS: "9.9.9.9", secondaryDNS: "1.1.1.1")
        XCTAssertEqual(s.resolvedDNSServers, ["9.9.9.9", "1.1.1.1"])
    }

    func testResolvedDNSFiltersEmptyWhenEnabled() {
        let s = AppSettingsState(useCustomDNS: true, primaryDNS: "   ", secondaryDNS: "1.1.1.1")
        XCTAssertEqual(s.resolvedDNSServers, ["1.1.1.1"])
    }

    func testResolvedDNSFiltersBothEmpty() {
        let s = AppSettingsState(useCustomDNS: true, primaryDNS: "", secondaryDNS: "")
        XCTAssertEqual(s.resolvedDNSServers, [])
    }

    // MARK: - Mutability (in-place)

    func testSettingsAreStructurallyMutableInPlace() {
        var s = AppSettingsState()
        s.protocolName = "SSH"
        s.useCustomDNS = true
        s.primaryDNS = "77.88.8.8"
        s.secondaryDNS = "77.88.8.1"
        s.killSwitch = false
        s.connectOnDemand = true
        s.enableLogging = true

        XCTAssertEqual(s.protocolName, "SSH")
        XCTAssertEqual(s.useCustomDNS, true)
        XCTAssertEqual(s.primaryDNS, "77.88.8.8")
        XCTAssertEqual(s.secondaryDNS, "77.88.8.1")
        XCTAssertEqual(s.killSwitch, false)
        XCTAssertEqual(s.connectOnDemand, true)
        XCTAssertEqual(s.enableLogging, true)
    }

    func testProtocolValidationAllowsKnownValues() {
        let s = AppSettingsState(protocolName: "SSH2")
        XCTAssertEqual(s.protocolName, "SSH2")
    }

    // MARK: - Codec round-trip

    func testCodecRoundTripPreservesAllFields() throws {
        let original = AppSettingsState(
            protocolName: "SSH",
            useCustomDNS: true,
            primaryDNS: "9.9.9.9",
            secondaryDNS: "149.112.112.112",
            killSwitch: false,
            connectOnDemand: true,
            enableLogging: true
        )
        let data = try AppSettingsCodec.encode(original)
        let decoded = try AppSettingsCodec.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testCodecRoundTripForDefaults() throws {
        let original = AppSettingsState()
        let decoded = try AppSettingsCodec.decode(try AppSettingsCodec.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testDecodeCorruptDataThrows() {
        let corrupt = Data("not json".utf8)
        XCTAssertThrowsError(try AppSettingsCodec.decode(corrupt)) { error in
            XCTAssertEqual(error as? AppSettingsError, .decodingFailed)
        }
    }

    func testDecodePartialDictionaryUsesDefaults() throws {
        // Only protocol present -> defaults fill the rest.
        let data = try JSONSerialization.data(withJSONObject: ["protocol": "SSH"])
        let decoded = try AppSettingsCodec.decode(data)
        XCTAssertEqual(decoded.protocolName, "SSH")
        XCTAssertEqual(decoded.useCustomDNS, false)
        XCTAssertEqual(decoded.primaryDNS, "1.1.1.1")
        XCTAssertEqual(decoded.killSwitch, true)
    }
}
