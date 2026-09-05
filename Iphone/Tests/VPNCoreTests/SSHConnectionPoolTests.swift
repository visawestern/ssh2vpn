import XCTest
@testable import VPNCore

final class SSHPoolPolicyTests: XCTestCase {

    private let policy = SSHPoolPolicy(maxConnections: 4, channelsPerConnection: 8)

    func testFirstFlowLandsOnFirstConnection() {
        let plan = policy.plan(inFlight: [0])
        XCTAssertEqual(plan.index, 0)
        XCTAssertFalse(plan.grow, "single idle connection never grows the pool")
    }

    func testLeastLoadedConnectionWins() {
        let plan = policy.plan(inFlight: [5, 2, 7])
        XCTAssertEqual(plan.index, 1, "flow goes to the least-loaded connection")
        XCTAssertFalse(plan.grow, "a connection below the cap absorbs new flows")
    }

    func testGrowsOnlyWhenEveryConnectionSaturated() {
        let plan = policy.plan(inFlight: [8, 8])
        XCTAssertTrue(plan.grow, "all connections at cap -> grow")
        XCTAssertEqual(plan.index, 0, "meanwhile the flow still gets a connection (tie -> first)")

        let notYet = policy.plan(inFlight: [8, 7])
        XCTAssertFalse(notYet.grow, "ONE connection below the cap absorbs the flow — no growth")
    }

    func testNeverGrowsPastMax() {
        let plan = policy.plan(inFlight: [9, 9, 9, 9])
        XCTAssertFalse(plan.grow, "pool is at max — stay at 4 connections even when packed")
    }

    func testSingleSaturatedConnectionGrowsToTwo() {
        let plan = policy.plan(inFlight: [8])
        XCTAssertTrue(plan.grow, "first connection at cap -> open the second")
    }

    func testCustomCapsAreRespected() {
        let p = SSHPoolPolicy(maxConnections: 2, channelsPerConnection: 1)
        XCTAssertTrue(p.plan(inFlight: [1]).grow)
        XCTAssertFalse(p.plan(inFlight: [1, 1]).grow, "max=2 reached — no third connection")
    }
}

/// The default policy must match the documented server-side budget: OpenSSH
/// MaxSessions defaults to 10, so 4 connections x 8 channels stays safely
/// below any sane sshd config while quadrupling throughput.
final class SSHPoolPolicyDefaultsTests: XCTestCase {
    func testDefaults() {
        let p = SSHPoolPolicy()
        XCTAssertEqual(p.maxConnections, 4)
        XCTAssertEqual(p.channelsPerConnection, 8)
    }
}
