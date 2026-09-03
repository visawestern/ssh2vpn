import XCTest
@testable import VPNCore

/// Tests the bounded retry budget used while waiting for system state — e.g.
/// a VPN profile being created after first-install consent: poll every 5s,
/// give up after 2 minutes (24 attempts).
final class RetryBudgetTests: XCTestCase {

    func testDefaultsCoverTwoMinutesAtFiveSecondPoll() {
        let budget = RetryBudget()
        XCTAssertEqual(budget.maxAttempts, 24)
        XCTAssertEqual(budget.intervalSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(budget.maxAttempts * Int(budget.intervalSeconds), 120)
    }

    func testConsumeYieldsTrueUntilExhausted() {
        var budget = RetryBudget(maxAttempts: 3, intervalSeconds: 5)
        XCTAssertTrue(budget.consume())
        XCTAssertTrue(budget.consume())
        XCTAssertTrue(budget.consume())
        XCTAssertFalse(budget.consume())
        XCTAssertFalse(budget.consume(), "exhausted budget stays exhausted")
    }

    func testRemainingCountsDown() {
        var budget = RetryBudget(maxAttempts: 3, intervalSeconds: 5)
        XCTAssertEqual(budget.remaining, 3)
        _ = budget.consume()
        XCTAssertEqual(budget.remaining, 2)
        _ = budget.consume()
        _ = budget.consume()
        XCTAssertEqual(budget.remaining, 0)
    }
}
