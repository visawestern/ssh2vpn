import XCTest
@testable import VPNCore

final class HeartbeatTrackerTests: XCTestCase {
    func testPeerIsNotDeadBeforeWindowElapses() {
        let now = Date(timeIntervalSince1970: 1_000)
        var tracker = HeartbeatTracker()
        tracker.markSent("a", at: now)

        XCTAssertTrue(tracker.deadTokens(at: now.addingTimeInterval(9), interval: 5, threshold: 2).isEmpty)
    }

    func testPeerDiesAfterMissedThresholdWindows() {
        let now = Date(timeIntervalSince1970: 1_000)
        var tracker = HeartbeatTracker()
        tracker.markSent("a", at: now)

        XCTAssertEqual(tracker.deadTokens(at: now.addingTimeInterval(10), interval: 5, threshold: 2), ["a"])
    }

    func testPongClearsOutstandingPing() {
        let now = Date(timeIntervalSince1970: 1_000)
        var tracker = HeartbeatTracker()
        tracker.markSent("a", at: now)
        tracker.markPong("a", at: now.addingTimeInterval(2))

        XCTAssertTrue(tracker.deadTokens(at: now.addingTimeInterval(30), interval: 5, threshold: 2).isEmpty)
    }

    func testPongRestartsWindowAfterResend() {
        let now = Date(timeIntervalSince1970: 1_000)
        var tracker = HeartbeatTracker()
        tracker.markSent("a", at: now)
        tracker.markPong("a", at: now.addingTimeInterval(2))
        tracker.markSent("a", at: now.addingTimeInterval(2))

        XCTAssertTrue(tracker.deadTokens(at: now.addingTimeInterval(11), interval: 5, threshold: 2).isEmpty)
        XCTAssertEqual(tracker.deadTokens(at: now.addingTimeInterval(12), interval: 5, threshold: 2), ["a"])
    }

    func testSilentPeerWithoutPingIsNotDead() {
        let now = Date(timeIntervalSince1970: 1_000)
        var tracker = HeartbeatTracker()
        tracker.markSent("a", at: now)
        tracker.markPong("a", at: now.addingTimeInterval(1))

        XCTAssertTrue(tracker.deadTokens(at: now.addingTimeInterval(1_000), interval: 5, threshold: 2).isEmpty)
    }

    func testRemovalForgetsPeer() {
        let now = Date(timeIntervalSince1970: 1_000)
        var tracker = HeartbeatTracker()
        tracker.markSent("a", at: now)
        tracker.remove("a")

        XCTAssertTrue(tracker.deadTokens(at: now.addingTimeInterval(1_000), interval: 5, threshold: 2).isEmpty)
    }

    func testUnrelatedTokenNotAffected() {
        let now = Date(timeIntervalSince1970: 1_000)
        var tracker = HeartbeatTracker()
        tracker.markSent("a", at: now)
        tracker.markPong("b", at: now) // late or spurious pong must not touch "a"

        XCTAssertEqual(tracker.deadTokens(at: now.addingTimeInterval(10), interval: 5, threshold: 2), ["a"])
    }
}