import XCTest
@testable import VPNCore

final class QuotaLedgerTests: XCTestCase {

    func testFreshLedgerGrantsInitialHour() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = QuotaLedger().withInitialGrant(now: now)
        XCTAssertTrue(ledger.allowsConnection(now: now))
        XCTAssertEqual(ledger.remaining(now: now), 3600, accuracy: 1)
        XCTAssertFalse(ledger.isUnlimited)
        // Wall clock decays in real time.
        let later = now.addingTimeInterval(600)
        XCTAssertEqual(ledger.remaining(now: later), 3600 - 600, accuracy: 1)
    }

    func testGrantIsNotRegrantedOnceSet() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = QuotaLedger().withInitialGrant(now: now)
        let again = ledger.withInitialGrant(now: now.addingTimeInterval(60))
        // expiry stays from FIRST grant (wall-clock budget started ticking)
        XCTAssertEqual(again.remaining(now: now.addingTimeInterval(60)), 3600 - 60, accuracy: 1)
    }

    func testLapsedBudgetBlocksConnection() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = QuotaLedger().withInitialGrant(now: now)
        XCTAssertTrue(ledger.allowsConnection(now: now))
        let lapsed = now.addingTimeInterval(3600 + 1)
        XCTAssertFalse(ledger.allowsConnection(now: lapsed))
        XCTAssertEqual(ledger.remaining(now: lapsed), 0)
    }

    func testAdViewExtendsWallClock() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let base = QuotaLedger().withInitialGrant(now: now)
        let credited = base.creditingAdView(now: now)
        XCTAssertNotNil(credited)
        // from +1h to +4h
        XCTAssertEqual(credited!.remaining(now: now), 4 * 3600, accuracy: 1)
        XCTAssertEqual(credited!.lastAdView, now)
    }

    func testAdViewCooldownBlocksImmediateSecondPress() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let base = QuotaLedger().withInitialGrant(now: now)
        guard let first = base.creditingAdView(now: now) else {
            XCTFail("first press should credit")
            return
        }
        // second press within the hour is refused
        XCTAssertNil(first.creditingAdView(now: now.addingTimeInterval(600)))
        // after the hourly cooldown it credits again
        XCTAssertNotNil(first.creditingAdView(now: now.addingTimeInterval(3601)))
    }

    func testAdViewNotCreditedAt12HourCap() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // A ledger already at 11h remaining.
        let nearCap = QuotaLedger(expiresAt: now.addingTimeInterval(11 * 3600))
        let credited = nearCap.creditingAdView(now: now)
        XCTAssertNotNil(credited)
        // clamped to exactly 12h — never above the cap
        XCTAssertEqual(credited!.remaining(now: now), 12 * 3600, accuracy: 1)
        // at the ceiling nothing more is granted
        XCTAssertNil(credited!.creditingAdView(now: now))
    }

    func testAdViewWithLapsedBudgetStartsFreshBank() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lapsed = now.addingTimeInterval(3600)
        let base = QuotaLedger().withInitialGrant(now: now)
        // budget already gone
        XCTAssertFalse(base.allowsConnection(now: lapsed))
        let credited = base.creditingAdView(now: lapsed)
        XCTAssertNotNil(credited)
        // +3h from the current wall-clock moment
        XCTAssertEqual(credited!.remaining(now: lapsed), 3 * 3600, accuracy: 1)
    }

    func testUnlimitedUnlocksEverythingAndRemovesCap() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = QuotaLedger().withInitialGrant(now: now).withUnlimited()
        XCTAssertTrue(ledger.isUnlimited)
        XCTAssertTrue(ledger.allowsConnection(now: now.addingTimeInterval(1000)))
        XCTAssertNil(ledger.expires)
        XCTAssertNil(ledger.creditingAdView(now: now))
    }

    func testUnlimitedFlagPersistsThroughEncodeDecode() throws {
        let ledger = QuotaLedger().withUnlimited()
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(QuotaLedger.self, from: data)
        XCTAssertTrue(decoded.isUnlimited)
        XCTAssertNil(decoded.expires)
    }

    func testExpiryAndAdStampRoundTripThroughEncodeDecode() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = QuotaLedger().withInitialGrant(now: now).creditingAdView(now: now)!
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(QuotaLedger.self, from: data)
        XCTAssertEqual(decoded.remaining(now: now), 4 * 3600, accuracy: 1)
        XCTAssertEqual(decoded.expires, ledger.expires)
        XCTAssertEqual(decoded.lastAdView, now)
    }

    func testOldLedgerWithoutAdStampDecodes() throws {
        // A ledger encoded before the ad-stamp field existed has no
        // `lastAdViewAt` key; it must decode as nil, not crash (upgrade path).
        let old = QuotaLedger(unlimited: false, expiresAt: Date(timeIntervalSince1970: 1_700_003_600))
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(QuotaLedger.self, from: data)
        XCTAssertNil(decoded.lastAdView)
        XCTAssertEqual(decoded.expires, old.expires)
    }
}