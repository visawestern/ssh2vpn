import XCTest
@testable import VPNCore

final class ConnectionBreakerTests: XCTestCase {

    func testTripsOnTenthConsecutiveFailure() {
        var b = ConnectionBreaker()
        for i in 1..<10 {
            XCTAssertFalse(b.recordFailure(), "failure \(i) must not trip")
        }
        XCTAssertTrue(b.recordFailure(), "10th consecutive failure trips")
        XCTAssertEqual(b.consecutiveFailures, 10)
        XCTAssertTrue(b.tripped)
    }

    func testTripsExactlyOnce() {
        var b = ConnectionBreaker(maxConsecutiveFailures: 2)
        XCTAssertFalse(b.recordFailure())
        XCTAssertTrue(b.recordFailure())
        XCTAssertFalse(b.recordFailure(), "already tripped — no second trip")
        XCTAssertFalse(b.recordFailure())
    }

    func testResetRearms() {
        var b = ConnectionBreaker(maxConsecutiveFailures: 2)
        b.recordFailure()
        XCTAssertTrue(b.recordFailure())
        b.reset()
        XCTAssertFalse(b.tripped)
        XCTAssertEqual(b.consecutiveFailures, 0)
        XCTAssertFalse(b.recordFailure())
        XCTAssertTrue(b.recordFailure(), "re-armed breaker trips again after 2")
    }

    func testCustomThreshold() {
        var b = ConnectionBreaker(maxConsecutiveFailures: 3)
        XCTAssertFalse(b.recordFailure())
        XCTAssertFalse(b.recordFailure())
        XCTAssertTrue(b.recordFailure())
    }

    func testThresholdClampedToAtLeastOne() {
        var b = ConnectionBreaker(maxConsecutiveFailures: 0)
        XCTAssertTrue(b.recordFailure(), "degenerate threshold trips on first failure")
    }
}
