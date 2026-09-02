import Foundation

public enum TunnelState: Equatable, Sendable {
    case disconnected
    case connecting
    case handshaking
    case connected
    case reconnecting(attempt: Int)
    case stopping
    case failed(TunnelFailure)
}

public enum TunnelFailure: Equatable, Sendable {
    case timeout
    case authentication
    case transport
    case protocolViolation
    case cancelled
}

public struct ReconnectPolicy: Equatable, Sendable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: Double

    public init(baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30, jitter: Double = 0.2) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    public func delay(for attempt: Int, randomUnit: Double = 0.5) -> TimeInterval {
        let exponential = min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        let boundedRandom = min(1, max(0, randomUnit))
        return exponential * (1 - jitter + (2 * jitter * boundedRandom))
    }
}

public struct TunnelStateMachine: Sendable {
    public private(set) var state: TunnelState = .disconnected

    public init() {}

    @discardableResult
    public mutating func start() -> Bool {
        guard state == .disconnected || isFailure else { return false }
        state = .connecting
        return true
    }

    @discardableResult
    public mutating func handshakeStarted() -> Bool {
        guard state == .connecting || isReconnecting else { return false }
        state = .handshaking
        return true
    }

    @discardableResult
    public mutating func connected() -> Bool {
        guard state == .handshaking else { return false }
        state = .connected
        return true
    }

    @discardableResult
    public mutating func lostConnection(attempt: Int) -> Bool {
        guard state == .connected || state == .handshaking || state == .connecting else { return false }
        state = .reconnecting(attempt: max(1, attempt))
        return true
    }

    @discardableResult
    public mutating func stop() -> Bool {
        guard state != .disconnected && state != .stopping else { return false }
        state = .stopping
        return true
    }

    public mutating func stopped() { state = .disconnected }

    public mutating func fail(_ failure: TunnelFailure) { state = .failed(failure) }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }
}
