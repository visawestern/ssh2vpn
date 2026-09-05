import XCTest
@testable import VPNCore

/// Client-side SYN budget: decorative pings must never be able to trip the
/// VPS per-source rate limiter (~6 NEW/30s), no matter how bursts stack.
final class PingBudgetTests: XCTestCase {

    func testAllowsUpToMaxWithinWindow() {
        var t = Date()
        let b = PingBudget(maxEvents: 4, window: 30, now: { t })
        XCTAssertTrue(b.allow())
        XCTAssertTrue(b.allow())
        XCTAssertTrue(b.allow())
        XCTAssertTrue(b.allow())
        XCTAssertFalse(b.allow(), "5th ping inside the window must be denied")
        XCTAssertEqual(b.spent, 4)
    }

    func testWindowSlidesAndRefills() {
        var t = Date()
        let b = PingBudget(maxEvents: 2, window: 30, now: { t })
        XCTAssertTrue(b.allow())
        XCTAssertTrue(b.allow())
        XCTAssertFalse(b.allow())
        t = t.addingTimeInterval(31)
        XCTAssertTrue(b.allow(), "expired stamps must free the budget")
        XCTAssertTrue(b.allow())
        XCTAssertFalse(b.allow())
    }

    func testDefaultBudgetLeavesHeadroomForSSH() {
        // Server allows ~6/30s; budget defaults to 4 so two real SSH SYNs
        // always fit even right after a full UI burst.
        var t = Date()
        let b = PingBudget(now: { t })
        for _ in 0..<4 { XCTAssertTrue(b.allow()) }
        XCTAssertFalse(b.allow())
        _ = t
    }
}
