import Crypto
import Foundation
import XCTest
@testable import VPNCore

/// Minimal recorded executor: records every command it receives and optionally
/// throws on demand. Single-shot mock shared across the suite.
final class MockGatewayExecutor: GatewayExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _executions: [GatewayExecutionCommand] = []
    private var _error: Error?

    var error: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _error }
        set { lock.lock(); defer { lock.unlock() }; _error = newValue }
    }

    var executions: [GatewayExecutionCommand] {
        lock.lock(); defer { lock.unlock() }; return _executions
    }

    var executionCount: Int {
        lock.lock(); defer { lock.unlock() }; return _executions.count
    }

    func execute(_ command: GatewayExecutionCommand) throws {
        lock.lock()
        if let _error { lock.unlock(); throw _error }
        _executions.append(command)
        lock.unlock()
    }
}

/// Tests Chapter 2 items 35, 37, 38: the deploy coordinator ties together mode
/// selection (GatewayDeploymentModeSelector) and verification
/// (GatewayArtifactVerifier) behind three hard invariants:
///   1. verify-before-execute — a binary is never executed unless it verifies;
///   2. no-execution-without-ready — nothing runs until the host is ready;
///   3. no-duplicate — a second deploy() is a single-flight no-op.
final class GatewayDeployCoordinatorTests: XCTestCase {
    private let binary = Data("gateway-binary".utf8)
    private let pythonScript = Data("python-script".utf8)
    private let artifactHash = Data(SHA256.hash(data: Data("gateway-binary")))

    private lazy var key = Curve25519.Signing.PrivateKey()
    private lazy var signature = try! key.signature(for: binary)
    private lazy var verifier = GatewayArtifactVerifier(expectedHash: artifactHash, publicKey: key.publicKey)

    private func artifact(_ archs: Set<String>) -> GatewayBinaryArtifact {
        GatewayBinaryArtifact(data: binary, signature: signature, supportedArchitectures: archs)
    }

    // MARK: - p.35: verify-before-execute

    func testBinaryExecutedOnlyAfterVerification() throws {
        let executor = MockGatewayExecutor()
        let coordinator = GatewayDeployCoordinator(verifier: verifier, executor: executor)
        try coordinator.deploy(
            hostArchitecture: "x86_64",
            binaries: [artifact(["x86_64"])],
            pythonScript: pythonScript,
            isReady: true
        )
        XCTAssertEqual(executor.executionCount, 1)
        XCTAssertEqual(executor.executions.first, .binary(binary))
    }

    func testUnverifiedBinaryNeverExecutes() {
        // Wrong signature → verification fails → executor must not be touched.
        let executor = MockGatewayExecutor()
        let intruder = Curve25519.Signing.PrivateKey()
        let badArtifact = GatewayBinaryArtifact(
            data: binary,
            signature: try! intruder.signature(for: binary),
            supportedArchitectures: ["x86_64"]
        )
        let coordinator = GatewayDeployCoordinator(verifier: verifier, executor: executor)
        XCTAssertThrowsError(try coordinator.deploy(
            hostArchitecture: "x86_64",
            binaries: [badArtifact],
            pythonScript: pythonScript,
            isReady: true
        ))
        XCTAssertEqual(executor.executionCount, 0, "executor must not run an unverified binary")
    }

    // MARK: - p.37: no-execution-without-ready

    func testNothingExecutesBeforeReady() {
        let executor = MockGatewayExecutor()
        let coordinator = GatewayDeployCoordinator(verifier: verifier, executor: executor)
        XCTAssertThrowsError(try coordinator.deploy(
            hostArchitecture: "x86_64",
            binaries: [artifact(["x86_64"])],
            pythonScript: pythonScript,
            isReady: false
        ))
        XCTAssertEqual(executor.executionCount, 0)
    }

    // MARK: - p.38: no-duplicate (single-flight)

    func testSecondDeployIsNoOp() throws {
        let executor = MockGatewayExecutor()
        let coordinator = GatewayDeployCoordinator(verifier: verifier, executor: executor)
        for _ in 0..<3 {
            try coordinator.deploy(
                hostArchitecture: "x86_64",
                binaries: [artifact(["x86_64"])],
                pythonScript: pythonScript,
                isReady: true
            )
        }
        XCTAssertEqual(executor.executionCount, 1, "deploy must be single-flight")
    }

    // MARK: - mode selection wired through

    func testFallsBackToPythonWhenNoBinaryMatches() throws {
        let executor = MockGatewayExecutor()
        let coordinator = GatewayDeployCoordinator(verifier: verifier, executor: executor)
        try coordinator.deploy(
            hostArchitecture: "unknown",
            binaries: [artifact(["x86_64"])],
            pythonScript: pythonScript,
            isReady: true
        )
        XCTAssertEqual(executor.executions.first, .python(pythonScript))
    }

    func testPythonModeSkipsVerification() throws {
        // In python mode the (would-be) binary is never verified or executed.
        let executor = MockGatewayExecutor()
        let coordinator = GatewayDeployCoordinator(verifier: verifier, executor: executor)
        try coordinator.deploy(
            hostArchitecture: "riscv64",
            binaries: [artifact(["x86_64"])],
            pythonScript: pythonScript,
            isReady: true
        )
        XCTAssertEqual(executor.executionCount, 1)
        XCTAssertEqual(executor.executions.first, .python(pythonScript))
    }

    // MARK: - executor errors propagate

    func testExecutorErrorPropagates() {
        struct Boom: Error {}
        let executor = MockGatewayExecutor()
        executor.error = Boom()
        let coordinator = GatewayDeployCoordinator(verifier: verifier, executor: executor)
        XCTAssertThrowsError(try coordinator.deploy(
            hostArchitecture: "x86_64",
            binaries: [artifact(["x86_64"])],
            pythonScript: pythonScript,
            isReady: true
        ))
    }
}

private extension Data {
    init(_ string: String) {
        self = string.data(using: .utf8)!
    }
}
