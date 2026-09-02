import Foundation

/// The concrete command the coordinator hands to an executor after mode
/// selection and (for binaries) verification.
public enum GatewayExecutionCommand: Sendable, Equatable {
    case binary(Data)
    case python(Data)
}

/// A candidate native gateway binary together with its signature and the CPU
/// architectures it supports. This is the verified, ready-to-execute form of
/// `GatewayBinaryCandidate`.
public struct GatewayBinaryArtifact: Sendable, Equatable {
    public let data: Data
    public let signature: Data
    public let supportedArchitectures: Set<String>

    public init(data: Data, signature: Data, supportedArchitectures: Set<String>) {
        self.data = data
        self.signature = signature
        self.supportedArchitectures = supportedArchitectures
    }
}

/// Executes a `GatewayExecutionCommand` on the host. In production this writes
/// the artifact to a temp file (0700) and runs it; in tests it is mocked.
public protocol GatewayExecutor: Sendable {
    func execute(_ command: GatewayExecutionCommand) throws
}

/// Orchestrates gateway deployment behind three hard security invariants
/// (Chapter 2, p.35/37/38):
///
///   1. **verify-before-execute** — a binary is verified (sha256 + Ed25519) by
///      `GatewayArtifactVerifier` *before* it is ever handed to the executor.
///      A failing verification throws and the executor is never called.
///   2. **no-execution-without-ready** — `deploy` throws `notReady` if the host
///      has not signalled readiness, so nothing runs on an unprobed VPS.
///   3. **no-duplicate (single-flight)** — only the first successful `deploy`
///      reaches the executor; subsequent calls are a no-op. This prevents a
///      duplicate process if bootstrap is retried.
///
/// Mode selection (`GatewayDeploymentModeSelector`) decides binary-vs-python;
/// the verifier is only consulted in binary mode, so the Python fallback never
/// depends on binary availability.
public struct GatewayDeployCoordinator<Executor: GatewayExecutor>: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case notReady
    }

    private let verifier: GatewayArtifactVerifier
    private let selector: GatewayDeploymentModeSelector
    private let executor: Executor
    private let executed: LockedBool

    public init(verifier: GatewayArtifactVerifier, selector: GatewayDeploymentModeSelector = GatewayDeploymentModeSelector(), executor: Executor) {
        self.verifier = verifier
        self.selector = selector
        self.executor = executor
        self.executed = LockedBool()
    }

    public func deploy(
        hostArchitecture: String,
        binaries: [GatewayBinaryArtifact],
        pythonScript: Data,
        isReady: Bool
    ) throws {
        guard isReady else { throw Error.notReady }
        guard executed.setOnce() else { return }

        let candidates = binaries.map { GatewayBinaryCandidate(supportedArchitectures: $0.supportedArchitectures) }
        switch selector.selectMode(hostArchitecture: hostArchitecture, binaries: candidates) {
        case .binary:
            guard let match = binaries.first(where: { $0.supportedArchitectures.contains(hostArchitecture) }) else {
                try executor.execute(.python(pythonScript))
                return
            }
            _ = try verifier.verify(match.data, signature: match.signature)
            try executor.execute(.binary(match.data))
        case .python:
            try executor.execute(.python(pythonScript))
        }
    }
}

/// A tiny send-once boolean guarded by a lock, used to enforce single-flight
/// deployment without pulling in heavy concurrency primitives.
private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Sets the flag to true exactly once; returns true only the first time.
    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
