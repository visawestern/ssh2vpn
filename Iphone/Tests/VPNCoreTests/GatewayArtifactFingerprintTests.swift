import Crypto
import Foundation
import XCTest
@testable import VPNCore

/// Tests Chapter 3 item 50: the install fingerprint. A host+user pair must map to
/// a unique, deterministic, path-safe string so artifacts never collide across
/// hosts and the same host+user always resolves to the same name.
final class GatewayArtifactFingerprintTests: XCTestCase {
    // MARK: - p.50: unique per host+user

    func testFingerprintIsDeterministic() {
        let a = GatewayArtifactFingerprint.fingerprint(host: "vps.example.com", user: "alice")
        let b = GatewayArtifactFingerprint.fingerprint(host: "vps.example.com", user: "alice")
        XCTAssertEqual(a, b)
    }

    func testFingerprintDiffersForDifferentHosts() {
        let a = GatewayArtifactFingerprint.fingerprint(host: "vps1.example.com", user: "alice")
        let b = GatewayArtifactFingerprint.fingerprint(host: "vps2.example.com", user: "alice")
        XCTAssertNotEqual(a, b)
    }

    func testFingerprintDiffersForDifferentUsers() {
        let a = GatewayArtifactFingerprint.fingerprint(host: "vps.example.com", user: "alice")
        let b = GatewayArtifactFingerprint.fingerprint(host: "vps.example.com", user: "bob")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - path safety

    func testFingerprintIsPathSafe() {
        // Only hexadecimal characters — safe in any file path, no slashes or
        // special characters that could escape the artifact directory.
        let fp = GatewayArtifactFingerprint.fingerprint(host: "host with spaces!/@#", user: "user")
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(fp.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testFingerprintIsFixedLength() {
        // SHA-256 → 64 hex chars regardless of input length.
        let short = GatewayArtifactFingerprint.fingerprint(host: "a", user: "b")
        let long = GatewayArtifactFingerprint.fingerprint(host: String(repeating: "x", count: 10000), user: String(repeating: "y", count: 10000))
        XCTAssertEqual(short.count, 64)
        XCTAssertEqual(long.count, 64)
    }

    // MARK: - edge cases

    func testEmptyInputsProduceDeterministicFingerprint() {
        let a = GatewayArtifactFingerprint.fingerprint(host: "", user: "")
        let b = GatewayArtifactFingerprint.fingerprint(host: "", user: "")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
    }

    func testUnicodeHostHandled() {
        let fp = GatewayArtifactFingerprint.fingerprint(host: "хост.пример.com", user: "用户")
        XCTAssertEqual(fp.count, 64)
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(fp.unicodeScalars.allSatisfy { allowed.contains($0) })
    }
}
