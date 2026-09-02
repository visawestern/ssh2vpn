import XCTest
@testable import VPNCore

final class FlowRouterTests: XCTestCase {
    func testFlowRemainsPinnedToItsTransport() {
        var router = FlowRouter(transportCount: 3)
        let first = router.transport(for: 42)
        XCTAssertEqual(router.transport(for: 42), first)
        XCTAssertTrue(router.isAssigned(42))
    }

    func testNewFlowsAreDistributedAcrossPool() {
        var router = FlowRouter(transportCount: 2)
        XCTAssertEqual(router.transport(for: 1), 0)
        XCTAssertEqual(router.transport(for: 2), 1)
        XCTAssertEqual(router.transport(for: 3), 0)
    }

    func testClosedFlowCanReceiveFreshAssignment() {
        var router = FlowRouter(transportCount: 2)
        let old = router.transport(for: 1)
        router.close(streamID: 1)
        XCTAssertFalse(router.isAssigned(1))
        XCTAssertEqual(router.transport(for: 1), (old + 1) % 2)
    }

    func testZeroTransportPoolStillHasSafeFallback() {
        var router = FlowRouter(transportCount: 0)
        XCTAssertEqual(router.transport(for: 7), 0)
    }
}
