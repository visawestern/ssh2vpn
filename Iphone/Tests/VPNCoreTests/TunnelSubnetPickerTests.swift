import XCTest
@testable import VPNCore

/// Subnet occupancy: the tunnel /24 must never silently collide with a live
/// local network (iOS then drops our v4 settings with zero diagnostics).
final class TunnelSubnetPickerTests: XCTestCase {

    func testDisjointNetsDoNotOverlap() {
        let a = IPv4Net(string: "10.203.113.0", prefix: 24)!
        let b = IPv4Net(string: "192.168.8.0", prefix: 24)!
        XCTAssertFalse(a.overlaps(b))
        XCTAssertFalse(b.overlaps(a))
    }

    func testNestedNetsOverlapBothWays() {
        let small = IPv4Net(string: "10.203.113.0", prefix: 24)!
        let big = IPv4Net(string: "10.0.0.0", prefix: 8)!
        XCTAssertTrue(small.overlaps(big))
        XCTAssertTrue(big.overlaps(small))
    }

    func testAdjacentSlash24DoNotOverlap() {
        let a = IPv4Net(string: "10.203.113.0", prefix: 24)!
        let b = IPv4Net(string: "10.203.114.0", prefix: 24)!
        XCTAssertFalse(a.overlaps(b))
    }

    func testPicksPrimaryWhenFree() {
        let c = TunnelSubnetPicker.pick(brokerID: "phone-1", occupied: [
            IPv4Net(string: "192.168.8.0", prefix: 24)!,
        ])
        XCTAssertFalse(c.collided)
        XCTAssertEqual(c.net.prefix, 24)
        XCTAssertTrue(c.deviceAddress.hasSuffix(".2"))
    }

    func testFallsBackOnCollision() {
        let primary = TunnelSubnetPicker.candidates(brokerID: "phone-1")[0]
        // Occupy the primary with a big corporate /8.
        let c = TunnelSubnetPicker.pick(brokerID: "phone-1", occupied: [
            IPv4Net(string: "10.0.0.0", prefix: 8)!,
        ])
        XCTAssertFalse(c.collided)
        XCTAssertNotEqual(c.net, primary)
    }

    func testLastResortKeepsPrimaryWithFlag() {
        let c = TunnelSubnetPicker.pick(brokerID: "phone-1", occupied: [
            IPv4Net(string: "0.0.0.0", prefix: 0)!,
        ])
        XCTAssertTrue(c.collided)
    }

    func testCandidatesAreDeterministic() {
        XCTAssertEqual(
            TunnelSubnetPicker.candidates(brokerID: "abc"),
            TunnelSubnetPicker.candidates(brokerID: "abc")
        )
    }

    func testBadStringsRejected() {
        XCTAssertNil(IPv4Net(string: "10.203.h1.2", prefix: 24))
        XCTAssertNil(IPv4Net(string: "1.2.3", prefix: 24))
    }
}
