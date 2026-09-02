import Foundation

/// Tracks per-session ping/pong liveness so a peer that silently stops
/// answering can be torn down instead of leaving a blackhole behind.
///
/// Tokens identify the peer. `markSent(_:at:)` starts a liveness window;
/// `markPong(_:at:)` clears it. A token whose last activity predates
/// `interval * threshold` and that never answered the outstanding ping is
/// reported dead.
public struct HeartbeatTracker: Sendable {
    private struct Entry {
        var hasOutstandingPing = false
        var lastActivity: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func markSent(_ token: String, at now: Date = Date()) {
        entries[token] = Entry(hasOutstandingPing: true, lastActivity: now)
    }

    public mutating func markPong(_ token: String, at now: Date = Date()) {
        if var entry = entries[token] {
            entry.lastActivity = now
            entry.hasOutstandingPing = false
            entries[token] = entry
        }
    }

    public func deadTokens(at now: Date = Date(), interval: TimeInterval, threshold: Int) -> [String] {
        entries.filter { entry in
            entry.value.hasOutstandingPing
                && now.timeIntervalSince(entry.value.lastActivity) >= interval * TimeInterval(max(1, threshold))
        }.map(\.key)
    }

    public mutating func remove(_ token: String) {
        entries[token] = nil
    }

    public mutating func reset() {
        entries.removeAll()
    }
}