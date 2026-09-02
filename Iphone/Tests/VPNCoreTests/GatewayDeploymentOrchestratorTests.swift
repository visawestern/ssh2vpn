import Crypto
import Foundation
import XCTest
@testable import VPNCore

/// Tests the deployment orchestrator — the convergence point that ties together
/// the validator (Chapter 1), mode selector, verifier, and command builder
/// (Chapter 2). It is the glue behind chains C1 (connect), C9 (bootstrap
/// readiness), and C10 (binary + signature → execute).
final class GatewayDeploymentOrchestratorTests: XCTestCase {
    private let binary = Data("native-gateway-binary")
    private let pythonScript = Data("python-gateway-script")
    private let binaryHash = Data(SHA256.hash(data: Data("native-gateway-binary")))

    private lazy var key = Curve25519.Signing.PrivateKey()
    private lazy var signature = try! key.signature(for: binary)
    private lazy var verifier = GatewayArtifactVerifier(expectedHash: binaryHash, publicKey: key.publicKey)

    private func artifact(_ archs: Set<String>) -> GatewayBinaryArtifact {
        GatewayBinaryArtifact(data: binary, signature: signature, supportedArchitectures: archs)
    }

    private func environment(_ arch: String) -> VPSEnvironment {
        VPSEnvironment(osFamily: "linux", libc: "glibc", architecture: arch, pythonVersion: "3.10.0")
    }

    // MARK: - C9 / C10: readiness → command

    func testProducesPythonCommandWhenNoBinaryMatches() throws {
        let orchestrator = GatewayDeploymentOrchestrator()
        let plan = try orchestrator.prepare(
            environment: environment("x86_64"),
            binaries: [],
            pythonScript: pythonScript,
            verifier: verifier
        )
        XCTAssertEqual(plan.mode, .python)
        XCTAssertEqual(plan.command, GatewayCommandBuilder.pythonInline(script: pythonScript))
        XCTAssertNil(plan.verifiedBinary)
    }

    func testProducesBinaryCommandWhenMatchVerified() throws {
        let orchestrator = GatewayDeploymentOrchestrator()
        let plan = try orchestrator.prepare(
            environment: environment("aarch64"),
            binaries: [artifact(["aarch64"])],
            pythonScript: pythonScript,
            verifier: verifier
        )
        XCTAssertEqual(plan.mode, .binary)
        XCTAssertNotNil(plan.verifiedBinary)
        XCTAssertEqual(plan.verifiedBinary, binary)
        XCTAssertTrue(plan.command.contains("aarch64") == false) // command is arch-agnostic shell
        XCTAssertFalse(plan.command.isEmpty)
    }

    func testBinaryVerificationFailureThrows() {
        let orchestrator = GatewayDeploymentOrchestrator()
        let intruder = Curve25519.Signing.PrivateKey()
        let bad = GatewayBinaryArtifact(
            data: binary,
            signature: try! intruder.signature(for: binary),
            supportedArchitectures: ["x86_64"]
        )
        XCTAssertThrowsError(try orchestrator.prepare(
            environment: environment("x86_64"),
            binaries: [bad],
            pythonScript: pythonScript,
            verifier: verifier
        )) { error in
            XCTAssertTrue(error is GatewayDeploymentError)
        }
    }

    // MARK: - C1: architecture-aware mode selection

    func testUnknownArchitectureFallsBackToPython() throws {
        let orchestrator = GatewayDeploymentOrchestrator()
        let plan = try orchestrator.prepare(
            environment: environment("unknown"),
            binaries: [artifact(["x86_64"])],
            pythonScript: pythonScript,
            verifier: verifier
        )
        XCTAssertEqual(plan.mode, .python)
    }

    // MARK: - brokerID threading

    func testBrokerIDThreadedIntoPythonCommand() throws {
        let orchestrator = GatewayDeploymentOrchestrator()
        let plan = try orchestrator.prepare(
            environment: environment("x86_64"),
            binaries: [],
            pythonScript: pythonScript,
            verifier: verifier,
            brokerID: "mybroker"
        )
        XCTAssertTrue(plan.command.contains("--broker-id mybroker"))
    }

    // MARK: - binary command is distinct from python

    func testBinaryCommandDiffersFromPythonCommand() throws {
        let orchestrator = GatewayDeploymentOrchestrator()
        let python = try orchestrator.prepare(
            environment: environment("riscv64"),
            binaries: [artifact(["x86_64"])],
            pythonScript: pythonScript,
            verifier: verifier
        )
        let binary = try orchestrator.prepare(
            environment: environment("x86_64"),
            binaries: [artifact(["x86_64"])],
            pythonScript: pythonScript,
            verifier: verifier
        )
        XCTAssertNotEqual(python.command, binary.command)
    }
}

private extension Data {
    init(_ string: String) {
        self = string.data(using: .utf8)!
    }
}
