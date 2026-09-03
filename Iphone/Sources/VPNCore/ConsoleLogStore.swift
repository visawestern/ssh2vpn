import Foundation

public enum ConsoleLogLevel: String, Sendable, CaseIterable, Codable {
    case info = "INFO"
    case ssh = "SSH2"
    case success = "OK"
    case warning = "WARN"
    case error = "ERR"
    case system = "SYS"
    case rawIn = "RECV"
    case rawOut = "SEND"

    public var prefixAscii: String {
        switch self {
        case .info: return ">> [INFO]"
        case .ssh: return ">> [SSH2]"
        case .success: return "++ [SUCCESS]"
        case .warning: return "!! [WARNING]"
        case .error: return "XX [ERROR]"
        case .system: return "## [SYSTEM]"
        case .rawIn: return "<- [IN]"
        case .rawOut: return "-> [OUT]"
        }
    }
}

public struct ConsoleLogEntry: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let level: ConsoleLogLevel
    public let tag: String
    public let message: String
    public let formattedTimestamp: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: ConsoleLogLevel, tag: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.tag = tag.uppercased()
        self.message = message
        self.formattedTimestamp = ConsoleLogStore.timestampFormatter.string(from: timestamp)
    }

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: ConsoleLogLevel, tag: String, message: String, formattedTimestamp: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.tag = tag.uppercased()
        self.message = message
        self.formattedTimestamp = formattedTimestamp
    }
}

public final class ConsoleLogStore: @unchecked Sendable {
    public static let shared = ConsoleLogStore()

    private let lock = NSLock()
    private var _entries: [ConsoleLogEntry] = []
    private let maxEntries: Int

    public static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    public init(maxEntries: Int = 1000) {
        self.maxEntries = maxEntries
    }

    public var entries: [ConsoleLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    public func log(level: ConsoleLogLevel, tag: String, message: String) {
        let sanitized = ConsoleLogSanitizer.sanitize(message)
        let entry = ConsoleLogEntry(level: level, tag: tag, message: sanitized)

        lock.lock()
        _entries.append(entry)
        if _entries.count > maxEntries {
            _entries.removeFirst(_entries.count - maxEntries)
        }
        lock.unlock()

        NotificationCenter.default.post(name: .consoleLogDidAppend, object: entry)
    }

    public func clear() {
        lock.lock()
        _entries.removeAll()
        lock.unlock()
        // One-way migration hygiene: older builds persisted history under this
        // key (whose export wrongly resurrected stale sessions, including log
        // strings from previous builds). The persisted log is gone for good —
        // export covers the current session only — so drop any leftover.
        Self.removeLegacyPersisted()
        NotificationCenter.default.post(name: .consoleLogDidClear, object: nil)
    }

    /// Deletes history persisted by older builds. Kept solely so CLEAR (and a
    /// fresh launch path) can wipe it; nothing writes this key anymore.
    private static func removeLegacyPersisted() {
        let defaults = UserDefaults(suiteName: "group.com.sshtunnel.shared") ?? .standard
        defaults.removeObject(forKey: "console.log.entries.v1")
    }

    /// Ingests entries pulled from the extension over the message API. Original
    /// timestamps are preserved (true cross-process ordering); repeats from
    /// overlapping poll windows are dropped by id. Entries are pre-sanitized
    /// at log() time on the producing side, so no secrets pass through here.
    public func ingestExternal(_ incoming: [ConsoleLogEntry]) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        var known = Set(_entries.map(\.id))
        for e in incoming where !known.contains(e.id) {
            known.insert(e.id)
            _entries.append(e)
        }
        if _entries.count > maxEntries {
            _entries.removeFirst(_entries.count - maxEntries)
        }
        lock.unlock()
        NotificationCenter.default.post(name: .consoleLogDidAppend, object: nil)
    }

    /// Exports exactly what is on screen: the current session's in-memory
    /// entries, newest last. No cross-launch history is merged in — stale
    /// sessions (and their outdated log strings) must never pollute a dump.
    public func exportPlainText() -> String {
        let snapshot = entries
        var out = [String]()
        out.append("==================================================================")
        out.append("                SSH2VPN HACKER TERMINAL LOG DUMP                  ")
        out.append("==================================================================")
        out.append("Generated: \(Date().description)")
        out.append("Entries: \(snapshot.count)")
        out.append("------------------------------------------------------------------")

        for e in snapshot {
            out.append("[\(e.formattedTimestamp)] \(e.level.prefixAscii) [\(e.tag)] \(e.message)")
        }

        out.append("==================================================================")
        out.append("                        END OF LOG DUMP                           ")
        out.append("==================================================================")
        return out.joined(separator: "\n")
    }
}

public extension Notification.Name {
    static let consoleLogDidAppend = Notification.Name("com.ssh2vpn.consoleLogDidAppend")
    static let consoleLogDidClear = Notification.Name("com.ssh2vpn.consoleLogDidClear")
}
