import XCTest
@testable import VPNCore

/// Tests the duplicate-burst gate for tunnel status logging. The system (and
/// stale profiles) can post the same NEVPNStatus several times within
/// milliseconds; the dump must show each distinct transition but collapse
/// identical bursts so a real death isn't buried in noise.
final class TunnelLogDedupeTests: XCTestCase {

    func testFirstEventAlwaysLogs() {
        XCTAssertTrue(TunnelLogDedupe.shouldLog(current: 1, last: nil, lastAt: nil, now: Date()))
    }

    func testDifferentStatusAlwaysLogs() {
        let now = Date()
        XCTAssertTrue(TunnelLogDedupe.shouldLog(current: 2, last: 1, lastAt: now, now: now))
    }

    func testSameStatusInsideWindowIsSuppressed() {
        let now = Date()
        XCTAssertFalse(TunnelLogDedupe.shouldLog(current: 2, last: 2, lastAt: now, now: now.addingTimeInterval(0.05)))
    }

    func testSameStatusAfterWindowLogsAgain() {
        let now = Date()
        XCTAssertTrue(TunnelLogDedupe.shouldLog(current: 2, last: 2, lastAt: now, now: now.addingTimeInterval(10)))
    }
}
