import Foundation

/// Circuit breaker for the connect storm.
///
/// Failure mode it stops: every failed attempt schedules a retry, every
/// unexpected drop schedules a kill-switch redial, and iOS connect-on-demand
/// relaunches the tunnel on its own — three loops that pile concurrent SSH
/// handshakes onto the server (sshd MaxStartups/fail2ban start dropping
/// them), which fails every attempt and feeds the loops forever.
///
/// The breaker counts consecutive failed ATTEMPTS (each `reportFailure`,
/// fatal ones included — a forever-wrong password must not hammer either).
/// At the cap it trips exactly once; tripping disables connect-on-demand at
/// the NE level (iOS stops relaunching) and parks the app-side redial, while
/// `settings.killSwitch` stays ON — only the auto-dial storm stops. A manual
/// connect or any successful connect re-arms it.
///
/// Pure logic, unit-testable; the app owns one and acts on `recordFailure`.
public struct ConnectionBreaker: Sendable {
    /// Failed attempts in a row that trip the breaker (default 10).
    public let maxConsecutiveFailures: Int
    public private(set) var consecutiveFailures = 0
    public private(set) var tripped = false

    public init(maxConsecutiveFailures: Int = 10) {
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
    }

    /// Records one failed attempt. Returns true exactly once — on the
    /// failure that trips the breaker. Further failures return false until
    /// a reset (manual connect / successful connect).
    public mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        guard !tripped, consecutiveFailures >= maxConsecutiveFailures else { return false }
        tripped = true
        return true
    }

    /// Success or fresh user intent: clear the count and re-arm.
    public mutating func reset() {
        consecutiveFailures = 0
        tripped = false
    }
}
