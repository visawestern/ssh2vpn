import Foundation

/// Client-side cap on decorative port-22 TCP pings (server-list badges, map
/// dot colors). The VPS rate-limits NEW connections to ~6/30s per source and
/// REJECTs the overflow — every ping SYN eats the same budget as a real SSH
/// connect, so an uncapped UI (boot sweep + list-appear sweep + minutely
/// ticks + retries stacked in seconds) DoSes our own server and then reads
/// as "no ping at load / server unreachable".
///
/// Rule: at most `maxEvents` ping SYNs per rolling `window`. Real SSH
/// connects (user intent) bypass the budget; only decoration pings go
/// through `allow()`. Skipped pings keep their last cached value.
public final class PingBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [Date] = []
    private let maxEvents: Int
    private let window: TimeInterval
    private let now: () -> Date

    public init(maxEvents: Int = 4, window: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
        self.maxEvents = maxEvents
        self.window = window
        self.now = now
    }

    /// True when a decorative ping may fire now (records the spend).
    public func allow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now().addingTimeInterval(-window)
        stamps.removeAll { $0 <= cutoff }
        guard stamps.count < maxEvents else { return false }
        stamps.append(now())
        return true
    }

    /// Spends remaining for diagnostics (testing only).
    public var spent: Int {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now().addingTimeInterval(-window)
        stamps.removeAll { $0 <= cutoff }
        return stamps.count
    }
}
