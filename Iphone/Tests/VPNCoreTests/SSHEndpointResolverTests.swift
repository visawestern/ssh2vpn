import XCTest
@testable import VPNCore

final class SSHEndpointResolverTests: XCTestCase {
    func testResolvesLocalhostToAtLeastOneAddress() throws {
        let endpoint = try SSHEndpointResolver.resolve("localhost")
        XCTAssertFalse(endpoint.ipv4.isEmpty && endpoint.ipv6.isEmpty)
    }

    func testRejectsUnresolvableHost() {
        XCTAssertThrowsError(try SSHEndpointResolver.resolve("vpn.invalid")) { error in
            XCTAssertEqual(error as? SSHEndpointResolverError, .cannotResolve)
        }
    }

    func testPrimaryTargetPrefersIPv4OverIPv6() {
        let endpoint = SSHResolvedEndpoint(ipv4: ["203.0.113.5", "203.0.113.6"], ipv6: ["2001:db8::1"])
        XCTAssertEqual(endpoint.primaryTarget(), "203.0.113.5")
    }

    func testPrimaryTargetFallsBackToIPv6() {
        let endpoint = SSHResolvedEndpoint(ipv4: [], ipv6: ["2001:db8::1"])
        XCTAssertEqual(endpoint.primaryTarget(), "2001:db8::1")
    }

    func testPrimaryTargetEmptyEndpointIsNil() {
        XCTAssertNil(SSHResolvedEndpoint(ipv4: [], ipv6: []).primaryTarget())
    }
}
