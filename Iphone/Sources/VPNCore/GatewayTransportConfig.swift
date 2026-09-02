import Foundation

/// Transport configuration constants (Chapter 5, p.86, p.93).
///
/// Bundles the MTU sizes advertised to the tunnel and the flow/timeout limits.
/// Centralized so the values are asserted by tests instead of scattered as
/// magic numbers across the transport layer.
public struct GatewayTransportConfig: Sendable {
    public let ipv4MTU: Int
    public let ipv6MTU: Int
    public let maxActiveFlows: Int
    public let tcpIdleTimeout: TimeInterval
    public let udpIdleTimeout: TimeInterval

    public static let `default` = GatewayTransportConfig(
        ipv4MTU: 1400,
        ipv6MTU: 1380,
        maxActiveFlows: 4096,
        tcpIdleTimeout: 300,
        udpIdleTimeout: 60
    )

    public init(
        ipv4MTU: Int = 1400,
        ipv6MTU: Int = 1380,
        maxActiveFlows: Int = 4096,
        tcpIdleTimeout: TimeInterval = 300,
        udpIdleTimeout: TimeInterval = 60
    ) {
        self.ipv4MTU = max(0, ipv4MTU)
        self.ipv6MTU = max(0, ipv6MTU)
        self.maxActiveFlows = max(1, maxActiveFlows)
        self.tcpIdleTimeout = max(0, tcpIdleTimeout)
        self.udpIdleTimeout = max(0, udpIdleTimeout)
    }
}

/// Flow-admission decision (Chapter 5, p.93, p.94).
public enum FlowDecision: Sendable {
    case accept
    case reject
}

/// Decides whether a new flow can be admitted given the current active count.
/// Pure logic for chain C7 (flow mode): reject cleanly at the limit.
public enum GatewayFlowAdmission {
    public static func decide(activeFlows: Int, config: GatewayTransportConfig) -> FlowDecision {
        activeFlows < config.maxActiveFlows ? .accept : .reject
    }
}
