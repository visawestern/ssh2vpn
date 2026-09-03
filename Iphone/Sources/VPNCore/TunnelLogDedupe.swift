import Foundation

/// Collapses identical tunnel-status bursts posted within milliseconds of each
/// other (system double-posts, stale profiles) while always surfacing genuine
/// transitions. Logging-only: state updates must never be gated by this.
public enum TunnelLogDedupe {
    public static func shouldLog<T: Equatable>(
        current: T, last: T?, lastAt: Date?, now: Date, window: TimeInterval = 0.15
    ) -> Bool {
        guard let last, let lastAt else { return true }
        if current != last { return true }
        return now.timeIntervalSince(lastAt) >= window
    }
}
