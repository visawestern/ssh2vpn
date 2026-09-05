import XCTest
@testable import VPNCore

final class AdQuotaTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFreshInstallHasThreeFreeHours() {
        let q = AdQuota()
        XCTAssertEqual(q.remainingSeconds, 3 * 3600, accuracy: 0.5)
    }

    func testFreeTimeDrainsBeforeBankedCredit() {
        var q = AdQuota(bankedSeconds: 3600)
        q.consume(100)
        XCTAssertEqual(q.remainingSeconds, 3 * 3600 + 3600 - 100, accuracy: 0.5)
        // Free grant crosses zero, bank takes the rest.
        q.consume(AdQuota.freeAllowance - 100 + 60)
        XCTAssertEqual(q.remainingSeconds, 3600 - 60, accuracy: 0.5,
                       "after the free 3h, the banked credit drains")
    }

    func testFirstAdAlwaysAllowedAndAddsThreeHours() {
        var q = AdQuota()
        XCTAssertTrue(q.canWatchAd(now: t0))
        XCTAssertTrue(q.watchAd(now: t0))
        XCTAssertEqual(q.remainingSeconds, 6 * 3600, accuracy: 0.5)
        XCTAssertEqual(q.lastViewAt, t0)
    }

    func testAdCooldownBlocksImmediateSecondView() {
        var q = AdQuota()
        XCTAssertTrue(q.watchAd(now: t0))
        XCTAssertFalse(q.canWatchAd(now: t0.addingTimeInterval(3599)))
        XCTAssertFalse(q.watchAd(now: t0.addingTimeInterval(3599)), "second view inside 1h is rejected")
        XCTAssertTrue(q.canWatchAd(now: t0.addingTimeInterval(3600)))
    }

    func testCooldownRemainingCountsDown() {
        var q = AdQuota()
        XCTAssertTrue(q.watchAd(now: t0))
        let rem = q.adCooldownRemaining(now: t0.addingTimeInterval(600))
        XCTAssertEqual(rem, 3000, accuracy: 0.5)
        XCTAssertEqual(q.adCooldownRemaining(now: t0.addingTimeInterval(4000)), 0)
    }

    func testBankCapsAtThreeViews() {
        var q = AdQuota()
        var now = t0
        for _ in 1...3 {
            XCTAssertTrue(q.watchAd(now: now))
            now = now.addingTimeInterval(AdQuota.viewCooldown)
        }
        XCTAssertFalse(q.canWatchAd(now: now), "4th view blocked: bank is full at 3 (9h)")
        XCTAssertEqual(q.bankedSeconds, 9 * 3600, accuracy: 0.5)
        // After burning some banked time a view is allowed again.
        q.consume(AdQuota.freeAllowance)            // free gone
        q.consume(3600)                              // burn 1h of bank
        XCTAssertTrue(q.canWatchAd(now: now))
        XCTAssertTrue(q.watchAd(now: now))
    }

    func testConsumeNeverGoesNegative() {
        var q = AdQuota()
        q.consume(999_999)
        XCTAssertEqual(q.remainingSeconds, 0)
        q.consume(10)
        XCTAssertEqual(q.remainingSeconds, 0)
    }

    func testStoreRoundTrips() {
        let defaults = UserDefaults(suiteName: "AdQuotaTests.\(UUID().uuidString)")!
        let store = AdQuotaStore(defaults: defaults)
        var q = AdQuota()
        q.consume(123)
        XCTAssertTrue(q.watchAd(now: t0))
        store.save(q)
        let loaded = store.load()
        XCTAssertEqual(loaded, q)
    }
}
