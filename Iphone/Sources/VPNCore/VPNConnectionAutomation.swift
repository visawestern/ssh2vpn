import Foundation

/// Classifies a connection error as fatal (must not retry, e.g. bad config)
/// vs transient (safe to retry a bounded number of times, e.g. network).
public enum ConnectionErrorClassifier {
    /// True when the error is a permanent configuration problem that retrying
    /// will never fix (NEVPNErrorDomain Code=1 configurationInvalid, invalid
    /// server data), so a bounded auto-retry should NOT run.
    public static func isFatal(_ errorDescription: String) -> Bool {
        let lower = errorDescription.lowercased()
        let fatalMarkers = [
            "configurationinvalid",
            "nevpnerrordomain code=1",
            "empty host",
            "invalid port",
            "invalid configuration",
            "missing credentials",
            "некорректная конфигурация",
            "пустой хост",
        ]
        return fatalMarkers.contains { lower.contains($0.lowercased()) }
    }
}

public enum ConnectionAutomationEvent: Equatable {
    case attemptStarted(Int)
    case connected
    case disconnected
    case transientFailure(Int, String)   // attempt index (1-based) + message
    case fatalFailure(String)            // no retry
    case gaveUpAfterRetries(String)
}

/// Drives the connect -> (retry on transient error up to maxRetries) -> result
/// lifecycle, and tracks elapsed connected time. Pure logic, unit-testable.
public struct VPNConnectionAutomation {
    public let maxRetries: Int
    public private(set) var attempt: Int = 0
    public private(set) var isConnected: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var activeSeconds: Int = 0

    public init(maxRetries: Int = 3) {
        self.maxRetries = maxRetries
    }

    public var isConnecting: Bool { !isConnected && attempt > 0 && errorMessage == nil }

    /// Begin a fresh connection attempt sequence.
    public mutating func beginConnect() -> ConnectionAutomationEvent {
        reset()
        attempt = 1
        return .attemptStarted(1)
    }

    /// Call when the tunnel actually reports connected.
    public mutating func markConnected() -> ConnectionAutomationEvent {
        isConnected = true
        errorMessage = nil
        return .connected
    }

    public mutating func markDisconnected() -> ConnectionAutomationEvent {
        isConnected = false
        activeSeconds = 0
        return .disconnected
    }

    /// Report a failure. If transient and attempts remain, schedules the next
    /// attempt; if transient and exhausted, returns gaveUp; if fatal, returns
    /// fatal and never retries.
    public mutating func reportFailure(_ message: String) -> ConnectionAutomationEvent {
        let fatal = ConnectionErrorClassifier.isFatal(message)
        errorMessage = message
        isConnected = false

        if fatal {
            return .fatalFailure(message)
        }

        if attempt < maxRetries {
            attempt += 1
            return .transientFailure(attempt, message)
        }

        return .gaveUpAfterRetries(message)
    }

    /// Error-aware overload. Any `VPNConfigurationError` is a permanent config
    /// mistake that retrying will never fix, so it is always classified fatal
    /// regardless of how the localized description gets flattened.
    public mutating func reportFailure(_ error: Error) -> ConnectionAutomationEvent {
        let message = error.localizedDescription
        let isConfigError = (error as? VPNConfigurationError) != nil
        errorMessage = message
        isConnected = false

        if isConfigError || ConnectionErrorClassifier.isFatal(message) {
            return .fatalFailure(message)
        }

        if attempt < maxRetries {
            attempt += 1
            return .transientFailure(attempt, message)
        }

        return .gaveUpAfterRetries(message)
    }

    /// Increment the connected timer by 1s; only advances while connected.
    public mutating func tick() {
        guard isConnected else { return }
        activeSeconds += 1
    }

    public mutating func reset() {
        attempt = 0
        isConnected = false
        errorMessage = nil
        activeSeconds = 0
    }
}
