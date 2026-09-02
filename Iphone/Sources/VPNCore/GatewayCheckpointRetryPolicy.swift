import Foundation

/// Bounded-retry policy for interrupted bootstrap resumption (Chapter 4, p.67-68).
///
/// When a bootstrap is interrupted (network drop, app backgrounded), resumption
/// retries are capped at `maxRetries` and grow with a bounded exponential
/// backoff (`baseDelay * 2^attempt`, clamped to `maxDelay`). An empty checkpoint
/// is invalid and must not trigger a resume — there is nothing to resume from.
///
/// The policy is pure data + pure functions: no timers, no side effects. The
/// caller owns scheduling; this owns the decision.
public struct GatewayCheckpointRetryPolicy: Sendable {
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    public init(maxRetries: Int = 3, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
    }

    /// Whether the given attempt (0-based) is still within the retry budget.
    public func shouldRetry(attempt: Int) -> Bool {
        attempt < maxRetries
    }

    /// Bounded exponential backoff for the given attempt. Grows as
    /// `baseDelay * 2^attempt` but never exceeds `maxDelay` and never goes
    /// negative.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 0 else { return 0 }
        let raw = baseDelay * pow(2, Double(attempt))
        return min(maxDelay, max(0, raw))
    }

    /// A checkpoint is valid for resumption only if it carries data. An empty
    /// checkpoint means there is nothing to resume from (p.68).
    public func isValidCheckpoint(_ data: Data) -> Bool {
        !data.isEmpty
    }
}
