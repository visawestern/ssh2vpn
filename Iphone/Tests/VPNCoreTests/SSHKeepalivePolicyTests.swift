import XCTest
@testable import VPNCore

/// Protocol-level SSH keepalive client-side policy: OpenSSH-style
/// `keepalive@openssh.com` global requests, suppressed while user traffic
/// flows, with dead-peer detection by consecutive unanswered pings.
/// Pure policy (no NIO dependency) — the timer calls these decisions.
final class SSHKeepalivePolicyTests: XCTestCase {

    // MARK: - request format

    func testKeepaliveNameIsTheOpenSSHOne() {
        let k = SSHKeepalivePolicy()
        XCTAssertEqual(k.requestName, "keepalive@openssh.com",
                       "must match the exact global-request name OpenSSH clients send")
    }

    func testRequestStringIgnoresEmptyUserPrefix() {
        var k = SSHKeepalivePolicy()
        // Invalid input: empty prefix must not end up in the request name.
        XCTAssertEqual(SSHKeepalivePolicy.normalizeName(" "), "keepalive@openssh.com")
        XCTAssertEqual(SSHKeepalivePolicy.normalizeName("keepalive@openssh.com"), "keepalive@openssh.com")
        _ = k
    }

    // MARK: - suppression by user traffic

    func testSuppressedByRecentUserTraffic() {
        var k = SSHKeepalivePolicy(interval: 60)
        let t0 = Date()
        k.noteUserTraffic(at: t0)
        XCTAssertFalse(k.shouldSend(at: t0.addingTimeInterval(59)),
                       "user traffic inside the window suppresses the ping — the wire stays shaped like a busy admin")
        XCTAssertTrue(k.shouldSend(at: t0.addingTimeInterval(60)))
    }

    func testSuppressedByDataArrivingDuringTickLoop() {
        var k = SSHKeepalivePolicy(interval: 60)
        let t0 = Date()
        XCTAssertTrue(k.shouldSend(at: t0.addingTimeInterval(30)), "idle: allowed")
        k.noteUserTraffic(at: t0.addingTimeInterval(40))
        k.noteServerResponse(at: t0.addingTimeInterval(41))
        XCTAssertFalse(k.shouldSend(at: t0.addingTimeInterval(60)))
    }

    // MARK: - dead-peer detection

    func testDeadAfterThreeUnanswered() {
        var k = SSHKeepalivePolicy(interval: 60, maxUnanswered: 3)
        let t0 = Date()
        XCTAssertTrue(k.shouldSend(at: t0))
        k.noteSent(at: t0)
        XCTAssertTrue(k.shouldSend(at: t0.addingTimeInterval(61)))
        k.noteSent(at: t0.addingTimeInterval(61))
        XCTAssertTrue(k.shouldSend(at: t0.addingTimeInterval(122)))
        k.noteSent(at: t0.addingTimeInterval(122))
        XCTAssertTrue(k.isDead(at: t0.addingTimeInterval(183)), "3 unanswered -> peer declared dead")
    }

    func testAnyServerResponseClearsTheCounter() {
        var k = SSHKeepalivePolicy(interval: 60, maxUnanswered: 3)
        let t0 = Date()
        k.noteSent(at: t0)
        k.noteSent(at: t0.addingTimeInterval(61))
        k.noteServerResponse(at: t0.addingTimeInterval(61))
        XCTAssertFalse(k.isDead(at: t0.addingTimeInterval(62)), "a single response re-arms detection")
    }

    // MARK: - invalid inputs

    func testZeroIntervalNeverDeadlocks() {
        var k = SSHKeepalivePolicy(interval: 0)
        XCTAssertTrue(k.shouldSend(at: Date()), "zero interval must mean every tick eligible, not an infinite suppress")
    }

    func testNegativeUnansweredThresholdClamps() {
        var k = SSHKeepalivePolicy(interval: 60, maxUnanswered: -1)
        k.noteSent(at: Date())
        // clamped to 1: one miss already is dead.
        XCTAssertTrue(k.isDead(at: Date()))
    }

    func testZeroMaxUnansweredNeverDeadWithNothingSent() {
        var k = SSHKeepalivePolicy(interval: 60, maxUnanswered: 0)
        XCTAssertFalse(k.isDead(at: Date()), "with zero threshold and nothing sent, it must not claim dead")
        k.noteSent(at: Date())
        XCTAssertTrue(k.isDead(at: Date()), "after a send with zero threshold it becomes dead on schedule")
    }
}
