import Foundation

/// The action the transport layer should take in response to an event.
public enum GatewayReconnectAction: Equatable, Sendable {
    case reportReady
    case scheduleReconnect
    case failAuthentication
    case failTransport
    case noOp
}

/// Pure, value-type decision engine for the reconnect/ready flow.
///
/// This encapsulates the reconnect/ready logic that previously lived inside
/// the App-layer `SSHPacketTunnelTransport` (which cannot be unit-tested in CI
/// because it does not build under macOS). Moving it here makes the heart of
/// chains C1 (connect), C6 (reconnect), and C13 (reconnect <-> network) fully
/// testable.
///
/// It holds no timers and performs no I/O — it only decides. The transport
/// layer owns scheduling; this owns the decision.
public struct GatewayReconnectController: Sendable {
    public var stateMachine = TunnelStateMachine()
    public var sessions = 0
    public private(set) var didReportReady = false
    public private(set) var initialAttemptsCompleted = 0
    public var reconnectAttempt = 0
    public private(set) var reconnectScheduled = false
    public var isStopped = false
    public let desiredSessionCount: Int

    public var state: TunnelState { stateMachine.state }

    public init(desiredSessionCount: Int = 3) {
        self.desiredSessionCount = max(1, desiredSessionCount)
    }

    /// Test-support initializer that seeds the full state, so individual
    /// decision branches can be exercised in isolation.
    internal init(
        desiredSessionCount: Int,
        sessions: Int,
        didReportReady: Bool,
        initialAttemptsCompleted: Int,
        reconnectAttempt: Int,
        reconnectScheduled: Bool,
        isStopped: Bool
    ) {
        self.desiredSessionCount = max(1, desiredSessionCount)
        self.sessions = max(0, sessions)
        self.didReportReady = didReportReady
        self.initialAttemptsCompleted = max(0, initialAttemptsCompleted)
        self.reconnectAttempt = max(0, reconnectAttempt)
        self.reconnectScheduled = reconnectScheduled
        self.isStopped = isStopped
    }

    // MARK: - Events

    /// A child session authenticated (pong received past the handshake gate).
    /// Reports ready exactly once, on the first authenticated session.
    @discardableResult
    public mutating func sessionAuthenticated() -> GatewayReconnectAction {
        guard !isStopped, !didReportReady else { return .noOp }
        didReportReady = true
        reconnectAttempt = 0
        stateMachine.connected()
        return .reportReady
    }

    /// An initial session attempt failed before authenticating.
    @discardableResult
    public mutating func initialAttemptFailed(isFatal: Bool) -> GatewayReconnectAction {
        guard !isStopped else { return .noOp }
        initialAttemptsCompleted += 1
        if isFatal {
            stateMachine.fail(.authentication)
            return .failAuthentication
        }
        if sessions == 0 {
            if !didReportReady, initialAttemptsCompleted >= desiredSessionCount {
                stateMachine.fail(.transport)
                return .failTransport
            }
            return scheduleReconnect()
        }
        return .noOp
    }

    /// An active session was lost (channelInactive). The caller sets the
    /// post-loss session count via `setSessions` before calling this, then the
    /// controller decides whether to schedule a reconnect.
    @discardableResult
    public mutating func sessionLost() -> GatewayReconnectAction {
        guard !isStopped else { return .noOp }
        if didReportReady || sessions == 0 {
            return scheduleReconnect()
        }
        return .noOp
    }

    // MARK: - Scheduling

    /// Marks a reconnect as armed. Fails-safe: refuses while stopped or if one
    /// is already scheduled (no double-arming).
    @discardableResult
    public mutating func scheduleReconnect() -> GatewayReconnectAction {
        guard !isStopped, !reconnectScheduled else { return .noOp }
        reconnectScheduled = true
        reconnectAttempt += 1
        return .scheduleReconnect
    }

    /// A scheduled reconnect fired. Clears the armed flag so the next loss can
    /// arm a fresh one.
    public mutating func reconnectFired() {
        reconnectScheduled = false
    }

    /// Transport layer calls this once it has armed the reconnect work item, so
    /// the controller can refuse to double-schedule.
    public mutating func markReconnectScheduled() {
        reconnectScheduled = true
    }

    // MARK: - Introspection helpers for the transport layer

    public mutating func incrementSessions() { sessions += 1 }

    public mutating func setSessions(_ count: Int) { sessions = max(0, count) }

    public func hasReachedDesiredSessionCount() -> Bool {
        sessions >= desiredSessionCount
    }
}
