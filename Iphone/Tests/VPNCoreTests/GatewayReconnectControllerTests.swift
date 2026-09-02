import Foundation
import XCTest
@testable import VPNCore

/// Tests the reconnect/ready decision engine (extracted from the App layer).
/// This is the heart of chains C1 (connect), C6 (reconnect), and C13
/// (reconnect <-> network). The controller is a pure value type so every
/// branch is unit-testable in CI — the original App-layer code cannot be.
///
/// Decision contract (mirrors SSHPacketTunnelTransport):
///   - reportReady exactly once, on first authenticated session;
///   - pre-ready: only scheduleReconnect when nothing is left to avoid stacking;
///   - post-ready: every loss tops back up;
///   - pre-ready exhaustion (all initial attempts failed, nothing pending): fail.
final class GatewayReconnectControllerTests: XCTestCase {
    private func makeController(desired: Int = 3) -> GatewayReconnectController {
        GatewayReconnectController(desiredSessionCount: desired)
    }

    // MARK: - report ready

    func testReportsReadyOnFirstAuthenticatedSession() {
        var c = makeController()
        XCTAssertEqual(c.sessionAuthenticated(), .reportReady)
        XCTAssertTrue(c.didReportReady)
        XCTAssertEqual(c.reconnectAttempt, 0)
    }

    func testDoesNotReportReadyTwice() {
        var c = makeController()
        _ = c.sessionAuthenticated()
        XCTAssertEqual(c.sessionAuthenticated(), .noOp)
    }

    func testReportReadyResetsReconnectAttempt() {
        var c = makeController()
        c.reconnectAttempt = 5
        _ = c.sessionAuthenticated()
        XCTAssertEqual(c.reconnectAttempt, 0)
    }

    // MARK: - pre-ready initial failures

    func testPreReadyFailureWithSessionsPendingDoesNotSchedule() {
        var c = makeController(desired: 3)
        c.sessions = 1 // one session still opening
        XCTAssertEqual(c.initialAttemptFailed(isFatal: false), .noOp)
        XCTAssertEqual(c.initialAttemptsCompleted, 1)
    }

    func testPreReadyFailureEmptySchedulesReconnectIfBudgetRemains() {
        var c = makeController(desired: 3)
        // first of 3 fails, nothing pending, budget remains
        XCTAssertEqual(c.initialAttemptFailed(isFatal: false), .scheduleReconnect)
        XCTAssertTrue(c.reconnectScheduled)
    }

    func testPreReadyExhaustionFails() {
        var c = makeController(desired: 2)
        XCTAssertEqual(c.initialAttemptFailed(isFatal: false), .scheduleReconnect)
        XCTAssertEqual(c.initialAttemptFailed(isFatal: false), .failTransport)
        XCTAssertEqual(c.state, .failed(.transport))
    }

    func testFatalInitialAttemptFailsImmediately() {
        var c = makeController()
        XCTAssertEqual(c.initialAttemptFailed(isFatal: true), .failAuthentication)
        XCTAssertEqual(c.state, .failed(.authentication))
    }

    // MARK: - post-ready session loss

    func testPostReadyEveryLossSchedulesReconnect() {
        var c = makeController()
        _ = c.sessionAuthenticated()
        c.sessions = 3
        XCTAssertEqual(c.sessionLost(), .scheduleReconnect)
        XCTAssertTrue(c.reconnectScheduled)
    }

    func testPostReadyLossKeepsFailingOver() {
        var c = makeController()
        _ = c.sessionAuthenticated()
        c.sessions = 1
        _ = c.markReconnectScheduled()
        // reconnect fires, opens new session which also dies
        c.reconnectFired()
        XCTAssertEqual(c.sessionLost(), .scheduleReconnect)
    }

    // MARK: - pre-ready session loss

    func testPreReadyLossWithSessionsPendingDoesNotSchedule() {
        var c = makeController()
        c.sessions = 2
        XCTAssertEqual(c.sessionLost(), .noOp)
        XCTAssertFalse(c.reconnectScheduled)
    }

    func testPreReadyLossEmptySchedulesReconnect() {
        var c = makeController()
        c.setSessions(0) // post-removal: no sessions left
        XCTAssertEqual(c.sessionLost(), .scheduleReconnect)
        XCTAssertTrue(c.reconnectScheduled)
    }

    // MARK: - reconnect scheduling guards

    func testNoScheduleWhenStopped() {
        var c = makeController()
        c.isStopped = true
        XCTAssertEqual(c.initialAttemptFailed(isFatal: false), .noOp)
        XCTAssertFalse(c.reconnectScheduled)
    }

    func testNoDoubleSchedule() {
        var c = makeController()
        XCTAssertEqual(c.initialAttemptFailed(isFatal: false), .scheduleReconnect)
        // second attempt while one is already scheduled → noOp
        XCTAssertEqual(c.initialAttemptFailed(isFatal: false), .noOp)
    }

    func testReconnectFiredClearsScheduledFlag() {
        var c = makeController()
        _ = c.initialAttemptFailed(isFatal: false)
        XCTAssertTrue(c.reconnectScheduled)
        c.reconnectFired()
        XCTAssertFalse(c.reconnectScheduled)
        XCTAssertEqual(c.reconnectAttempt, 1)
    }

    // MARK: - reconnect attempt increment

    func testScheduleReconnectIncrementsAttempt() {
        var c = makeController(desired: 3)
        _ = c.initialAttemptFailed(isFatal: false)
        XCTAssertEqual(c.reconnectAttempt, 1)
        c.reconnectFired()
        // after fire, a new schedule increments again
        _ = c.sessionLost()
        XCTAssertEqual(c.reconnectAttempt, 2)
    }

    // MARK: - stopped suppresses everything

    func testStoppedIgnoresAuthentication() {
        var c = makeController()
        c.isStopped = true
        XCTAssertEqual(c.sessionAuthenticated(), .noOp)
        XCTAssertFalse(c.didReportReady)
    }

    func testStoppedIgnoresSessionLoss() {
        var c = makeController()
        _ = c.sessionAuthenticated()
        c.isStopped = true
        c.sessions = 2
        XCTAssertEqual(c.sessionLost(), .noOp)
        XCTAssertFalse(c.reconnectScheduled)
    }
}
