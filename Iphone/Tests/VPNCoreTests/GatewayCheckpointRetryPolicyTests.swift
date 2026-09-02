import Foundation
import XCTest
@testable import VPNCore

/// Tests Chapter 4 items 67-68: bounded checkpoint retry. When bootstrap is
/// interrupted, resumption retries are capped (max 3) with bounded backoff, and
/// an empty/checkpoint is treated as invalid (no resume from nothing).
final class GatewayCheckpointRetryPolicyTests: XCTestCase {
    private let policy = GatewayCheckpointRetryPolicy(maxRetries: 3, baseDelay: 1, maxDelay: 30)

    // MARK: - p.67: bounded retries

    func testAllowsRetriesUpToMax() {
        XCTAssertTrue(policy.shouldRetry(attempt: 0))
        XCTAssertTrue(policy.shouldRetry(attempt: 1))
        XCTAssertTrue(policy.shouldRetry(attempt: 2))
    }

    func testStopsAfterMaxRetries() {
        XCTAssertFalse(policy.shouldRetry(attempt: 3))
        XCTAssertFalse(policy.shouldRetry(attempt: 4))
        XCTAssertFalse(policy.shouldRetry(attempt: 100))
    }

    // MARK: - p.67: bounded backoff

    func testDelayIsBoundedByMaxDelay() {
        for attempt in 0..<20 {
            let delay = policy.delay(forAttempt: attempt)
            XCTAssertLessThanOrEqual(delay, 30, "delay must not exceed maxDelay")
            XCTAssertGreaterThanOrEqual(delay, 0, "delay must be non-negative")
        }
    }

    func testDelayIsMonotonicNonDecreasing() {
        // Backoff does not decrease as attempts grow (no earlier retry waits longer).
        var previous: TimeInterval = 0
        for attempt in 0..<10 {
            let delay = policy.delay(forAttempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, previous)
            previous = delay
        }
    }

    func testFirstRetryHasBaseDelay() {
        XCTAssertEqual(policy.delay(forAttempt: 0), 1, accuracy: 0.001)
    }

    // MARK: - p.68: zero-byte checkpoint invalid

    func testZeroByteCheckpointInvalid() {
        XCTAssertFalse(policy.isValidCheckpoint(Data()))
    }

    func testEmptyCheckpointInvalid() {
        XCTAssertFalse(policy.isValidCheckpoint(Data()))
    }

    func testValidCheckpointAccepted() {
        XCTAssertTrue(policy.isValidCheckpoint(Data("checkpoint-payload".utf8)))
    }

    // MARK: - custom configuration

    func testZeroMaxRetriesMeansNoRetry() {
        let noRetry = GatewayCheckpointRetryPolicy(maxRetries: 0)
        XCTAssertFalse(noRetry.shouldRetry(attempt: 0))
    }

    func testDelayNeverNegative() {
        let policy = GatewayCheckpointRetryPolicy(maxRetries: 3, baseDelay: 0, maxDelay: 0)
        XCTAssertEqual(policy.delay(forAttempt: 5), 0, accuracy: 0.001)
    }
}

private extension Data {
    init(_ string: String) {
        self = string.data(using: .utf8)!
    }
}
