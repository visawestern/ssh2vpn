import Foundation
import XCTest
@testable import VPNCore

/// Tests Chapter 6 item 104: wildcard /32 and /128 exclude. The kill switch must
/// exclude each resolved VPS IP as a single-host route (not a wider range) so
/// the SSH control channel stays outside the tunnel. Pure logic for chain C8.
final class GatewayExcludedRoutesTests: XCTestCase {
    // MARK: - p.104: single-host excludes

    func testIPv4ExcludeUsesHostRoute() {
        let route = GatewayExcludedRoutes.exclude(ip: "203.0.113.5", family: .ipv4)
        XCTAssertEqual(route?.subnetMask, "255.255.255.255")
    }

    func testIPv6ExcludeUsesHostRoute() {
        let route = GatewayExcludedRoutes.exclude(ip: "2001:db8::1", family: .ipv6)
        XCTAssertEqual(route?.prefixLength, 128)
    }

    // MARK: - address family detection

    func testDetectsIPv4() {
        XCTAssertEqual(GatewayExcludedRoutes.family(of: "192.0.2.1"), .ipv4)
        XCTAssertEqual(GatewayExcludedRoutes.family(of: "10.0.0.1"), .ipv4)
    }

    func testDetectsIPv6() {
        XCTAssertEqual(GatewayExcludedRoutes.family(of: "2001:db8::1"), .ipv6)
        XCTAssertEqual(GatewayExcludedRoutes.family(of: "::1"), .ipv6)
    }

    func testInvalidAddressReturnsNil() {
        XCTAssertNil(GatewayExcludedRoutes.family(of: "not-an-ip"))
        XCTAssertNil(GatewayExcludedRoutes.family(of: ""))
    }

    // MARK: - excludes from resolved endpoint

    func testExcludesAllResolvedIPs() {
        let endpoint = SSHResolvedEndpoint(ipv4: ["203.0.113.5", "203.0.113.6"], ipv6: ["2001:db8::1"])
        let routes = GatewayExcludedRoutes.excludes(for: endpoint)
        XCTAssertEqual(routes.count, 3)
        XCTAssertTrue(routes.contains { $0.subnetMask == "255.255.255.255" })
        XCTAssertTrue(routes.contains { $0.prefixLength == 128 })
    }

    func testEmptyEndpointYieldsNoRoutes() {
        let endpoint = SSHResolvedEndpoint(ipv4: [], ipv6: [])
        XCTAssertTrue(GatewayExcludedRoutes.excludes(for: endpoint).isEmpty)
    }
}
