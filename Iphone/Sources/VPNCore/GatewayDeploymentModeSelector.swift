import Foundation

/// The way the gateway is deployed to the VPS.
///
/// Chapter 2, p.28-29: a native binary is preferred when one exists for the
/// host architecture, but the gateway must always be able to fall back to the
/// inline Python script when no matching binary is available (or the host
/// architecture is unrecognized). The fallback is the safety net that keeps the
/// tunnel working across heterogeneous VPS fleet.
public enum GatewayDeploymentMode: Sendable, Equatable {
    case binary
    case python
}

/// A candidate native gateway binary, described by the CPU architectures it
/// supports. The selector matches these against the host architecture reported
/// by `VPSEnvironmentValidator`.
public struct GatewayBinaryCandidate: Sendable, Equatable {
    public let supportedArchitectures: Set<String>

    public init(supportedArchitectures: Set<String>) {
        self.supportedArchitectures = supportedArchitectures
    }
}

/// Selects how the gateway should be deployed: native binary or inline Python.
///
/// The decision is intentionally conservative — it returns `.binary` only when a
/// candidate explicitly lists the host architecture. Anything unknown or
/// unmatched falls back to `.python`, which is always available.
public struct GatewayDeploymentModeSelector: Sendable {
    public init() {}

    public func selectMode(
        hostArchitecture: String,
        binaries: [GatewayBinaryCandidate]
    ) -> GatewayDeploymentMode {
        let matches = binaries.contains { $0.supportedArchitectures.contains(hostArchitecture) }
        return matches ? .binary : .python
    }
}
