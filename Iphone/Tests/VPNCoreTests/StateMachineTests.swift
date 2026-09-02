import XCTest
@testable import VPNCore

final class StateMachineTests: XCTestCase {
    func testHappyPath() {
        var machine = TunnelStateMachine()
        XCTAssertTrue(machine.start())
        XCTAssertTrue(machine.handshakeStarted())
        XCTAssertTrue(machine.connected())
        XCTAssertEqual(machine.state, .connected)
    }

    func testRejectsConnectedBeforeHandshake() {
        var machine = TunnelStateMachine()
        XCTAssertFalse(machine.connected())
        XCTAssertEqual(machine.state, .disconnected)
    }

    func testReconnectPreservesExplicitAttempt() {
        var machine = TunnelStateMachine()
        _ = machine.start()
        _ = machine.handshakeStarted()
        _ = machine.connected()
        XCTAssertTrue(machine.lostConnection(attempt: 3))
        XCTAssertEqual(machine.state, .reconnecting(attempt: 3))
    }

    func testBackoffIsBoundedAndNeverNegative() {
        let policy = ReconnectPolicy(baseDelay: 1, maxDelay: 8, jitter: 0.2)
        XCTAssertEqual(policy.delay(for: 1, randomUnit: 0), 0.8, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(for: 99, randomUnit: 1), 9.6, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(policy.delay(for: -1, randomUnit: 0), 0)
    }
}
