import Crypto
import Foundation
import XCTest
@testable import VPNCore

/// Tests the C10 security core: an artifact (gateway binary) must pass sha256
/// AND Ed25519 checks before it is ever trusted for execution. This is the
/// non-negotiable primitive — the rest of Chapter 2 (streaming, CDN, UI)
/// depends on it and is built on top later.
final class GatewayArtifactVerifierTests: XCTestCase {
    private var keyPair: Curve25519.Signing.PrivateKey!
    private var expectedBinary: Data!
    private var expectedHash: Data!
    private var validSignature: Data!

    override func setUp() {
        super.setUp()
        keyPair = Curve25519.Signing.PrivateKey()
        expectedBinary = Data("sshtunnel-gateway-binary-v1".utf8)
        expectedHash = Data(SHA256.hash(data: expectedBinary))
        validSignature = try! keyPair.signature(for: expectedBinary)
    }

    private func makeVerifier(maximum: Int = 2 * 1024 * 1024) -> GatewayArtifactVerifier {
        GatewayArtifactVerifier(
            expectedHash: expectedHash,
            publicKey: keyPair.publicKey,
            maximumBinarySize: maximum
        )
    }

    // MARK: - Happy path

    func testValidBinaryAndSignatureAccepted() throws {
        let verifier = makeVerifier()
        let result = try verifier.verify(expectedBinary, signature: validSignature)
        XCTAssertEqual(result, expectedBinary)
    }

    // MARK: - Hash verification

    func testHashMismatchRejected() {
        let verifier = makeVerifier()
        let wrongHash = Data(repeating: 0x00, count: 32)
        let other = GatewayArtifactVerifier(expectedHash: wrongHash, publicKey: keyPair.publicKey)
        XCTAssertThrowsError(try other.verify(expectedBinary, signature: validSignature)) { error in
            guard case GatewayArtifactError.hashMismatch(let expected, let actual) = error else {
                return XCTFail("expected hashMismatch, got \(error)")
            }
            XCTAssertEqual(expected, wrongHash.hex)
            XCTAssertEqual(actual, expectedHash.hex)
        }
    }

    func testTamperedBinaryRejected() throws {
        // Flip a single bit in an otherwise-valid binary: hash no longer matches.
        var tampered = expectedBinary!
        tampered[0] ^= 0x01
        let newSig = try keyPair.signature(for: tampered)
        let verifier = makeVerifier()
        XCTAssertThrowsError(try verifier.verify(tampered, signature: newSig)) { error in
            XCTAssertTrue(error is GatewayArtifactError)
        }
    }

    func testTruncatedBinaryRejected() {
        let truncated = expectedBinary.prefix(expectedBinary.count / 2)
        let verifier = makeVerifier()
        XCTAssertThrowsError(try verifier.verify(truncated, signature: validSignature)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .hashMismatch(expected: expectedHash.hex, actual: Data(SHA256.hash(data: truncated)).hex))
        }
    }

    // MARK: - Signature verification

    func testSignatureMismatchRejected() {
        let intruder = Curve25519.Signing.PrivateKey()
        let badSignature = try! intruder.signature(for: expectedBinary)
        let verifier = makeVerifier()
        XCTAssertThrowsError(try verifier.verify(expectedBinary, signature: badSignature)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .signatureMismatch)
        }
    }

    func testSignatureCheckedAfterHash() {
        // A binary with a valid hash but wrong signature must fail on the
        // signature step, proving the order is hash-then-signature.
        let intruder = Curve25519.Signing.PrivateKey()
        let signedByIntruder = try! intruder.signature(for: expectedBinary)
        let verifier = makeVerifier()
        XCTAssertThrowsError(try verifier.verify(expectedBinary, signature: signedByIntruder)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .signatureMismatch)
        }
    }

    // MARK: - Size and emptiness guards

    func testEmptyBinaryRejected() {
        let verifier = makeVerifier()
        XCTAssertThrowsError(try verifier.verify(Data(), signature: validSignature)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .emptyBinary)
        }
    }

    func testZeroSizeBinaryRejected() {
        // Explicit zero-length is the same guard as empty.
        let verifier = makeVerifier()
        XCTAssertThrowsError(try verifier.verify(Data(), signature: Data())) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .emptyBinary)
        }
    }

    func testBinaryExceedingMaximumSizeRejected() {
        let verifier = makeVerifier(maximum: 16)
        XCTAssertThrowsError(try verifier.verify(expectedBinary, signature: validSignature)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .binaryTooLarge(maximum: 16))
        }
    }

    func testBinaryAtMaximumSizeAccepted() throws {
        let exact = Data(repeating: 0xAB, count: 32)
        let hash = Data(SHA256.hash(data: exact))
        let sig = try keyPair.signature(for: exact)
        let verifier = GatewayArtifactVerifier(expectedHash: hash, publicKey: keyPair.publicKey, maximumBinarySize: 32)
        XCTAssertEqual(try verifier.verify(exact, signature: sig), exact)
    }

    // MARK: - Order of checks (defence in depth)

    func testEmptyCheckedBeforeHash() {
        // An empty binary must fail on the emptiness guard, not produce a
        // misleading hashMismatch for the empty input.
        let verifier = makeVerifier()
        XCTAssertThrowsError(try verifier.verify(Data(), signature: validSignature)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .emptyBinary)
        }
    }

    func testSizeCheckedBeforeHash() {
        // An oversized binary must fail on the size guard before any hashing.
        let verifier = makeVerifier(maximum: 4)
        XCTAssertThrowsError(try verifier.verify(expectedBinary, signature: validSignature)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .binaryTooLarge(maximum: 4))
        }
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
