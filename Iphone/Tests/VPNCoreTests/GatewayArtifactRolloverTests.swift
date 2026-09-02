import Crypto
import Foundation
import XCTest
@testable import VPNCore

/// Tests Chapter 2 items 30-31: public-key rollover. The verifier must accept a
/// signature made with ANY activated trusted key, and must reject a signature
/// made with a key whose activation date has not arrived yet (grace period).
final class GatewayArtifactRolloverTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_900_000_000) // fixed "now" anchor
    private let past = Date(timeIntervalSince1970: 1_800_000_000)          // well before reference
    private let future = Date(timeIntervalSince1970: 2_000_000_000)        // well after reference

    private var oldKey: Curve25519.Signing.PrivateKey!
    private var newKey: Curve25519.Signing.PrivateKey!
    private var binary: Data!
    private var artifactHash: Data!

    override func setUp() {
        super.setUp()
        oldKey = Curve25519.Signing.PrivateKey()
        newKey = Curve25519.Signing.PrivateKey()
        binary = Data("sshtunnel-gateway-binary-v2".utf8)
        artifactHash = Data(SHA256.hash(data: binary))
    }

    private func verifier(now: Date, newActivation: Date) -> GatewayArtifactVerifier {
        GatewayArtifactVerifier(
            expectedHash: artifactHash,
            trustedKeys: [
                TrustedKey(publicKey: oldKey.publicKey, activationDate: past),
                TrustedKey(publicKey: newKey.publicKey, activationDate: newActivation),
            ]
        )
    }

    // MARK: - p.30: key rollover

    func testOldKeySignatureAcceptedBeforeNewKeyActivates() throws {
        let sig = try oldKey.signature(for: binary)
        let verifier = verifier(now: referenceDate, newActivation: future)
        XCTAssertEqual(try verifier.verify(binary, signature: sig, now: referenceDate), binary)
    }

    func testNewKeySignatureRejectedBeforeActivation() {
        // Grace period: the new key exists but is not yet active → its
        // signature must be rejected even though the key is "trusted".
        let sig = try! newKey.signature(for: binary)
        let verifier = verifier(now: referenceDate, newActivation: future)
        XCTAssertThrowsError(try verifier.verify(binary, signature: sig, now: referenceDate)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .signatureMismatch)
        }
    }

    func testNewKeySignatureAcceptedAfterActivation() throws {
        let sig = try newKey.signature(for: binary)
        let verifier = verifier(now: referenceDate, newActivation: past)
        XCTAssertEqual(try verifier.verify(binary, signature: sig, now: referenceDate), binary)
    }

    func testOldKeySignatureStillAcceptedAfterNewKeyActivates() throws {
        // Backward compatibility: activating the new key must not invalidate
        // signatures made with the old key.
        let sig = try oldKey.signature(for: binary)
        let verifier = verifier(now: referenceDate, newActivation: past)
        XCTAssertEqual(try verifier.verify(binary, signature: sig, now: referenceDate), binary)
    }

    // MARK: - p.31: rollover grace period

    func testGracePeriodRejectsNewKeyBeforeActivationDate() {
        // Exactly one second before activation → still rejected.
        let justBefore = Date(timeIntervalSince1970: 1_900_000_000 - 1)
        let sig = try! newKey.signature(for: binary)
        let verifier = verifier(now: referenceDate, newActivation: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertThrowsError(try verifier.verify(binary, signature: sig, now: justBefore)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .signatureMismatch)
        }
    }

    func testGracePeriodAcceptsNewKeyExactlyAtActivationDate() throws {
        // At the exact activation instant → accepted (>= boundary).
        let activation = Date(timeIntervalSince1970: 1_900_000_000)
        let sig = try newKey.signature(for: binary)
        let verifier = verifier(now: referenceDate, newActivation: activation)
        XCTAssertEqual(try verifier.verify(binary, signature: sig, now: activation), binary)
    }

    // MARK: - edge cases

    func testNoActivatedKeysRejects() {
        // Both keys activate in the future → nothing can verify a signature.
        let sig = try! oldKey.signature(for: binary)
        let verifier = verifier(now: referenceDate, newActivation: future)
        let bothFuture = GatewayArtifactVerifier(
            expectedHash: artifactHash,
            trustedKeys: [
                TrustedKey(publicKey: oldKey.publicKey, activationDate: future),
                TrustedKey(publicKey: newKey.publicKey, activationDate: future),
            ]
        )
        XCTAssertThrowsError(try bothFuture.verify(binary, signature: sig, now: referenceDate)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .signatureMismatch)
        }
        _ = verifier
    }

    func testSingleTrustedKeyBackwardsCompatible() throws {
        // The single-key initializer (no activation date) must keep working.
        let sig = try oldKey.signature(for: binary)
        let verifier = GatewayArtifactVerifier(expectedHash: artifactHash, publicKey: oldKey.publicKey)
        XCTAssertEqual(try verifier.verify(binary, signature: sig, now: referenceDate), binary)
    }

    func testUnknownKeyRejectedEvenWhenActivated() {
        // A key that is not in the trusted set is rejected even if "activated".
        let intruder = Curve25519.Signing.PrivateKey()
        let sig = try! intruder.signature(for: binary)
        let verifier = verifier(now: referenceDate, newActivation: past)
        XCTAssertThrowsError(try verifier.verify(binary, signature: sig, now: referenceDate)) { error in
            XCTAssertEqual(error as? GatewayArtifactError, .signatureMismatch)
        }
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
