import XCTest
@testable import VPNCore

/// Rekey schedule: OpenSSH renegotiates session keys after 4GB or 1h
/// (`RekeyLimit default`). A connection that never rekeys is a
/// long-lived-session fingerprint, so the pool rekeys on the same schedule.
final class SSHRekeyPolicyTests: XCTestCase {
    func testDefaultsMirrorOpenSSHRekeyLimit() {
        let p = SSHRekeyPolicy()
        XCTAssertEqual(p.byteLimit, 4 * 1024 * 1024 * 1024, "RekeyLimit default is 4G")
        XCTAssertEqual(p.interval, 3600, "RekeyLimit default time is 1h")
    }

    func testFreshConnectionNeverRekeys() {
        XCTAssertFalse(SSHRekeyPolicy().shouldRekey(bytesSinceRekey: 0, elapsed: 0))
    }

    func testRekeysAtByteLimit() {
        let p = SSHRekeyPolicy(byteLimit: 100, interval: 3600)
        XCTAssertFalse(p.shouldRekey(bytesSinceRekey: 99, elapsed: 0))
        XCTAssertTrue(p.shouldRekey(bytesSinceRekey: 100, elapsed: 0))
        XCTAssertTrue(p.shouldRekey(bytesSinceRekey: 10_000, elapsed: 0))
    }

    func testRekeysAtIntervalEvenWhenIdle() {
        let p = SSHRekeyPolicy(byteLimit: .max, interval: 60)
        XCTAssertFalse(p.shouldRekey(bytesSinceRekey: 0, elapsed: 59))
        XCTAssertTrue(p.shouldRekey(bytesSinceRekey: 0, elapsed: 60))
    }

    func testEitherThresholdAloneIsEnough() {
        let p = SSHRekeyPolicy(byteLimit: 100, interval: 60)
        XCTAssertTrue(p.shouldRekey(bytesSinceRekey: 100, elapsed: 0))
        XCTAssertTrue(p.shouldRekey(bytesSinceRekey: 0, elapsed: 60))
    }
}
