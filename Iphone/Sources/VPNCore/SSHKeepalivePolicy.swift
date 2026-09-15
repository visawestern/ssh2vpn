import Foundation

/// Client-side decision policy for protocol-level SSH keepalive.
///
/// Replaces the old channel-dance keepalive (direct-tcpip open/close every
/// 15s) with the same global request OpenSSH clients send
/// (`keepalive@openssh.com`). Rules:
/// - Suppressed while user traffic flows recently — no ping is needed when
///   data already keeps NAT/sshd alive, and the absence of timed pings makes
///   idle look human again.
/// - Consecutive unanswered echoes declare the peer dead; the pool heal /
///   reconnect path owns what comes next.
/// Pure policy: callers wire the timer in the app; VPNCore stays NIO-free.
public struct SSHKeepalivePolicy: Sendable {
    public let requestName = "keepalive@openssh.com"
    private let interval: TimeInterval
    /// Clamped to >= 1 so "negative max" cannot silently disable detection.
    private let maxUnanswered: Int

    private var lastUserTraffic: Date?
    private var lastSent: Date?
    private var unanswered = 0

    public init(interval: TimeInterval = 60, maxUnanswered: Int = 3) {
        self.interval = interval
        self.maxUnanswered = max(1, maxUnanswered)
    }

    /// A garbled prefix must never leak into the request name.
    public static func normalizeName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "keepalive@openssh.com" ? t : "keepalive@openssh.com"
    }

    /// Eligible when there was no user traffic for at least `interval`.
    public mutating func shouldSend(at now: Date) -> Bool {
        guard let last = lastUserTraffic else { return true }
        return now.timeIntervalSince(last) >= max(interval, 0.001)
    }

    public mutating func noteUserTraffic(at now: Date) {
        lastUserTraffic = now
        // Any data means the NAT entry is fresh — reset dead detection too.
    }

    public mutating func noteServerResponse(at now: Date) {
        lastUserTraffic = now
        unanswered = 0
    }

    public mutating func noteSent(at now: Date) {
        unanswered += 1
        lastSent = now
    }

    public func isDead(at now: Date) -> Bool {
        guard maxUnanswered > 0 else { return false }
        return unanswered >= maxUnanswered
    }
}
