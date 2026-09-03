import XCTest
@testable import VPNCore

final class TunnelDeviceTests: XCTestCase {
    func testDeriveMatchesGatewayGoldenValues() throws {
        // testbroker -> h1=49, h2=46, base=46&0xFC=44: /30 subnet 10.203.49.44,
        // gateway .45, device .46. Must match gateway.py subnet_for_broker.
        let device = try TunnelDevice.derive(brokerID: "testbroker")
        XCTAssertEqual(device.gatewayIPv4, "10.203.49.45")
        XCTAssertEqual(device.ipv4Address, "10.203.49.46")
        XCTAssertEqual(device.ipv6Address, "fd00:203:312e::2")
    }

    func testDeriveIsDeterministicPerBroker() throws {
        let first = try TunnelDevice.derive(brokerID: "device42")
        let second = try TunnelDevice.derive(brokerID: "device42")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.ipv4Address, "10.203.26.2")
    }

    func testDistinctBrokersGetDistinctIPv4Addresses() throws {
        let a = try TunnelDevice.derive(brokerID: "testbroker")
        let b = try TunnelDevice.derive(brokerID: "device42")
        XCTAssertNotEqual(a.ipv4Address, b.ipv4Address)
    }

    func testStaticAddressingConstants() {
        XCTAssertEqual(TunnelDevice.v4SubnetMask, "255.255.255.252")
        XCTAssertEqual(TunnelDevice.v6PrefixLength, 64)
    }

    func testEmptyBrokerIDThrows() {
        XCTAssertThrowsError(try TunnelDevice.derive(brokerID: "")) { error in
            XCTAssertEqual(error as? TunnelDeviceError, .invalidBrokerID)
        }
    }

    /// Regression: five-octet strings ("10.203.h1.h2.2") are not IPv4 and made
    /// iOS silently drop the v4 tunnel settings (all IPv4 bypassed the tunnel).
    /// Gateway and device must be valid 4-octet hosts of the same /30.
    func testDerivedAddressesAreValidHostsOfOneSlash30() throws {
        for broker in ["testbroker", "device42", "a", "phone-1", "zzz-last"] {
            let device = try TunnelDevice.derive(brokerID: broker)
            let gw = try XCTUnwrap(parseIPv4(device.gatewayIPv4), "gateway must parse: \(device.gatewayIPv4)")
            let dev = try XCTUnwrap(parseIPv4(device.ipv4Address), "device must parse: \(device.ipv4Address)")
            XCTAssertEqual(gw[0..<3], dev[0..<3], "same /24 for \(broker)")
            XCTAssertEqual(gw[3] % 4, 1, "gateway is .1 of its /30 for \(broker)")
            XCTAssertEqual(dev[3], gw[3] + 1, "device is gateway+1 for \(broker)")
        }
    }

    private func parseIPv4(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}