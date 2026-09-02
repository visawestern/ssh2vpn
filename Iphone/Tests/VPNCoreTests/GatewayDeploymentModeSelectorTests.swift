import Foundation
import XCTest
@testable import VPNCore

/// Tests Chapter 2 items 28-29: deployment-mode selection. The rule is simple and
/// must hold for security: a native binary is used only when one exists that
/// explicitly supports the host architecture; otherwise the gateway falls back
/// to the inline Python script. An unrecognized host architecture must NEVER
/// select a binary (safe default = python).
final class GatewayDeploymentModeSelectorTests: XCTestCase {
    private let selector = GatewayDeploymentModeSelector()

    private func binary(_ archs: Set<String>) -> GatewayBinaryCandidate {
        GatewayBinaryCandidate(supportedArchitectures: archs)
    }

    // MARK: - p.28: binary preferred when available for host arch

    func testBinarySelectedWhenAvailableForX86_64() {
        let mode = selector.selectMode(
            hostArchitecture: "x86_64",
            binaries: [binary(["x86_64", "aarch64"])]
        )
        XCTAssertEqual(mode, .binary)
    }

    func testBinarySelectedWhenAvailableForAarch64() {
        let mode = selector.selectMode(
            hostArchitecture: "aarch64",
            binaries: [binary(["x86_64", "aarch64"])]
        )
        XCTAssertEqual(mode, .binary)
    }

    func testBinarySelectedWhenOneOfSeveralMatches() {
        let mode = selector.selectMode(
            hostArchitecture: "aarch64",
            binaries: [binary(["x86_64"]), binary(["aarch64"])]
        )
        XCTAssertEqual(mode, .binary)
    }

    // MARK: - p.29: python fallback when no binary matches

    func testPythonFallbackWhenNoBinariesAvailable() {
        let mode = selector.selectMode(hostArchitecture: "x86_64", binaries: [])
        XCTAssertEqual(mode, .python)
    }

    func testPythonFallbackWhenBinarySupportsDifferentArch() {
        let mode = selector.selectMode(
            hostArchitecture: "aarch64",
            binaries: [binary(["x86_64"])]
        )
        XCTAssertEqual(mode, .python)
    }

    func testPythonFallbackForUnknownArchitecture() {
        // An architecture the validator could not identify must not silently
        // pick a binary — that would risk running an unsuited executable.
        let mode = selector.selectMode(
            hostArchitecture: "unknown",
            binaries: [binary(["x86_64", "aarch64"])]
        )
        XCTAssertEqual(mode, .python)
    }

    // MARK: - edge cases

    func testPythonFallbackForExoticArchitecture() {
        // Future/unrecognized arch names fall back to python rather than
        // guessing a binary match.
        let mode = selector.selectMode(
            hostArchitecture: "riscv64",
            binaries: [binary(["x86_64", "aarch64"])]
        )
        XCTAssertEqual(mode, .python)
    }

    func testEmptySupportedArchitecturesNeverMatches() {
        // A malformed binary candidate that claims no architectures must not
        // match any host.
        let mode = selector.selectMode(
            hostArchitecture: "x86_64",
            binaries: [binary([])]
        )
        XCTAssertEqual(mode, .python)
    }
}
