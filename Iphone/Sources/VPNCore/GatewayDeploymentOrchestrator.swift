import Foundation

/// A complete, ready-to-send deployment plan produced by
/// `GatewayDeploymentOrchestrator`. It couples the chosen mode with the exact
/// shell command to send over SSH and, for binary mode, the verified bytes.
public struct GatewayDeploymentPlan: Equatable, Sendable {
    public let mode: GatewayDeploymentMode
    public let command: String
    public let verifiedBinary: Data?

    public init(mode: GatewayDeploymentMode, command: String, verifiedBinary: Data? = nil) {
        self.mode = mode
        self.command = command
        self.verifiedBinary = verifiedBinary
    }
}

public enum GatewayDeploymentError: Error, Equatable, Sendable {
    case verificationFailed(GatewayArtifactError)
}

/// Ties together the validator output, mode selection, artifact verification,
/// and command building into a single decision point.
///
/// Convergence hub for chains C1 (connect), C9 (bootstrap readiness), and C10
/// (binary + signature → execute). It guarantees, by construction, that a
/// binary is never turned into an execution command unless it first passes
/// sha256 + Ed25519 verification, and that an unrecognized host architecture
/// always falls back to the inline Python script.
public struct GatewayDeploymentOrchestrator: Sendable {
    public init() {}

    public func prepare(
        environment: VPSEnvironment,
        binaries: [GatewayBinaryArtifact],
        pythonScript: Data,
        verifier: GatewayArtifactVerifier,
        brokerID: String = "",
        now: Date = Date()
    ) throws -> GatewayDeploymentPlan {
        let candidates = binaries.map { GatewayBinaryCandidate(supportedArchitectures: $0.supportedArchitectures) }
        let mode = GatewayDeploymentModeSelector().selectMode(hostArchitecture: environment.architecture, binaries: candidates)

        switch mode {
        case .python:
            return GatewayDeploymentPlan(
                mode: .python,
                command: GatewayCommandBuilder.pythonInline(script: pythonScript, brokerID: brokerID)
            )
        case .binary:
            guard let match = binaries.first(where: { $0.supportedArchitectures.contains(environment.architecture) }) else {
                // Selector said binary but no artifact matches (shouldn't happen) — safe fallback.
                return GatewayDeploymentPlan(
                    mode: .python,
                    command: GatewayCommandBuilder.pythonInline(script: pythonScript, brokerID: brokerID)
                )
            }
            do {
                let verified = try verifier.verify(match.data, signature: match.signature, now: now)
                return GatewayDeploymentPlan(
                    mode: .binary,
                    command: GatewayCommandBuilder.binaryInline(data: verified, brokerID: brokerID),
                    verifiedBinary: verified
                )
            } catch let error as GatewayArtifactError {
                throw GatewayDeploymentError.verificationFailed(error)
            }
        }
    }
}
