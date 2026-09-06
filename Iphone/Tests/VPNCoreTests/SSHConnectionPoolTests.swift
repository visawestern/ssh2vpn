import XCTest
@testable import VPNCore

final class SSHPoolPolicyTests: XCTestCase {

    private let policy = SSHPoolPolicy(maxConnections: 4, channelsPerConnection: 4)

    func testFirstFlowLandsOnFirstConnection() {
        XCTAssertEqual(policy.plan(inFlight: [0]), 0)
    }

    func testLeastLoadedConnectionWins() {
        XCTAssertEqual(policy.plan(inFlight: [5, 2, 7]), 1, "flow goes to the least-loaded connection")
        XCTAssertEqual(policy.plan(inFlight: [3, 3]), 0, "tie -> first")
    }

    func testDesiredConnectionsScalesWithLoad() {
        XCTAssertEqual(policy.desiredConnections(totalInFlight: 0), 1)
        XCTAssertEqual(policy.desiredConnections(totalInFlight: 1), 1)
        XCTAssertEqual(policy.desiredConnections(totalInFlight: 4), 1)
        XCTAssertEqual(policy.desiredConnections(totalInFlight: 5), 2, "5th concurrent channel warrants connection #2")
        XCTAssertEqual(policy.desiredConnections(totalInFlight: 9), 3)
        XCTAssertEqual(policy.desiredConnections(totalInFlight: 13), 4)
    }

    func testDesiredConnectionsCappedAtMax() {
        XCTAssertEqual(policy.desiredConnections(totalInFlight: 100), 4)
    }

    func testCustomCapsAreRespected() {
        let p = SSHPoolPolicy(maxConnections: 2, channelsPerConnection: 1)
        XCTAssertEqual(p.desiredConnections(totalInFlight: 1), 1)
        XCTAssertEqual(p.desiredConnections(totalInFlight: 2), 2)
        XCTAssertEqual(p.desiredConnections(totalInFlight: 99), 2, "max=2 — never a third")
    }
}


