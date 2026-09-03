import Foundation

/// Bounded retry budget for waiting on system state — e.g. a VPN profile being
/// created after first-install consent: poll every `intervalSeconds`, give up
/// after `maxAttempts`. Defaults: 5s poll, 24 attempts = 2 minutes.
public struct RetryBudget: Sendable {
    public let maxAttempts: Int
    public let intervalSeconds: Double
    public private(set) var used: Int = 0

    public init(maxAttempts: Int = 24, intervalSeconds: Double = 5) {
        self.maxAttempts = maxAttempts
        self.intervalSeconds = intervalSeconds
    }

    public var remaining: Int { max(0, maxAttempts - used) }

    /// Consumes one attempt. Returns false when the budget is exhausted.
    public mutating func consume() -> Bool {
        guard used < maxAttempts else { return false }
        used += 1
        return true
    }
}
