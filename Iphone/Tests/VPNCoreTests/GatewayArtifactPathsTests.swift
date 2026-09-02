import Foundation
import XCTest
@testable import VPNCore

/// Tests Chapter 3 items 54, 56, 59: artifact path safety. Paths must stay inside
/// the artifact directory (no escape), normalize unicode hosts, and never
/// produce world-writable or traversable components. Converges chain C3.
final class GatewayArtifactPathsTests: XCTestCase {
    private let baseURL = URL(fileURLWithPath: "/var/lib/sshtunnel")

    // MARK: - p.59: unicode + unsafe path normalization

    func testASCIIHostUnchanged() {
        let name = GatewayArtifactPaths.safeComponent("vps.example.com")
        XCTAssertEqual(name, "vps.example.com")
    }

    func testUnicodeHostNormalized() {
        let name = GatewayArtifactPaths.safeComponent("хост.пример.com")
        // Normalized to ASCII (Latin + diacritics → ASCII), no raw unicode.
        let ascii = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_")
        XCTAssertTrue(name.unicodeScalars.allSatisfy { ascii.contains($0) })
    }

    func testSlashesStripped() {
        let name = GatewayArtifactPaths.safeComponent("foo/bar\\baz")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\\"))
    }

    func testPathTraversalRemoved() {
        let name = GatewayArtifactPaths.safeComponent("../../etc/passwd")
        XCTAssertFalse(name.contains(".."))
        XCTAssertEqual(name, "etcpasswd")
    }

    func testEmptyInputFallsBackToFingerprint() {
        let name = GatewayArtifactPaths.safeComponent("")
        XCTAssertFalse(name.isEmpty)
        XCTAssertEqual(name.count, 64) // sha256 hex
    }

    // MARK: - p.54: artifact path construction

    func testArtifactPathStaysInBaseDirectory() {
        let url = GatewayArtifactPaths.appending(filename: "gateway.bin", to: baseURL, fingerprint: "abc123")
        XCTAssertEqual(url.path.hasPrefix(baseURL.path), true)
        XCTAssertEqual(url.lastPathComponent, "gateway-abc123.bin")
    }

    func testArtifactPathResistsTraversalViaFilename() {
        let url = GatewayArtifactPaths.appending(filename: "../../../etc/passwd", to: baseURL, fingerprint: "abc123")
        // Must remain under baseURL regardless of filename — no "../" can escape.
        XCTAssertTrue(url.path.hasPrefix(baseURL.path), "path escaped base: \(url.path)")
        XCTAssertFalse(url.lastPathComponent.contains(".."))
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }

    // MARK: - p.56: filename sanitization

    func testFilenameNeverWorldWritableIndicator() {
        // The sanitized name contains no shell-special or permission-escape chars.
        let name = GatewayArtifactPaths.safeComponent("file; rm -rf /")
        XCTAssertFalse(name.contains(";"))
        XCTAssertFalse(name.contains(" "))
    }
}
