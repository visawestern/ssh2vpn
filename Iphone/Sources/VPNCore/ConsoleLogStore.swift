import Foundation

public enum ConsoleLogLevel: String, Sendable, CaseIterable {
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

public struct ConsoleLogEntry: Identifiable, Sendable, Equatable {
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
        NotificationCenter.default.post(name: .consoleLogDidClear, object: nil)
    }

    public func exportPlainText() -> String {
        let currentEntries = entries
        var out = [String]()
        out.append("==================================================================")
        out.append("                SSH2VPN HACKER TERMINAL LOG DUMP                  ")
        out.append("==================================================================")
        out.append("Generated: \(Date().description)")
        out.append("Entries: \(currentEntries.count)")
        out.append("------------------------------------------------------------------")

        for e in currentEntries {
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
