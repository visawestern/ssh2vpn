import XCTest
@testable import VPNCore

final class TunnelDeviceTests: XCTestCase {
    func testDeriveMatchesGatewayGoldenValues() throws {
        let device = try TunnelDevice.derive(brokerID: "testbroker")
        XCTAssertEqual(device.gatewayIPv4, "10.203.49.46.1")
        XCTAssertEqual(device.ipv4Address, "10.203.49.46.2")
        XCTAssertEqual(device.ipv6Address, "fd00:203:312e::2")
    }

    func testDeriveIsDeterministicPerBroker() throws {
        let first = try TunnelDevice.derive(brokerID: "device42")
        let second = try TunnelDevice.derive(brokerID: "device42")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.ipv4Address, "10.203.26.1.2")
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
}